-- 0002-infra-entrega.sql
--
-- Garante a entrega: nada que o sistema prometeu entregar depende de um processo
-- ficar de pé. webhooks_recebidos dá idempotência na borda (evento do gateway só
-- entra uma vez), eventos_saida é o outbox (gravado na mesma transação do fato, lido
-- por poller), lembretes é o relógio durável da régua da seção 6, mensagens_enviadas
-- deduplica o envio e fila_morta guarda o que esgotou retry para um humano ver.
-- Os dois índices parciais no fim de cada bloco de poller são o que faz o Schedule
-- Trigger de 1 minuto custar nada: ele não varre a tabela, só o que está pendente.

set search_path = public;


-- ---------------------------------------------------------------------------
-- webhooks_recebidos — idempotência da borda.
-- Sem tenant_id de propósito: o webhook de pagamento chega ANTES de o tenant
-- existir (fluxo A), então não há dono para filtrar. Fica fechada para usuário
-- final em 0003.
-- ---------------------------------------------------------------------------
create table public.webhooks_recebidos (
  id                uuid        primary key default gen_random_uuid(),
  gateway           text        not null check (gateway in ('mercadopago', 'asaas', 'stripe')),
  -- O par (gateway, evento_externo_id) é a chave de idempotência: o INSERT ... ON
  -- CONFLICT DO NOTHING do passo 3 do fluxo A depende desta UNIQUE para que a
  -- reentrega do gateway encerre sozinha, sem reprocessar.
  evento_externo_id text        not null,
  -- Hash do corpo, não o corpo: serve para detectar o gateway mandando conteúdo
  -- diferente sob o mesmo id, sem guardar payload de pagamento no banco.
  corpo_hash        text        not null check (corpo_hash ~ '^[0-9a-f]{64}$'),
  recebido_em       timestamptz not null default now(),
  processado_em     timestamptz,
  resultado         text        check (resultado is null or resultado in
                                  ('provisionado', 'atualizado', 'ignorado', 'erro')),
  erro              text,
  unique (gateway, evento_externo_id)
);

-- O que entrou e nunca fechou o ciclo: é por aqui que se vê webhook aceito e
-- abandonado no meio.
create index webhooks_recebidos_abertos on public.webhooks_recebidos (recebido_em)
  where processado_em is null;


-- ---------------------------------------------------------------------------
-- eventos_saida — outbox. O `id` desta linha é o `id` do envelope da seção 3, ou
-- seja, a chave de idempotência que o consumidor usa. Por isso ele é gerado aqui e
-- não no n8n.
-- ---------------------------------------------------------------------------
create table public.eventos_saida (
  id            uuid        primary key default gen_random_uuid(),
  tenant_id     uuid        not null references public.tenants (id) on delete cascade,
  evento        text        not null,
  versao        integer     not null default 1 check (versao >= 1),
  dados         jsonb       not null default '{}'::jsonb,
  criado_em     timestamptz not null default now(),
  entregue_em   timestamptz,
  tentativas    integer     not null default 0 check (tentativas >= 0),
  ultimo_erro   text,
  -- Lease de reserva. FOR UPDATE SKIP LOCKED só protege enquanto a transação do
  -- poller está aberta; a chamada da função commita e solta o lock, e o poller
  -- seguinte pegaria a mesma linha enquanto o n8n ainda está entregando. Com o
  -- lease, a linha fica invisível para outros workers até reservado_ate passar.
  reservado_ate timestamptz,
  -- Esgotou o retry: sai do índice do poller e vai para fila_morta. Sem esta coluna
  -- o evento morto ficaria para sempre com entregue_em nulo, engordando o índice
  -- parcial que existe justamente para ser pequeno.
  abandonado_em timestamptz
);

-- O índice do poller do outbox (fluxo B, reconciliador de 1 min). Parcial: só linha
-- pendente entra. Numa base com milhões de eventos entregues, ele continua do tamanho
-- da fila, não do tamanho da tabela.
create index eventos_saida_pendentes on public.eventos_saida (criado_em)
  where entregue_em is null and abandonado_em is null;

create index eventos_saida_por_tenant on public.eventos_saida (tenant_id, criado_em desc);


-- ---------------------------------------------------------------------------
-- lembretes — o relógio durável. A régua da seção 6 produz UMA linha por
-- agendamento, e esse número é a variável de custo da precificação.
-- ---------------------------------------------------------------------------
create table public.lembretes (
  id             uuid        primary key default gen_random_uuid(),
  tenant_id      uuid        not null references public.tenants (id) on delete cascade,
  agendamento_id uuid        not null references public.agendamentos (id) on delete cascade,
  -- Os dois braços da régua, e só eles: 'lembrete_2h' para quem marcou com mais de
  -- 2h de antecedência, 'imediato' para quem marcou em cima da hora.
  tipo           text        not null check (tipo in ('lembrete_2h', 'imediato')),
  disparar_em    timestamptz not null,
  canal          text        not null check (canal in ('whatsapp', 'email')),
  destino        text        not null,
  status         text        not null default 'pendente'
                             check (status in ('pendente', 'enviado', 'cancelado', 'falhou')),
  tentativas     integer     not null default 0 check (tentativas >= 0),
  ultimo_erro    text,
  reservado_ate  timestamptz,
  enviado_em     timestamptz,
  criado_em      timestamptz not null default now(),

  -- O destino tem de combinar com o canal, senão o erro só aparece na hora do envio.
  constraint lembretes_destino_coerente check (
    (canal = 'whatsapp' and destino ~ '^[1-9][0-9]{7,14}$')
    or (canal = 'email' and destino like '%_@_%._%')
  ),
  constraint lembretes_enviado_tem_data check (
    (status = 'enviado') = (enviado_em is not null)
  )
);

-- A seção 6 escrita como constraint: um lembrete por agendamento. Remarcar cancela o
-- anterior e cria o novo (o 'cancelado' libera a vaga); 'falhou' continua ocupando,
-- porque a tentativa já foi paga.
create unique index lembretes_um_por_agendamento on public.lembretes (agendamento_id)
  where status <> 'cancelado';

-- O índice do poller de lembretes. Parcial em 'pendente' pelo mesmo motivo do outbox:
-- lembrete enviado é a maioria absoluta das linhas e não interessa ao relógio.
create index lembretes_devidos on public.lembretes (disparar_em)
  where status = 'pendente';


-- ---------------------------------------------------------------------------
-- mensagens_enviadas — log e dedupe de envio. A chave de dedupe é o que impede o
-- cliente de receber a mesma mensagem duas vezes quando o n8n reentrega.
-- ---------------------------------------------------------------------------
create table public.mensagens_enviadas (
  id                   uuid        primary key default gen_random_uuid(),
  tenant_id            uuid        not null references public.tenants (id) on delete cascade,
  -- Normalmente "<evento_id>:<canal>:<destino>" ou "<lembrete_id>:<canal>". Quem monta
  -- é o workflow de envio; o banco só garante que ela não repete dentro do tenant.
  chave_dedupe         text        not null,
  canal                text        not null check (canal in ('whatsapp', 'email')),
  destino              text        not null,
  -- Guarda template e variáveis, não o texto final: o corpo renderizado é o dado
  -- pessoal mais exposto do sistema e não acrescenta nada ao suporte.
  template             text,
  variaveis            jsonb       not null default '{}'::jsonb,
  lembrete_id          uuid        references public.lembretes (id) on delete set null,
  provedor_mensagem_id text,
  status               text        not null default 'enviada'
                                   check (status in ('enviada', 'entregue', 'lida', 'falhou')),
  erro                 text,
  enviado_em           timestamptz not null default now(),
  unique (tenant_id, chave_dedupe)
);

create index mensagens_enviadas_recentes on public.mensagens_enviadas (tenant_id, enviado_em desc);


-- ---------------------------------------------------------------------------
-- primeiro_acesso — token one-time do fluxo A. Guarda o HASH, nunca o token: o token
-- existe só dentro do link que sai para o dono. Vazamento desta tabela não dá acesso
-- a conta nenhuma.
-- ---------------------------------------------------------------------------
create table public.primeiro_acesso (
  id         uuid        primary key default gen_random_uuid(),
  tenant_id  uuid        not null references public.tenants (id) on delete cascade,
  usuario_id uuid        not null references auth.users (id) on delete cascade,
  -- sha256 em hex minúsculo. O CHECK é estrutural: string com 64 hex não é token
  -- utilizável, então ela denuncia quem tentar gravar o token cru aqui.
  token_hash text        not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  -- TTL de 72h (fluxo A). Default no banco para que esquecer de passar o prazo não
  -- gere token eterno.
  expira_em  timestamptz not null default now() + interval '72 hours',
  usado_em   timestamptz,
  criado_em  timestamptz not null default now(),
  constraint primeiro_acesso_prazo_futuro check (expira_em > criado_em)
);

create index primeiro_acesso_por_usuario on public.primeiro_acesso (usuario_id)
  where usado_em is null;


-- ---------------------------------------------------------------------------
-- fila_morta — o que esgotou retry. tenant_id é nulável porque a falha pode ocorrer
-- antes de existir tenant (webhook de pagamento que não normaliza).
-- ---------------------------------------------------------------------------
create table public.fila_morta (
  id          uuid        primary key default gen_random_uuid(),
  tenant_id   uuid        references public.tenants (id) on delete set null,
  origem      text        not null,
  evento      text,
  payload     jsonb       not null default '{}'::jsonb,
  erro        text        not null,
  criado_em   timestamptz not null default now(),
  revisado_em timestamptz,
  revisado_por text
);

create index fila_morta_abertas on public.fila_morta (criado_em desc) where revisado_em is null;
