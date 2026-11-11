-- 0004-funcoes.sql
--
-- Garante as duas coisas que a aplicação não consegue garantir sozinha:
-- atomicidade (o agendamento, o evento do outbox e o lembrete nascem na MESMA
-- transação — não existe agenda sem aviso nem aviso sem agenda) e reserva segura de
-- fila (FOR UPDATE SKIP LOCKED mais lease, para vários workers do n8n sem entrega
-- dobrada). A régua da seção 6 mora em UMA função, agendar_lembrete, porque mexer
-- nela mexe no preço do produto. Toda função SECURITY DEFINER tem search_path = '' e
-- nomes qualificados: DEFINER com search_path aberto é escalonamento de privilégio,
-- porque quem controla o search_path escolhe qual tabela a função vai usar.

set search_path = public;


-- ---------------------------------------------------------------------------
-- iso_utc — o envelope da seção 3 carrega instante em UTC com 'Z'.
-- ---------------------------------------------------------------------------
-- Não use to_jsonb(timestamptz) para montar payload: ele renderiza no TimeZone da
-- sessão, então o mesmo evento sairia com offset diferente dependendo de quem chamou.
create or replace function public.iso_utc(p_instante timestamptz)
returns text
language sql
immutable
set search_path = ''
as $$
  select to_char(p_instante at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
$$;


-- ---------------------------------------------------------------------------
-- registrar_falha — o que esgotou retry vira linha na fila_morta.
-- ---------------------------------------------------------------------------
-- DEFINER porque fila_morta é fechada para usuário final (0003) e quem chama pode ser
-- um gatilho rodando em nome de uma sessão de painel.
create or replace function public.registrar_falha(
  p_origem    text,
  p_evento    text,
  p_payload   jsonb,
  p_erro      text,
  p_tenant_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_origem is null or btrim(p_origem) = '' then
    raise exception 'origem da falha e obrigatoria' using errcode = '22023';
  end if;

  insert into public.fila_morta (tenant_id, origem, evento, payload, erro)
  values (p_tenant_id, p_origem, p_evento, coalesce(p_payload, '{}'::jsonb),
          coalesce(p_erro, 'sem detalhe'))
  returning id into v_id;

  return v_id;
end;
$$;


-- ---------------------------------------------------------------------------
-- agendar_lembrete — A RÉGUA DA SEÇÃO 6, em um único lugar.
-- ---------------------------------------------------------------------------
-- Chamada por criar_agendamento e pelo gatilho de remarcação. Se a régua virasse duas
-- cópias, a remarcação passaria a usar uma regra diferente da criação e o custo por
-- agendamento deixaria de ser um número conhecido.
create or replace function public.agendar_lembrete(p_agendamento_id uuid)
returns public.lembretes
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dados    record;
  v_tipo     text;
  v_disparar timestamptz;
  v_canal    text;
  v_destino  text;
  v_lembrete public.lembretes;
begin
  select a.tenant_id       as tenant_id,
         a.inicio_em       as inicio_em,
         a.status          as status,
         c.canal_preferido as canal_preferido,
         c.telefone        as telefone,
         c.email           as email
    into v_dados
    from public.agendamentos a
    join public.clientes c on c.id = a.cliente_id
   where a.id = p_agendamento_id;

  if not found then
    raise exception 'agendamento % nao encontrado', p_agendamento_id using errcode = 'P0002';
  end if;

  -- Agendamento cancelado não gera lembrete; devolver NULL deixa o gatilho de
  -- remarcação simples (cancelou e remarcou na mesma transação não ressuscita aviso).
  if v_dados.status = 'cancelado' then
    return null;
  end if;

  -- Horário que já passou não é "em cima da hora": é passado. Só chega aqui por
  -- reativação ou remarcação para trás, e avisar depois do corte é só incômodo.
  if v_dados.inicio_em <= now() then
    return null;
  end if;

  -- Régua da reunião de 27/08/2026: mais de 2h de antecedência avisa 2h antes; em
  -- cima da hora avisa na hora. Uma mensagem por agendamento, sempre.
  if v_dados.inicio_em - now() > interval '2 hours' then
    v_tipo     := 'lembrete_2h';
    v_disparar := v_dados.inicio_em - interval '2 hours';
  else
    v_tipo     := 'imediato';
    v_disparar := now();
  end if;

  -- O canal sai de clientes.canal_preferido (e-mail é ~100x mais barato que mensagem,
  -- então o custo variável tem duas curvas).
  v_canal   := v_dados.canal_preferido;
  v_destino := case when v_canal = 'email' then v_dados.email else v_dados.telefone end;

  if v_destino is null then
    raise exception 'cliente sem destino para o canal %', v_canal using errcode = '22023';
  end if;

  insert into public.lembretes (tenant_id, agendamento_id, tipo, disparar_em, canal, destino)
  values (v_dados.tenant_id, p_agendamento_id, v_tipo, v_disparar, v_canal, v_destino)
  returning * into v_lembrete;

  return v_lembrete;
end;
$$;


-- ---------------------------------------------------------------------------
-- criar_agendamento — o caminho transacional do fluxo B.
-- ---------------------------------------------------------------------------
-- Grava agendamento + evento no outbox + lembrete de uma vez. A chamada direta do
-- webhook do n8n, que acontece depois, é só otimização de latência: se ela falhar, o
-- reconciliador entrega pelo outbox. Por isso o evento NÃO pode ser emitido fora
-- desta transação.
create or replace function public.criar_agendamento(
  p_tenant_id   uuid,
  p_barbeiro_id uuid,
  p_servico_id  uuid,
  p_cliente_id  uuid,
  p_inicio_em   timestamptz,
  p_origem      text default 'painel'
)
returns table (
  agendamento_id uuid,
  evento_id      uuid,
  lembrete_id    uuid,
  disparar_em    timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sessao          uuid := public.tenant_atual();
  v_barbeiro        record;
  v_servico         record;
  v_cliente         record;
  v_fim             timestamptz;
  v_agendamento_id  uuid;
  v_evento_id       uuid;
  v_lembrete        public.lembretes;
begin
  -- DEFINER passa por cima da RLS, então a checagem de inquilino tem de ser explícita
  -- aqui. Sessão de usuário final só escreve no próprio tenant; a service_role não
  -- carrega tenant no JWT (tenant_atual() é NULL) e por isso pode agendar em nome de
  -- qualquer barbearia — é ela que atende o agente e o site.
  if v_sessao is not null and v_sessao <> p_tenant_id then
    raise exception 'tenant do pedido difere do tenant da sessao'
      using errcode = '42501';
  end if;

  if p_origem not in ('painel', 'agente', 'site', 'importacao') then
    raise exception 'origem invalida: %', p_origem using errcode = '22023';
  end if;

  if p_inicio_em is null or p_inicio_em <= now() then
    raise exception 'inicio_em tem de estar no futuro' using errcode = '22023';
  end if;

  -- Cada referência é conferida CONTRA o tenant do pedido: sem isso um id de barbeiro
  -- de outra barbearia entraria na agenda desta.
  select b.nome, b.telefone, b.canal_preferido, b.ativo
    into v_barbeiro
    from public.barbeiros b
   where b.id = p_barbeiro_id and b.tenant_id = p_tenant_id;
  if not found then
    raise exception 'barbeiro % nao pertence ao tenant %', p_barbeiro_id, p_tenant_id
      using errcode = 'P0002';
  end if;
  if not v_barbeiro.ativo then
    raise exception 'barbeiro % esta inativo', p_barbeiro_id using errcode = '22023';
  end if;

  select s.nome, s.duracao_min, s.preco_centavos, s.ativo
    into v_servico
    from public.servicos s
   where s.id = p_servico_id and s.tenant_id = p_tenant_id;
  if not found then
    raise exception 'servico % nao pertence ao tenant %', p_servico_id, p_tenant_id
      using errcode = 'P0002';
  end if;
  if not v_servico.ativo then
    raise exception 'servico % esta inativo', p_servico_id using errcode = '22023';
  end if;

  select c.nome, c.telefone, c.canal_preferido
    into v_cliente
    from public.clientes c
   where c.id = p_cliente_id and c.tenant_id = p_tenant_id;
  if not found then
    raise exception 'cliente % nao pertence ao tenant %', p_cliente_id, p_tenant_id
      using errcode = 'P0002';
  end if;

  -- O fim vem da duração do serviço, nunca do chamador: fim informado por fora é
  -- como se vende duas vezes o mesmo horário sem a constraint perceber.
  v_fim := p_inicio_em + (v_servico.duracao_min * interval '1 minute');

  begin
    insert into public.agendamentos
      (tenant_id, barbeiro_id, servico_id, cliente_id, inicio_em, fim_em, origem)
    values
      (p_tenant_id, p_barbeiro_id, p_servico_id, p_cliente_id, p_inicio_em, v_fim, p_origem)
    returning id into v_agendamento_id;
  exception
    when exclusion_violation then
      -- Quem perdeu a corrida recebe erro de negócio, não traço de constraint.
      raise exception 'horario ja ocupado para este barbeiro: % a %', p_inicio_em, v_fim
        using errcode = '23P01',
              hint = 'recarregue a disponibilidade antes de tentar de novo';
  end;

  -- Padrão outbox: o evento é parte do fato, não consequência dele.
  insert into public.eventos_saida (tenant_id, evento, versao, dados)
  values (
    p_tenant_id,
    'agendamento.criado',
    1,
    jsonb_build_object(
      'agendamento_id', v_agendamento_id,
      'inicio_em',      public.iso_utc(p_inicio_em),
      'fim_em',         public.iso_utc(v_fim),
      'servico', jsonb_build_object(
        'nome',           v_servico.nome,
        'duracao_min',    v_servico.duracao_min,
        'preco_centavos', v_servico.preco_centavos
      ),
      'cliente', jsonb_build_object(
        'nome',            v_cliente.nome,
        'telefone',        v_cliente.telefone,
        'canal_preferido', v_cliente.canal_preferido
      ),
      'barbeiro', jsonb_build_object(
        'nome',            v_barbeiro.nome,
        'telefone',        v_barbeiro.telefone,
        'canal_preferido', v_barbeiro.canal_preferido
      ),
      'origem', p_origem
    )
  )
  returning id into v_evento_id;

  v_lembrete := public.agendar_lembrete(v_agendamento_id);

  return query select v_agendamento_id, v_evento_id, v_lembrete.id, v_lembrete.disparar_em;
end;
$$;


-- ---------------------------------------------------------------------------
-- cancelar_lembretes_do_agendamento — cancelamento tem de matar o aviso.
-- ---------------------------------------------------------------------------
-- Sem isso o cliente recebe lembrete de um corte que não existe mais, que é o defeito
-- mais visível que este sistema consegue produzir.
create or replace function public.cancelar_lembretes_do_agendamento(p_agendamento_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sessao uuid := public.tenant_atual();
  v_n      integer;
begin
  update public.lembretes l
     set status = 'cancelado',
         reservado_ate = null
   where l.agendamento_id = p_agendamento_id
     and l.status = 'pendente'
     -- DEFINER ignora RLS: a sessão de painel só cancela aviso do próprio tenant.
     and (v_sessao is null or l.tenant_id = v_sessao);

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;


-- ---------------------------------------------------------------------------
-- ao_mudar_agendamento — o painel altera a agenda por UPDATE direto (0003 permite),
-- e o outbox não pode depender de o painel lembrar de emitir o evento.
-- ---------------------------------------------------------------------------
-- DEFINER porque eventos_saida é fechada para usuário final: sem isso o UPDATE do
-- painel falharia na política de INSERT do outbox.
create or replace function public.ao_mudar_agendamento()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'cancelado' and old.status <> 'cancelado' then
    perform public.cancelar_lembretes_do_agendamento(new.id);

    insert into public.eventos_saida (tenant_id, evento, versao, dados)
    values (new.tenant_id, 'agendamento.cancelado', 1, jsonb_build_object(
      'agendamento_id', new.id,
      'cancelado_em',   public.iso_utc(coalesce(new.cancelado_em, now())),
      'cancelado_por',  coalesce(new.cancelado_por, 'desconhecido'),
      'motivo',         new.motivo_cancelamento
    ));

    -- Cancelou: não há remarcação a tratar, mesmo que a hora também tenha mudado.
    return new;
  end if;

  if new.status = 'confirmado' and old.status <> 'confirmado' then
    insert into public.eventos_saida (tenant_id, evento, versao, dados)
    values (new.tenant_id, 'agendamento.confirmado', 1, jsonb_build_object(
      'agendamento_id', new.id,
      'confirmado_em',  public.iso_utc(coalesce(new.confirmado_em, now())),
      'confirmado_por', coalesce(new.confirmado_por, 'desconhecido')
    ));
  end if;

  -- Reativar um agendamento cancelado é UPDATE de status no painel, e sem este ramo o
  -- corte volta para a agenda sem aviso nenhum: o lembrete morreu no cancelamento.
  if old.status = 'cancelado' and new.status <> 'cancelado' then
    perform public.cancelar_lembretes_do_agendamento(new.id);
    perform public.agendar_lembrete(new.id);
  end if;

  if new.inicio_em <> old.inicio_em then
    -- O aviso velho aponta para uma hora que não existe mais. Cancelar primeiro é o
    -- que libera a vaga do índice único "um lembrete por agendamento".
    perform public.cancelar_lembretes_do_agendamento(new.id);
    perform public.agendar_lembrete(new.id);

    insert into public.eventos_saida (tenant_id, evento, versao, dados)
    values (new.tenant_id, 'agendamento.remarcado', 1, jsonb_build_object(
      'agendamento_id',   new.id,
      'inicio_em_antigo', public.iso_utc(old.inicio_em),
      'inicio_em',        public.iso_utc(new.inicio_em)
    ));
  end if;

  return new;
end;
$$;

drop trigger if exists ao_mudar_agendamento on public.agendamentos;
create trigger ao_mudar_agendamento
  after update on public.agendamentos
  for each row
  when (old.status is distinct from new.status
        or old.inicio_em is distinct from new.inicio_em)
  execute function public.ao_mudar_agendamento();


-- ---------------------------------------------------------------------------
-- reservar_eventos_saida — o poller do outbox.
-- ---------------------------------------------------------------------------
-- SKIP LOCKED resolve a corrida entre dois workers DENTRO da transação; o lease
-- (reservado_ate) resolve o que vem depois dela, porque o lock morre no commit da
-- função e a mesma linha voltaria a aparecer enquanto o n8n ainda está entregando.
-- Juntos é o que permite mais de um worker sem entrega dupla.
create or replace function public.reservar_eventos_saida(
  p_limite         integer  default 50,
  p_lease          interval default interval '2 minutes',
  p_max_tentativas integer  default 8
)
returns table (
  id         uuid,
  tenant_id  uuid,
  evento     text,
  versao     integer,
  dados      jsonb,
  criado_em  timestamptz,
  tentativas integer
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with alvo as (
    select e.id
      from public.eventos_saida e
     where e.entregue_em is null
       and e.abandonado_em is null
       and (e.reservado_ate is null or e.reservado_ate <= now())
       and e.tentativas < p_max_tentativas
     order by e.criado_em
     limit greatest(p_limite, 1)
     for update skip locked
  )
  update public.eventos_saida e
     set tentativas    = e.tentativas + 1,
         reservado_ate = now() + p_lease
    from alvo
   where e.id = alvo.id
  returning e.id, e.tenant_id, e.evento, e.versao, e.dados, e.criado_em, e.tentativas;
end;
$$;


-- ---------------------------------------------------------------------------
-- reservar_lembretes_devidos — o poller do relógio.
-- ---------------------------------------------------------------------------
-- Devolve o `variaveis{}` do evento lembrete.devido já montado, inclusive a hora no
-- fuso da barbearia: a conversão de UTC para local é da montagem da mensagem, e o
-- fuso mora em tenants, não no n8n.
create or replace function public.reservar_lembretes_devidos(
  p_limite         integer  default 50,
  p_lease          interval default interval '2 minutes',
  p_max_tentativas integer  default 5
)
returns table (
  lembrete_id    uuid,
  tenant_id      uuid,
  agendamento_id uuid,
  tipo           text,
  canal          text,
  destino        text,
  tentativas     integer,
  variaveis      jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with devidos as (
    select l.id
      from public.lembretes l
     where l.status = 'pendente'
       and l.disparar_em <= now()
       and (l.reservado_ate is null or l.reservado_ate <= now())
       and l.tentativas < p_max_tentativas
     order by l.disparar_em
     limit greatest(p_limite, 1)
     for update skip locked
  ),
  reservados as (
    update public.lembretes l
       set tentativas    = l.tentativas + 1,
           reservado_ate = now() + p_lease
      from devidos d
     where l.id = d.id
    returning l.id, l.tenant_id, l.agendamento_id, l.tipo, l.canal, l.destino, l.tentativas
  )
  select r.id, r.tenant_id, r.agendamento_id, r.tipo, r.canal, r.destino, r.tentativas,
         jsonb_build_object(
           'cliente_nome',    c.nome,
           'barbeiro_nome',   b.nome,
           'servico_nome',    s.nome,
           'preco_centavos',  s.preco_centavos,
           'inicio_em_utc',   public.iso_utc(a.inicio_em),
           'inicio_em_local', to_char(a.inicio_em at time zone t.fuso, 'DD/MM/YYYY HH24:MI'),
           'fuso',            t.fuso
         )
    from reservados r
    join public.agendamentos a on a.id = r.agendamento_id
    join public.tenants      t on t.id = r.tenant_id
    join public.clientes     c on c.id = a.cliente_id
    join public.servicos     s on s.id = a.servico_id
    join public.barbeiros    b on b.id = a.barbeiro_id;
end;
$$;


-- ---------------------------------------------------------------------------
-- Fechamento de ciclo: entregue, enviado, falhou.
-- ---------------------------------------------------------------------------
-- Devolvem false quando não havia nada a fechar (reentrega do n8n sobre linha já
-- fechada), e isso não é erro: é idempotência.
create or replace function public.marcar_evento_entregue(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.eventos_saida
     set entregue_em   = now(),
         reservado_ate = null,
         ultimo_erro   = null
   where id = p_id
     and entregue_em is null;

  return found;
end;
$$;

create or replace function public.marcar_lembrete_enviado(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.lembretes
     set status        = 'enviado',
         enviado_em    = now(),
         reservado_ate = null,
         ultimo_erro   = null
   where id = p_id
     and status = 'pendente';

  return found;
end;
$$;

-- Devolve true se ainda vai ser tentado, false se virou caso de fila_morta. O backoff
-- é exponencial com teto de 1h: 30s, 1min, 2min, ... e a linha continua no índice do
-- poller, só invisível até reservado_ate passar.
create or replace function public.registrar_falha_do_evento(
  p_id             uuid,
  p_erro           text,
  p_max_tentativas integer default 8
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tentativas integer;
  v_tenant     uuid;
  v_evento     text;
  v_dados      jsonb;
begin
  update public.eventos_saida e
     set ultimo_erro   = coalesce(p_erro, 'sem detalhe'),
         reservado_ate = now() + least(interval '1 hour',
                                       interval '30 seconds' * power(2, least(e.tentativas, 7)))
   where e.id = p_id
     and e.entregue_em is null
     and e.abandonado_em is null
  returning e.tentativas, e.tenant_id, e.evento, e.dados
       into v_tentativas, v_tenant, v_evento, v_dados;

  if not found then
    return false;
  end if;

  if v_tentativas >= p_max_tentativas then
    update public.eventos_saida set abandonado_em = now() where id = p_id;
    perform public.registrar_falha('outbox', v_evento, v_dados,
                                   coalesce(p_erro, 'sem detalhe'), v_tenant);
    return false;
  end if;

  return true;
end;
$$;

create or replace function public.registrar_falha_do_lembrete(
  p_id             uuid,
  p_erro           text,
  p_max_tentativas integer default 5
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tentativas integer;
  v_tenant     uuid;
  v_agendamento uuid;
  v_canal      text;
  v_destino    text;
begin
  update public.lembretes l
     set ultimo_erro   = coalesce(p_erro, 'sem detalhe'),
         reservado_ate = now() + least(interval '1 hour',
                                       interval '30 seconds' * power(2, least(l.tentativas, 7)))
   where l.id = p_id
     and l.status = 'pendente'
  returning l.tentativas, l.tenant_id, l.agendamento_id, l.canal, l.destino
       into v_tentativas, v_tenant, v_agendamento, v_canal, v_destino;

  if not found then
    return false;
  end if;

  if v_tentativas >= p_max_tentativas then
    -- 'falhou' tira a linha do índice parcial do poller e mantém o histórico; a vaga
    -- do índice único continua ocupada, porque a tentativa já foi paga.
    update public.lembretes set status = 'falhou', reservado_ate = null where id = p_id;
    perform public.registrar_falha('lembrete', 'lembrete.devido',
      jsonb_build_object(
        'lembrete_id',    p_id,
        'agendamento_id', v_agendamento,
        'canal',          v_canal,
        'destino',        v_destino
      ),
      coalesce(p_erro, 'sem detalhe'), v_tenant);
    return false;
  end if;

  return true;
end;
$$;


-- ---------------------------------------------------------------------------
-- Quem pode chamar o quê
-- ---------------------------------------------------------------------------
-- EXECUTE é concedido a PUBLIC por padrão no Postgres, e função SECURITY DEFINER
-- aberta a PUBLIC é a mesma coisa que não ter RLS. Daqui para baixo, cada função
-- declara seu chamador.

-- Painel e backend: criar agendamento e cancelar o aviso. As duas conferem o tenant
-- da sessão por dentro.
revoke all on function public.criar_agendamento(uuid, uuid, uuid, uuid, timestamptz, text) from public;
grant execute on function public.criar_agendamento(uuid, uuid, uuid, uuid, timestamptz, text)
  to authenticated, service_role;

revoke all on function public.cancelar_lembretes_do_agendamento(uuid) from public;
grant execute on function public.cancelar_lembretes_do_agendamento(uuid)
  to authenticated, service_role;

-- Infraestrutura de entrega: só o backend. Painel que pudesse reservar a fila
-- conseguiria ler evento de outro tenant, porque poller não filtra por tenant.
revoke all on function public.agendar_lembrete(uuid) from public;
grant execute on function public.agendar_lembrete(uuid) to service_role;

revoke all on function public.reservar_eventos_saida(integer, interval, integer) from public;
grant execute on function public.reservar_eventos_saida(integer, interval, integer) to service_role;

revoke all on function public.reservar_lembretes_devidos(integer, interval, integer) from public;
grant execute on function public.reservar_lembretes_devidos(integer, interval, integer) to service_role;

revoke all on function public.marcar_evento_entregue(uuid) from public;
grant execute on function public.marcar_evento_entregue(uuid) to service_role;

revoke all on function public.marcar_lembrete_enviado(uuid) from public;
grant execute on function public.marcar_lembrete_enviado(uuid) to service_role;

revoke all on function public.registrar_falha(text, text, jsonb, text, uuid) from public;
grant execute on function public.registrar_falha(text, text, jsonb, text, uuid) to service_role;

revoke all on function public.registrar_falha_do_evento(uuid, text, integer) from public;
grant execute on function public.registrar_falha_do_evento(uuid, text, integer) to service_role;

revoke all on function public.registrar_falha_do_lembrete(uuid, text, integer) from public;
grant execute on function public.registrar_falha_do_lembrete(uuid, text, integer) to service_role;

-- ao_mudar_agendamento() fica com o EXECUTE padrão: é função de gatilho, disparada
-- pelo UPDATE do painel, e revogá-la de PUBLIC só criaria risco de o gatilho não
-- rodar. Ela não aceita argumento e não é chamável de forma útil por fora.
