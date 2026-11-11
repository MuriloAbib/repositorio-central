-- 0012-reserva-de-fila.sql
--
-- Como o n8n tira trabalho da fila sem que dois workers peguem a mesma linha.
--
-- O problema concreto: em queue mode o n8n roda N workers. Se o poller fosse
-- "SELECT ... WHERE entregue_em IS NULL LIMIT 10", os dois workers leriam as
-- MESMAS dez linhas no mesmo segundo e o cliente receberia tudo em dobro. E
-- "SELECT ... FOR UPDATE" sem SKIP LOCKED não resolve: o segundo worker fica
-- bloqueado esperando o primeiro, e a vazão da fila cai para a de um worker só.
--
-- FOR UPDATE SKIP LOCKED é o que dá as duas coisas: exclusividade e paralelismo.
-- O segundo worker não espera — ele pula as linhas travadas e pega as próximas.
--
-- Em cima disso há um LEASE (reservado_ate). SKIP LOCKED só protege durante a
-- transação; quando ela commita, a linha destrava. Se o worker morrer DEPOIS do
-- commit da reserva e ANTES de entregar, sem lease a linha ficaria "reservada"
-- para sempre e o evento nunca sairia. O lease expira e a linha volta à fila.

set search_path = public;

-- ---------------------------------------------------------------------------
-- reservar_eventos_saida — o poller do outbox (workflow 03).
-- ---------------------------------------------------------------------------
create or replace function public.reservar_eventos_saida(
  p_limite        integer default 20,
  p_lease_segundos integer default 120,
  p_max_tentativas integer default 6
)
returns table (
  id         uuid,
  owner_id   uuid,
  evento     text,
  versao     integer,
  dados      jsonb,
  tentativas integer
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with candidatos as (
    select e.id
      from public.eventos_saida e
     where e.entregue_em is null
       and e.tentativas < p_max_tentativas
       -- livre, ou com lease vencido (worker que morreu no meio)
       and (e.reservado_ate is null or e.reservado_ate < now())
     order by e.criado_em
     limit p_limite
     for update skip locked
  )
  update public.eventos_saida e
     set reservado_ate = now() + (p_lease_segundos * interval '1 second'),
         tentativas    = e.tentativas + 1
    from candidatos c
   where e.id = c.id
  returning e.id, e.owner_id, e.evento, e.versao, e.dados, e.tentativas;
end;
$$;

-- Incrementar tentativas NA RESERVA, e não na falha, é deliberado: worker que
-- morre sem reportar nada ainda consome uma tentativa. Se o contador só subisse
-- no caminho de erro, um evento que derruba o worker toda vez (payload que
-- quebra o parser, por exemplo) seria tentado para sempre.

-- ---------------------------------------------------------------------------
-- reservar_lembretes_devidos — o poller da régua (workflow 04).
-- ---------------------------------------------------------------------------
create or replace function public.reservar_lembretes_devidos(
  p_limite         integer default 50,
  p_lease_segundos integer default 300,
  p_max_tentativas integer default 4
)
returns table (
  id             uuid,
  owner_id       uuid,
  appointment_id uuid,
  tipo           text,
  canal          text,
  destino        text,
  tentativas     integer,
  dados          jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with candidatos as (
    select l.id
      from public.lembretes l
     where l.status = 'pendente'
       and l.disparar_em <= now()
       and l.tentativas < p_max_tentativas
       and (l.reservado_ate is null or l.reservado_ate < now())
     order by l.disparar_em
     limit p_limite
     for update skip locked
  )
  update public.lembretes l
     set reservado_ate = now() + (p_lease_segundos * interval '1 second'),
         tentativas    = l.tentativas + 1
    from candidatos c
   where l.id = c.id
  returning
    l.id, l.owner_id, l.appointment_id, l.tipo, l.canal, l.destino, l.tentativas,
    -- O contexto vai junto para o n8n não precisar de uma segunda consulta por
    -- lembrete. Com 50 lembretes por rodada, isso é 1 consulta em vez de 51.
    public.contexto_do_agendamento(l.appointment_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Marcar resultado.
-- ---------------------------------------------------------------------------
create or replace function public.marcar_evento_entregue(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.eventos_saida
     set entregue_em   = now(),
         reservado_ate = null,
         ultimo_erro   = null
   where id = p_id;
end;
$$;

create or replace function public.marcar_evento_falhou(p_id uuid, p_erro text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Libera o lease para a próxima rodada tentar de novo. tentativas já subiu na
  -- reserva, então não sobe aqui — subir nos dois lugares faria o teto de
  -- tentativas valer pela metade.
  update public.eventos_saida
     set reservado_ate = null,
         ultimo_erro   = left(coalesce(p_erro, 'erro sem mensagem'), 2000)
   where id = p_id;
end;
$$;

create or replace function public.marcar_lembrete_enviado(p_id uuid)
returns void
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
   where id = p_id;
end;
$$;

create or replace function public.marcar_lembrete_falhou(p_id uuid, p_erro text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tentativas integer;
  v_max        integer := 4;
begin
  update public.lembretes
     set reservado_ate = null,
         ultimo_erro   = left(coalesce(p_erro, 'erro sem mensagem'), 2000)
   where id = p_id
  returning tentativas into v_tentativas;

  -- Esgotou: marca falhou e registra, para o lembrete não ficar rodando em
  -- círculo e para alguém poder olhar.
  if v_tentativas is not null and v_tentativas >= v_max then
    update public.lembretes set status = 'falhou' where id = p_id;

    insert into public.fila_morta (owner_id, origem, evento, payload, erro, tentativas)
    select l.owner_id,
           'lembrete',
           'lembrete.' || l.tipo,
           jsonb_build_object(
             'lembrete_id',    l.id,
             'appointment_id', l.appointment_id,
             'canal',          l.canal,
             'destino',        l.destino
           ),
           coalesce(p_erro, 'esgotou tentativas'),
           l.tentativas
      from public.lembretes l
     where l.id = p_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Diagnóstico — o que olhar todo dia.
-- ---------------------------------------------------------------------------
-- View, e não consulta solta na documentação, porque consulta em documentação
-- apodrece em silêncio quando o schema muda.
create or replace view public.automacao_saude as
select
  (select count(*) from public.eventos_saida
    where entregue_em is null and criado_em < now() - interval '10 minutes')
    as eventos_presos,
  (select count(*) from public.lembretes
    where status = 'pendente' and disparar_em < now() - interval '15 minutes')
    as lembretes_atrasados,
  (select count(*) from public.lembretes where status = 'falhou')
    as lembretes_falhados,
  (select count(*) from public.fila_morta where resolvido_em is null)
    as fila_morta_aberta,
  (select count(*) from public.webhooks_recebidos
    where processado_em is null and recebido_em < now() - interval '10 minutes')
    as webhooks_nao_processados;

comment on view public.automacao_saude is
  'Quatro numeros que devem ser zero. Qualquer um diferente de zero significa cliente nao avisado.';
