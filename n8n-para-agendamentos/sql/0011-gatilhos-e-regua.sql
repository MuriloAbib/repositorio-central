-- 0011-gatilhos-e-regua.sql
--
-- Liga a camada de automação ao appointments que já existe, SEM alterar a
-- tabela e sem exigir mudança no app do Lovable: o app continua dando
-- INSERT/UPDATE em appointments como hoje, e o gatilho emite o evento e agenda
-- o lembrete na mesma transação.
--
-- É de propósito que isto seja gatilho e não chamada da aplicação. O BarberBook
-- grava agendamento de três lugares diferentes (painel do barbeiro em
-- app.agendamentos, link público em agendar.$slug, área do cliente em
-- cliente.*). Se o evento fosse emitido pela aplicação, cada um desses lugares
-- teria de lembrar de emitir — e o que for esquecido vira agendamento sem aviso,
-- silenciosamente. No gatilho, não há como esquecer.
--
-- A RÉGUA DA SEÇÃO 6 vive em UMA função, agendar_lembrete. Mexer nela mexe no
-- número de mensagens por agendamento, que é a variável de custo do produto.

set search_path = public;

-- ---------------------------------------------------------------------------
-- iso_utc — instante em UTC com 'Z', para o payload do evento.
-- ---------------------------------------------------------------------------
-- Não use to_jsonb(timestamptz) para montar payload: ele renderiza no TimeZone
-- da sessão, então o MESMO agendamento sairia com offset diferente dependendo
-- de quem disparou o gatilho (painel, webhook, psql). O consumidor no n8n
-- converte para o fuso da barbearia na hora de escrever a mensagem; o
-- transporte é sempre UTC.
create or replace function public.iso_utc(p_instante timestamptz)
returns text
language sql
immutable
set search_path = ''
as $$
  select to_char(p_instante at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
$$;

-- ---------------------------------------------------------------------------
-- contexto_do_agendamento — junta o que a mensagem precisa, de uma vez.
-- ---------------------------------------------------------------------------
-- Um SELECT só em vez de cinco. O gatilho roda dentro da transação de quem está
-- gravando o agendamento: cada consulta extra aqui é latência no clique do
-- cliente que está marcando o horário.
create or replace function public.contexto_do_agendamento(p_appointment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'appointment_id',  a.id,
    'owner_id',        a.barber_id,
    'inicio_em',       public.iso_utc(a.scheduled_at),
    'fim_em',          public.iso_utc(a.scheduled_at + (a.duration_min * interval '1 minute')),
    'duracao_min',     a.duration_min,
    'status',          a.status,
    'total_centavos',  round(a.total_price * 100)::bigint,
    'observacao',      a.notes,
    'barbearia',       jsonb_build_object(
                         'nome', coalesce(b.shop_name, 'sua barbearia'),
                         'slug', b.slug
                       ),
    'servico',         jsonb_build_object(
                         'nome',        coalesce(s.name, 'serviço'),
                         'duracao_min', s.duration_min
                       ),
    'cliente',         jsonb_build_object(
                         'nome',     coalesce(pc.full_name, 'cliente'),
                         'telefone', pc.phone,
                         -- canal: o vault registra que e-mail é ~100x mais
                         -- barato que mensagem, e que deixar o cliente escolher
                         -- o modal faz o custo variável ter duas curvas. O
                         -- schema atual não tem a coluna de preferência, então
                         -- a regra é "WhatsApp se houver telefone, senão
                         -- e-mail". Quando a coluna existir, é só aqui que muda.
                         'canal',    case when pc.phone is not null then 'whatsapp' else 'email' end
                       ),
    'profissional',    jsonb_build_object(
                         'nome',     coalesce(st.display_name, st.full_name, po.full_name, 'profissional'),
                         -- O aviso vai para quem atende. Se o agendamento tem
                         -- staff, é o telefone dele; senão é o do dono. Sem o
                         -- coalesce, barbearia de um só profissional (que não
                         -- cria staff) nunca receberia aviso.
                         'telefone', coalesce(st.phone, po.phone),
                         'canal',    case when coalesce(st.phone, po.phone) is not null
                                          then 'whatsapp' else 'email' end,
                         'email',    coalesce(st.email, (select u.email from auth.users u where u.id = a.barber_id))
                       )
  )
  from public.appointments a
  left join public.barbers  b  on b.user_id = a.barber_id
  left join public.services  s  on s.id      = a.service_id
  left join public.profiles  pc on pc.id     = a.client_id
  left join public.profiles  po on po.id     = a.barber_id
  left join public.staff     st on st.id     = a.staff_id
  where a.id = p_appointment_id;
$$;

-- ---------------------------------------------------------------------------
-- emitir_evento — grava no outbox.
-- ---------------------------------------------------------------------------
create or replace function public.emitir_evento(
  p_owner_id uuid,
  p_evento   text,
  p_dados    jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.eventos_saida (owner_id, evento, versao, dados)
  values (p_owner_id, p_evento, 1, p_dados)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- agendar_lembrete — A RÉGUA. Decidida na reunião de 27/08/2026.
-- ---------------------------------------------------------------------------
--   início a MAIS de 2h  ->  lembrete em (início - 2h)
--   início em 2h ou menos ->  lembrete AGORA (em cima da hora avisa na hora)
--
-- Uma função, um lugar. Se a régua virasse duas cópias (uma na criação, outra
-- na remarcação), remarcar passaria a usar regra diferente de marcar e o número
-- de mensagens por agendamento deixaria de ser conhecido — exatamente o número
-- que a precificação do produto depende.
--
-- Usa ON CONFLICT em (appointment_id, tipo): remarcar REAPROVEITA a linha em
-- vez de criar outra. É isso que garante uma mensagem por agendamento mesmo
-- quando o cliente remarca três vezes.
create or replace function public.agendar_lembrete(p_appointment_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ctx         jsonb;
  v_disparar    timestamptz;
  v_inicio      timestamptz;
  v_canal       text;
  v_destino     text;
  v_id          uuid;
begin
  v_ctx := public.contexto_do_agendamento(p_appointment_id);
  if v_ctx is null then
    return null;
  end if;

  -- Agendamento que já nasce cancelado ou concluído não gera aviso.
  if (v_ctx ->> 'status') in ('cancelled', 'completed') then
    return null;
  end if;

  v_inicio := ((v_ctx ->> 'inicio_em')::timestamptz);
  v_canal  := v_ctx -> 'cliente' ->> 'canal';

  -- O destino do lembrete é o CLIENTE. profiles não tem coluna de e-mail: o
  -- e-mail do cliente mora em auth.users, porque quem cria a conta é o Supabase
  -- Auth. Daí a busca por client_id aqui em vez de vir no contexto.
  if v_canal = 'whatsapp' then
    v_destino := v_ctx -> 'cliente' ->> 'telefone';
  else
    select u.email
      into v_destino
      from public.appointments a
      join auth.users u on u.id = a.client_id
     where a.id = p_appointment_id;
  end if;

  -- Sem telefone e sem e-mail não há como avisar. Não cria linha pendente que
  -- nunca vai sair: o painel de "lembretes atrasados" existe para mostrar
  -- problema real, e encher ele de lixo permanente o torna inútil.
  if v_destino is null or btrim(v_destino) = '' then
    return null;
  end if;

  -- A régua, nas duas pernas.
  if v_inicio - now() > interval '2 hours' then
    v_disparar := v_inicio - interval '2 hours';
  else
    v_disparar := now();
  end if;

  insert into public.lembretes (owner_id, appointment_id, tipo, disparar_em, canal, destino)
  values (
    ((v_ctx ->> 'owner_id')::uuid),
    p_appointment_id,
    'confirmacao',
    v_disparar,
    v_canal,
    v_destino
  )
  on conflict (appointment_id, tipo) do update
    set disparar_em   = excluded.disparar_em,
        canal         = excluded.canal,
        destino       = excluded.destino,
        -- Remarcação ressuscita um lembrete já enviado ou cancelado: o cliente
        -- precisa ser avisado do horário NOVO, mesmo que já tenha confirmado o
        -- antigo. Zera tentativas para não herdar o retry da linha anterior.
        status        = 'pendente',
        tentativas    = 0,
        reservado_ate = null,
        enviado_em    = null,
        ultimo_erro   = null
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- cancelar_lembretes_do_agendamento
-- ---------------------------------------------------------------------------
-- Sem isto o cliente recebe lembrete de um corte que não existe mais — o
-- defeito mais visível que este sistema consegue produzir.
create or replace function public.cancelar_lembretes_do_agendamento(p_appointment_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.lembretes
     set status = 'cancelado'
   where appointment_id = p_appointment_id
     and status = 'pendente';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- O gatilho.
-- ---------------------------------------------------------------------------
-- AFTER, não BEFORE: o evento só deve existir se o agendamento existir de fato,
-- inclusive depois de todas as constraints passarem.
create or replace function public.ao_mudar_agendamento()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ctx jsonb;
begin
  if tg_op = 'INSERT' then
    v_ctx := public.contexto_do_agendamento(new.id);
    perform public.emitir_evento(new.barber_id, 'agendamento.criado', v_ctx);
    perform public.agendar_lembrete(new.id);
    return new;
  end if;

  -- UPDATE --------------------------------------------------------------

  -- Cancelamento: avisa quem atende e mata o lembrete pendente.
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    v_ctx := public.contexto_do_agendamento(new.id);
    perform public.emitir_evento(new.barber_id, 'agendamento.cancelado', v_ctx);
    perform public.cancelar_lembretes_do_agendamento(new.id);
    return new;
  end if;

  -- Confirmação pelo cliente (o fluxo sim/não) ou pelo painel.
  if new.status = 'confirmed' and old.status <> 'confirmed' then
    v_ctx := public.contexto_do_agendamento(new.id);
    perform public.emitir_evento(new.barber_id, 'agendamento.confirmado', v_ctx);
    return new;
  end if;

  -- Remarcação. Compara o instante, não a linha: UPDATE que só mexe em notes
  -- não é remarcação e não deve reenviar nada.
  if new.scheduled_at <> old.scheduled_at then
    v_ctx := public.contexto_do_agendamento(new.id)
             || jsonb_build_object('inicio_em_antigo', public.iso_utc(old.scheduled_at));
    perform public.emitir_evento(new.barber_id, 'agendamento.remarcado', v_ctx);
    perform public.agendar_lembrete(new.id);
    return new;
  end if;

  return new;
end;
$$;

drop trigger if exists agendamento_para_automacao on public.appointments;
create trigger agendamento_para_automacao
  after insert or update on public.appointments
  for each row execute function public.ao_mudar_agendamento();
