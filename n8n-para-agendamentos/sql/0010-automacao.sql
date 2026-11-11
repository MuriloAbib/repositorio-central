-- 0010-automacao.sql
--
-- A camada de automação, encaixada no schema REAL do BarberBook (FastChair).
--
-- Não cria nem altera nenhuma tabela de domínio existente (profiles, barbers,
-- staff, services, products, appointments, appointment_products,
-- commission_entries, commission_payments). Só acrescenta a infraestrutura que
-- hoje não existe: idempotência de webhook, outbox de evento, relógio durável
-- de lembrete, log/dedupe de mensagem e fila morta.
--
-- A tenancy do BarberBook é por USUÁRIO DONO, não por tabela de inquilino:
-- appointments.barber_id, services.barber_id, products.barber_id e
-- staff.owner_id são todos o auth.users.id do dono da barbearia. Esta camada
-- segue a mesma convenção e chama essa coluna de owner_id — inventar um
-- tenant_id aqui criaria duas noções de inquilino no mesmo banco, e a consulta
-- que esquecesse de casar as duas vazaria dado entre barbearias.
--
-- Rodar DEPOIS das migrações existentes do projeto (supabase/migrations/).

set search_path = public;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- webhooks_recebidos — idempotência da borda.
-- ---------------------------------------------------------------------------
-- O Stripe entrega at-least-once: retenta em timeout, em 5xx e em deploy. Sem
-- esta tabela, a reentrega de um checkout.session.completed reexecuta o
-- provisionamento inteiro — e no código atual isso RESETA a senha do dono
-- (ver docs/02-defeitos-encontrados.md, defeito 1).
--
-- A unicidade é (gateway, evento_externo_id) e não só evento_externo_id:
-- id do Stripe e id do Mercado Pago vivem em espaços separados e podem colidir.
create table if not exists public.webhooks_recebidos (
  id                 uuid        primary key default gen_random_uuid(),
  gateway            text        not null check (gateway in ('stripe', 'mercadopago', 'asaas')),
  evento_externo_id  text        not null,
  tipo_externo       text,
  corpo_hash         text        not null,
  recebido_em        timestamptz not null default now(),
  processado_em      timestamptz,
  resultado          text        check (resultado is null or resultado in ('ok', 'ignorado', 'falhou')),
  erro               text,
  tentativas         integer     not null default 0,

  constraint webhooks_recebidos_unico unique (gateway, evento_externo_id)
);

-- O corpo_hash não é decoração: dois eventos com o MESMO id externo e corpos
-- diferentes significam que alguém está forjando reentrega, ou que o gateway
-- mudou o payload. Vale alarme, não processamento silencioso.
create index if not exists webhooks_recebidos_pendentes
  on public.webhooks_recebidos (recebido_em)
  where processado_em is null;

-- ---------------------------------------------------------------------------
-- eventos_saida — o outbox.
-- ---------------------------------------------------------------------------
-- Gravado na MESMA transação do appointments (ver 0011). É isso que resolve o
-- problema que "gravar e depois chamar o n8n" não resolve: se o processo morre
-- entre o commit e a chamada, o agendamento existe e o aviso nunca sai. Com o
-- outbox, o evento commitou junto; o reconciliador entrega depois.
create table if not exists public.eventos_saida (
  id          uuid        primary key default gen_random_uuid(),
  owner_id    uuid        not null references auth.users (id) on delete cascade,
  evento      text        not null,
  versao      integer     not null default 1,
  dados       jsonb       not null,
  criado_em   timestamptz not null default now(),

  -- lease: quem reservou e até quando. Sem o lease, um worker que travou
  -- segura o evento para sempre; com ele, o evento volta para a fila.
  reservado_ate timestamptz,
  entregue_em   timestamptz,
  tentativas    integer     not null default 0,
  ultimo_erro   text
);

-- Índice parcial: o poller roda a cada minuto e só olha o que falta entregar.
-- Sem o WHERE, a varredura cresce com o histórico inteiro e o custo do poller
-- aumenta para sempre, mesmo com a fila vazia.
create index if not exists eventos_saida_a_entregar
  on public.eventos_saida (criado_em)
  where entregue_em is null;

create index if not exists eventos_saida_por_owner
  on public.eventos_saida (owner_id, criado_em desc);

-- ---------------------------------------------------------------------------
-- lembretes — o relógio durável.
-- ---------------------------------------------------------------------------
-- Por que tabela + poller, e não o nó Wait do n8n: um Wait de 2h vive dentro de
-- uma execução. Execução perdida (restart, redeploy, limpeza de histórico,
-- queda do worker) = lembrete que nunca dispara, e ninguém fica sabendo. A
-- linha no banco sobrevive a tudo isso e é auditável: dá para perguntar "o que
-- deveria ter saído e não saiu".
create table if not exists public.lembretes (
  id             uuid        primary key default gen_random_uuid(),
  owner_id       uuid        not null references auth.users (id) on delete cascade,
  appointment_id uuid        not null references public.appointments (id) on delete cascade,
  tipo           text        not null default 'confirmacao'
                             check (tipo in ('confirmacao', 'lembrete', 'pos_atendimento')),
  disparar_em    timestamptz not null,
  canal          text        not null check (canal in ('whatsapp', 'email')),
  destino        text        not null,
  status         text        not null default 'pendente'
                             check (status in ('pendente', 'enviado', 'cancelado', 'falhou')),
  tentativas     integer     not null default 0,
  reservado_ate  timestamptz,
  enviado_em     timestamptz,
  ultimo_erro    text,
  criado_em      timestamptz not null default now(),

  -- Um lembrete de cada tipo por agendamento. É esta constraint que mantém o
  -- custo por agendamento sendo UM número conhecido, e não uma estimativa:
  -- remarcar reaproveita a linha em vez de criar outra. O vault registra que
  -- sem o custo por mensagem não há como fechar precificação — duplicar
  -- lembrete por acidente quebraria a conta antes de ela existir.
  constraint lembretes_um_por_tipo unique (appointment_id, tipo)
);

create index if not exists lembretes_devidos
  on public.lembretes (disparar_em)
  where status = 'pendente';

-- ---------------------------------------------------------------------------
-- mensagens_enviadas — log e dedupe de saída.
-- ---------------------------------------------------------------------------
-- A chave de dedupe é construída por quem envia e descreve O QUE a mensagem é
-- (ex: 'lembrete:<lembrete_id>', 'novo-agendamento:<appointment_id>'), nunca um
-- timestamp nem um aleatório — chave que muda a cada tentativa não deduplica
-- nada. A UNIQUE aqui é a única coisa entre uma reentrega do n8n e o cliente
-- recebendo a mesma mensagem duas vezes.
create table if not exists public.mensagens_enviadas (
  id            uuid        primary key default gen_random_uuid(),
  owner_id      uuid        not null references auth.users (id) on delete cascade,
  chave_dedupe  text        not null,
  canal         text        not null check (canal in ('whatsapp', 'email')),
  destino       text        not null,
  template      text,
  variaveis     jsonb,
  status        text        not null default 'reservado'
                            check (status in ('reservado', 'enviado', 'falhou')),
  provedor      text,
  provedor_id   text,
  erro          text,
  criado_em     timestamptz not null default now(),
  enviado_em    timestamptz,

  constraint mensagens_enviadas_unico unique (owner_id, chave_dedupe)
);

create index if not exists mensagens_enviadas_por_owner
  on public.mensagens_enviadas (owner_id, criado_em desc);

-- ---------------------------------------------------------------------------
-- fila_morta — o que esgotou retry.
-- ---------------------------------------------------------------------------
-- Falha silenciosa é o pior defeito possível numa infra de entrega: o sistema
-- parece funcionando e o cliente simplesmente não recebe. Tudo que desiste
-- para aqui, com payload suficiente para reprocessar à mão.
create table if not exists public.fila_morta (
  id          uuid        primary key default gen_random_uuid(),
  owner_id    uuid        references auth.users (id) on delete set null,
  origem      text        not null,
  evento      text,
  payload     jsonb,
  erro        text        not null,
  tentativas  integer,
  criado_em   timestamptz not null default now(),
  resolvido_em timestamptz,
  resolvido_por text
);

create index if not exists fila_morta_aberta
  on public.fila_morta (criado_em desc)
  where resolvido_em is null;

-- ---------------------------------------------------------------------------
-- primeiro_acesso — token one-time, substituindo a senha do CPF.
-- ---------------------------------------------------------------------------
-- Guarda SÓ o hash. Vazamento do banco não vira login, e nem o operador do
-- banco consegue entrar na conta de um cliente. Ver
-- docs/02-defeitos-encontrados.md defeito 1 para o que isto substitui.
create table if not exists public.primeiro_acesso (
  id          uuid        primary key default gen_random_uuid(),
  usuario_id  uuid        not null references auth.users (id) on delete cascade,
  token_hash  text        not null unique,
  expira_em   timestamptz not null,
  usado_em    timestamptz,
  criado_em   timestamptz not null default now()
);

create index if not exists primeiro_acesso_por_usuario
  on public.primeiro_acesso (usuario_id, criado_em desc);

-- ---------------------------------------------------------------------------
-- RLS — estas tabelas são fechadas para usuário final.
-- ---------------------------------------------------------------------------
-- RLS ligada e NENHUMA policy permissiva: com RLS ligada e zero policy, o
-- Postgres nega tudo. Só a service_role (que ignora RLS por definição) entra —
-- ou seja, só o servidor e o n8n. Isso é deliberado: nenhuma dessas tabelas
-- tem razão para aparecer no navegador do barbeiro, e `eventos_saida.dados`
-- carrega telefone de cliente.
--
-- FORCE é para o caso de uma função SECURITY DEFINER futura ser escrita pelo
-- dono dessas tabelas: sem FORCE, o dono da tabela escapa da própria RLS.
alter table public.webhooks_recebidos  enable row level security;
alter table public.webhooks_recebidos  force  row level security;
alter table public.eventos_saida       enable row level security;
alter table public.eventos_saida       force  row level security;
alter table public.lembretes           enable row level security;
alter table public.lembretes           force  row level security;
alter table public.mensagens_enviadas  enable row level security;
alter table public.mensagens_enviadas  force  row level security;
alter table public.fila_morta          enable row level security;
alter table public.fila_morta          force  row level security;
alter table public.primeiro_acesso     enable row level security;
alter table public.primeiro_acesso     force  row level security;

comment on table public.eventos_saida is
  'Outbox. Gravado na mesma transacao do appointments. Fechado para usuario final: contem telefone de cliente.';
comment on table public.lembretes is
  'Relogio duravel da regua. Um por (appointment_id, tipo) — e essa constraint que mantem o custo por agendamento previsivel.';
comment on table public.primeiro_acesso is
  'Token one-time de primeiro login. Guarda apenas o hash. Substitui a senha derivada de CPF.';
