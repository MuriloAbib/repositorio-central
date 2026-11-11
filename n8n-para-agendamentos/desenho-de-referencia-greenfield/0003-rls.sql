-- 0003-rls.sql
--
-- Garante o isolamento entre barbearias dentro do banco. Um SaaS onde a agenda de um
-- estabelecimento pode ser lida pela conta de outro é incidente de dados, não bug —
-- por isso o filtro não fica em nenhum WHERE de aplicação, onde um endpoint esquecido
-- vaza tudo: fica em policy, que vale para qualquer consulta, inclusive a que ainda
-- não foi escrita. O tenant da sessão vem SEMPRE do JWT (tenant_atual()), nunca do
-- corpo do pedido. Tabela de infraestrutura fica com RLS ligada e ZERO policy.
-- Este arquivo depende de papéis e do schema `auth` do Supabase (anon, authenticated,
-- service_role, auth.jwt()).

set search_path = public;


-- ---------------------------------------------------------------------------
-- tenant_atual() — o tenant da sessão
-- ---------------------------------------------------------------------------
-- app_metadata e NÃO user_metadata. user_metadata é escrito pelo próprio usuário
-- (supabase.auth.updateUser do navegador): ler o tenant de lá é entregar a agenda do
-- vizinho a quem editar um campo do próprio perfil. app_metadata só muda pela Admin
-- API com a service_role, isto é, do lado do servidor.
--
-- Dois efeitos que um revisor precisa conhecer:
--  - sem o claim (service_role, token anônimo) a função devolve NULL, e `tenant_id =
--    NULL` é NULL, nunca true: a política nega por omissão.
--  - o claim é estampado na emissão do token, então mudar app_metadata só vale depois
--    do refresh. Tirar alguém de um tenant exige revogar a sessão, não só o vínculo.
create or replace function public.tenant_atual()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(auth.jwt() -> 'app_metadata' ->> 'tenant_id', '')::uuid
$$;

revoke all on function public.tenant_atual() from public;
grant execute on function public.tenant_atual() to authenticated, service_role;


-- ---------------------------------------------------------------------------
-- anon não entra em lugar nenhum
-- ---------------------------------------------------------------------------
-- Nada neste produto é público-anônimo: a página de agendamento do cliente final fala
-- com Edge Function (service_role), não com o PostgREST pela anon key. Deixar a anon
-- com privilégio de tabela é apostar que toda policy futura vai estar certa.
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;


-- ---------------------------------------------------------------------------
-- Onde FORCE ROW LEVEL SECURITY entra, e onde não entra de propósito
-- ---------------------------------------------------------------------------
-- FORCE faz a policy valer também para o dono da tabela, o que fecha a porta de uma
-- função SECURITY DEFINER escrita no futuro ler fora do tenant. Ele está ligado em
-- usuarios_tenant, assinaturas, mensagens_enviadas, primeiro_acesso e
-- webhooks_recebidos: nenhuma função toca nelas, só a service_role escreve.
-- Ele NÃO está ligado em tenants, barbeiros, servicos, clientes, agendamentos,
-- lembretes, eventos_saida e fila_morta porque as funções SECURITY DEFINER de
-- 0004-funcoes.sql leem e escrevem nelas em nome do dono, e as policies dependem de um
-- JWT de usuário que o backend não carrega ao chamar como service_role: com FORCE,
-- criar_agendamento não acharia o cliente e os pollers voltariam vazios. A proteção
-- dessas tabelas é a própria função, que confere o tenant antes de tocar na linha.


-- ===========================================================================
-- tenants — a raiz. Aqui o próprio id é o tenant.
-- ===========================================================================
alter table public.tenants enable row level security;

grant select, update on public.tenants to authenticated;
grant all on public.tenants to service_role;

create policy tenants_le_o_proprio on public.tenants
  for select to authenticated
  using (id = public.tenant_atual());

-- using = quais linhas posso alterar; with check = em que estado posso deixá-las.
-- Sem o with check, um UPDATE poderia mover a linha para outro tenant e ela sairia do
-- alcance do dono original — vale para todas as tabelas daqui para baixo.
create policy tenants_altera_o_proprio on public.tenants
  for update to authenticated
  using (id = public.tenant_atual())
  with check (id = public.tenant_atual());

-- Sem policy de INSERT nem de DELETE, de propósito: tenant nasce no provisionamento
-- (fluxo A, service_role) e morre por status = 'cancelado'. Conta de painel não cria
-- nem apaga barbearia.


-- ===========================================================================
-- usuarios_tenant — vínculo de conta. Só leitura para o painel.
-- ===========================================================================
alter table public.usuarios_tenant enable row level security;
alter table public.usuarios_tenant force row level security;

grant select on public.usuarios_tenant to authenticated;
grant all on public.usuarios_tenant to service_role;

create policy usuarios_tenant_le_os_do_tenant on public.usuarios_tenant
  for select to authenticated
  using (tenant_id = public.tenant_atual());

-- Sem INSERT/UPDATE/DELETE para authenticated: quem define vínculo e papel é o
-- provisionamento com service_role. Se o painel pudesse escrever aqui, 'recepcao'
-- se promoveria a 'dono' com um PATCH.


-- ===========================================================================
-- barbeiros — CRUD do painel, preso ao tenant.
-- ===========================================================================
-- Sem FORCE: criar_agendamento (DEFINER) confere o barbeiro contra o tenant do pedido.
alter table public.barbeiros enable row level security;

grant select, insert, update, delete on public.barbeiros to authenticated;
grant all on public.barbeiros to service_role;

create policy barbeiros_le on public.barbeiros
  for select to authenticated
  using (tenant_id = public.tenant_atual());

create policy barbeiros_cria on public.barbeiros
  for insert to authenticated
  with check (tenant_id = public.tenant_atual());

create policy barbeiros_altera on public.barbeiros
  for update to authenticated
  using (tenant_id = public.tenant_atual())
  with check (tenant_id = public.tenant_atual());

create policy barbeiros_apaga on public.barbeiros
  for delete to authenticated
  using (tenant_id = public.tenant_atual());


-- ===========================================================================
-- servicos
-- ===========================================================================
-- Sem FORCE: lido por criar_agendamento e reservar_lembretes_devidos (DEFINER).
alter table public.servicos enable row level security;

grant select, insert, update, delete on public.servicos to authenticated;
grant all on public.servicos to service_role;

create policy servicos_le on public.servicos
  for select to authenticated
  using (tenant_id = public.tenant_atual());

create policy servicos_cria on public.servicos
  for insert to authenticated
  with check (tenant_id = public.tenant_atual());

create policy servicos_altera on public.servicos
  for update to authenticated
  using (tenant_id = public.tenant_atual())
  with check (tenant_id = public.tenant_atual());

create policy servicos_apaga on public.servicos
  for delete to authenticated
  using (tenant_id = public.tenant_atual());


-- ===========================================================================
-- clientes
-- ===========================================================================
-- Sem FORCE: agendar_lembrete (DEFINER) lê daqui o canal e o destino do aviso.
alter table public.clientes enable row level security;

grant select, insert, update, delete on public.clientes to authenticated;
grant all on public.clientes to service_role;

create policy clientes_le on public.clientes
  for select to authenticated
  using (tenant_id = public.tenant_atual());

create policy clientes_cria on public.clientes
  for insert to authenticated
  with check (tenant_id = public.tenant_atual());

create policy clientes_altera on public.clientes
  for update to authenticated
  using (tenant_id = public.tenant_atual())
  with check (tenant_id = public.tenant_atual());

-- DELETE liberado para atender pedido de exclusão (LGPD). Cliente com histórico é
-- barrado pelo ON DELETE RESTRICT de agendamentos: nesse caso a exclusão se faz
-- anonimizando a linha, porque apagar a agenda apagaria registro de serviço prestado.
create policy clientes_apaga on public.clientes
  for delete to authenticated
  using (tenant_id = public.tenant_atual());


-- ===========================================================================
-- agendamentos
-- ===========================================================================
alter table public.agendamentos enable row level security;

grant select, insert, update on public.agendamentos to authenticated;
grant all on public.agendamentos to service_role;

create policy agendamentos_le on public.agendamentos
  for select to authenticated
  using (tenant_id = public.tenant_atual());

-- INSERT direto existe para bloqueio de agenda feito no painel. O caminho normal é
-- criar_agendamento(), que além de gravar emite o evento e cria o lembrete na mesma
-- transação; INSERT cru grava a agenda e não avisa ninguém.
create policy agendamentos_cria on public.agendamentos
  for insert to authenticated
  with check (tenant_id = public.tenant_atual());

create policy agendamentos_altera on public.agendamentos
  for update to authenticated
  using (tenant_id = public.tenant_atual())
  with check (tenant_id = public.tenant_atual());

-- Sem policy de DELETE, de propósito: cancelar é status = 'cancelado', que libera o
-- horário na constraint de exclusão, mata o lembrete e emite agendamento.cancelado
-- pelo gatilho de 0004. DELETE faria as três coisas desaparecerem em silêncio, e o
-- cliente ainda receberia o lembrete de um corte que ninguém sabe que existiu.


-- ===========================================================================
-- assinaturas — leitura do dono, escrita só do fluxo de pagamento.
-- ===========================================================================
alter table public.assinaturas enable row level security;
alter table public.assinaturas force row level security;

grant select on public.assinaturas to authenticated;
grant all on public.assinaturas to service_role;

create policy assinaturas_le on public.assinaturas
  for select to authenticated
  using (tenant_id = public.tenant_atual());

-- Sem escrita para authenticated: o estado da assinatura é o que o gateway disse, e
-- vem pelo webhook normalizado. Painel que pudesse escrever aqui se auto-renovaria.


-- ===========================================================================
-- lembretes — leitura do painel (ver o que vai sair), escrita pelas funções.
-- ===========================================================================
alter table public.lembretes enable row level security;

grant select on public.lembretes to authenticated;
grant all on public.lembretes to service_role;

create policy lembretes_le on public.lembretes
  for select to authenticated
  using (tenant_id = public.tenant_atual());

-- Sem escrita para authenticated: a régua da seção 6 é uma mensagem por agendamento,
-- e essa mensagem é custo. Quem cria e cancela lembrete são as funções de 0004.


-- ===========================================================================
-- mensagens_enviadas — log, leitura do tenant.
-- ===========================================================================
alter table public.mensagens_enviadas enable row level security;
alter table public.mensagens_enviadas force row level security;

grant select on public.mensagens_enviadas to authenticated;
grant all on public.mensagens_enviadas to service_role;

create policy mensagens_enviadas_le on public.mensagens_enviadas
  for select to authenticated
  using (tenant_id = public.tenant_atual());

-- Sem escrita para authenticated: quem grava é o workflow de envio, e a UNIQUE
-- (tenant_id, chave_dedupe) é a trava contra envio dobrado. Deixar o painel inserir
-- aqui permitiria queimar a chave de dedupe de uma mensagem que ainda não saiu.


-- ===========================================================================
-- primeiro_acesso — RLS ligada, NENHUMA policy. Nem o dono lê.
-- ===========================================================================
-- Hash de token one-time não é dado de painel. Quem cria é o provisionamento e quem
-- consome é a Edge Function de troca de senha, ambos com service_role (que tem
-- BYPASSRLS e por isso passa sem policy). Policy de leitura aqui transformaria
-- "vazou o token do link" em "vazou a lista de links de todo mundo".
alter table public.primeiro_acesso enable row level security;
alter table public.primeiro_acesso force row level security;

revoke all on public.primeiro_acesso from anon, authenticated;
grant all on public.primeiro_acesso to service_role;


-- ===========================================================================
-- Infraestrutura: eventos_saida, webhooks_recebidos, fila_morta
-- ===========================================================================
-- As três têm RLS ligada e nenhuma policy permissiva: para anon e authenticated elas
-- simplesmente não existem, em SELECT, INSERT, UPDATE e DELETE. Só service_role entra
-- (BYPASSRLS), e o dono das funções de 0004 escreve nelas como SECURITY DEFINER.
-- Por que fechar: eventos_saida carrega `dados` com nome e telefone de cliente e, no
-- tenant.provisionado, credencial de primeiro acesso; webhooks_recebidos é a trava de
-- idempotência do pagamento, e quem consegue inserir nela consegue fazer um webhook
-- legítimo ser descartado como duplicado; fila_morta guarda payload de falha, que é o
-- lugar mais fácil de achar dado cru.
alter table public.eventos_saida enable row level security;
revoke all on public.eventos_saida from anon, authenticated;
grant all on public.eventos_saida to service_role;

alter table public.webhooks_recebidos enable row level security;
alter table public.webhooks_recebidos force row level security;
revoke all on public.webhooks_recebidos from anon, authenticated;
grant all on public.webhooks_recebidos to service_role;

alter table public.fila_morta enable row level security;
revoke all on public.fila_morta from anon, authenticated;
grant all on public.fila_morta to service_role;
