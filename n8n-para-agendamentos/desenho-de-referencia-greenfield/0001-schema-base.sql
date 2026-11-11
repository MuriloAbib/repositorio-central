-- 0001-schema-base.sql
--
-- Garante o domínio da seção 4 da ESPECIFICACAO: a barbearia (tenant), sua equipe,
-- seus serviços, seus clientes, a agenda e a assinatura. Toda tabela de dado de
-- cliente nasce com tenant_id NOT NULL — é o que torna possível o isolamento de
-- 0003-rls.sql, porque nenhuma linha pode existir sem dono.
-- Garante também a invariante da agenda dentro do banco: dois agendamentos ativos
-- do mesmo barbeiro não se cruzam, nem quando dois pedidos chegam no mesmo instante.
-- Datas em timestamptz (UTC), dinheiro em centavos inteiros, telefone E.164 sem '+'.

-- O btree_gist dá ao índice gist o opclass de igualdade para uuid; sem ele o EXCLUDE
-- de `agendamentos` não compila. No Supabase a extensão mora no schema `extensions`,
-- que precisa estar no search_path desta sessão para o opclass ser encontrado na
-- criação da constraint. Schema inexistente no search_path é ignorado sem erro, então
-- a linha abaixo funciona tanto no Supabase quanto num Postgres cru.
set search_path = public, extensions;
create extension if not exists btree_gist;

-- Enums como CHECK e não como tipo próprio: acrescentar valor ('nao_compareceu', um
-- gateway novo) é um DROP/ADD CONSTRAINT numa migração comum, enquanto em tipo próprio
-- remover ou renomear valor exige recriar o tipo e todas as colunas que o usam, e
-- ALTER TYPE ... ADD VALUE tem restrição de uso na mesma transação.

-- E.164 sem '+' (seção 2): só dígitos, 8 a 15, não começa em zero. A inclusão do nono
-- dígito é trabalho da borda que normaliza; aqui fica a forma, que é o que o banco
-- consegue garantir — número de 10 dígitos não é necessariamente fixo.
create domain public.telefone_e164 as text
  check (value ~ '^[1-9][0-9]{7,14}$');

create or replace function public.tocar_atualizado_em()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;


-- ---------------------------------------------------------------------------
-- tenants — a barbearia. É a raiz do isolamento: o id daqui é o tenant_id de todas
-- as outras tabelas.
-- ---------------------------------------------------------------------------
create table public.tenants (
  id            uuid        primary key default gen_random_uuid(),
  nome          text        not null check (length(btrim(nome)) > 0),
  slug          text        not null unique check (slug ~ '^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])$'),
  status        text        not null default 'ativo'
                            check (status in ('ativo', 'suspenso', 'cancelado')),
  -- `plano` não é enum do domínio: o nome vem do catálogo de preços do gateway e muda
  -- sem migração. Quem valida plano é quem normaliza o pagamento.confirmado.
  plano         text        not null,
  fuso          text        not null default 'America/Sao_Paulo',
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create trigger tenants_atualizado_em
  before update on public.tenants
  for each row execute function public.tocar_atualizado_em();


-- ---------------------------------------------------------------------------
-- usuarios_tenant — liga auth.users ao tenant. É a tabela que responde "esta conta
-- pode ver esta barbearia?" para um humano; o JWT responde isso para o banco (0003).
-- ---------------------------------------------------------------------------
create table public.usuarios_tenant (
  id           uuid        primary key default gen_random_uuid(),
  tenant_id    uuid        not null references public.tenants (id) on delete cascade,
  usuario_id   uuid        not null references auth.users (id) on delete cascade,
  papel        text        not null check (papel in ('dono', 'barbeiro', 'recepcao')),
  trocar_senha boolean     not null default true,
  criado_em    timestamptz not null default now(),
  unique (tenant_id, usuario_id)
);

-- Uma conta pode pertencer a mais de uma barbearia (dono com duas lojas); o JWT fixa
-- qual delas está ativa na sessão. Este índice é a busca "de quais tenants este
-- usuário participa", feita no login.
create index usuarios_tenant_por_usuario on public.usuarios_tenant (usuario_id);
create index usuarios_tenant_donos on public.usuarios_tenant (tenant_id) where papel = 'dono';


-- ---------------------------------------------------------------------------
-- barbeiros — o profissional que atende. O dono é o primeiro barbeiro (fluxo A).
-- ---------------------------------------------------------------------------
create table public.barbeiros (
  id              uuid        primary key default gen_random_uuid(),
  tenant_id       uuid        not null references public.tenants (id) on delete cascade,
  nome            text        not null check (length(btrim(nome)) > 0),
  telefone        public.telefone_e164,
  canal_preferido text        not null default 'whatsapp'
                              check (canal_preferido in ('whatsapp', 'email')),
  -- Opcional de propósito: barbeiro que não usa o painel não precisa de conta.
  usuario_id      uuid        references auth.users (id) on delete set null,
  ativo           boolean     not null default true,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);

create trigger barbeiros_atualizado_em
  before update on public.barbeiros
  for each row execute function public.tocar_atualizado_em();

create index barbeiros_ativos on public.barbeiros (tenant_id) where ativo;


-- ---------------------------------------------------------------------------
-- servicos — nome, duração e preço. A duração é o que define o fim do agendamento;
-- o fim nunca vem do cliente que agenda.
-- ---------------------------------------------------------------------------
create table public.servicos (
  id             uuid        primary key default gen_random_uuid(),
  tenant_id      uuid        not null references public.tenants (id) on delete cascade,
  nome           text        not null check (length(btrim(nome)) > 0),
  duracao_min    integer     not null check (duracao_min between 5 and 480),
  preco_centavos integer     not null check (preco_centavos >= 0),
  ativo          boolean     not null default true,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  unique (tenant_id, nome)
);

create trigger servicos_atualizado_em
  before update on public.servicos
  for each row execute function public.tocar_atualizado_em();

create index servicos_ativos on public.servicos (tenant_id) where ativo;


-- ---------------------------------------------------------------------------
-- clientes — quem corta o cabelo. canal_preferido é a variável de custo da régua
-- (seção 6): e-mail é ~100x mais barato que mensagem.
-- ---------------------------------------------------------------------------
create table public.clientes (
  id                uuid        primary key default gen_random_uuid(),
  tenant_id         uuid        not null references public.tenants (id) on delete cascade,
  nome              text        not null check (length(btrim(nome)) > 0),
  telefone          public.telefone_e164,
  email             text        check (email is null or email like '%_@_%._%'),
  canal_preferido   text        not null default 'whatsapp'
                                check (canal_preferido in ('whatsapp', 'email')),
  optin_whatsapp_em timestamptz,
  optin_email_em    timestamptz,
  criado_em         timestamptz not null default now(),
  atualizado_em     timestamptz not null default now(),

  -- Sem este CHECK existe cliente cujo lembrete não tem para onde ir, e a falha só
  -- aparece duas horas antes do corte. Com ele, criar_agendamento sempre resolve
  -- destino a partir de canal_preferido.
  constraint clientes_canal_tem_destino check (
    (canal_preferido = 'whatsapp' and telefone is not null)
    or (canal_preferido = 'email' and email is not null)
  ),

  -- O mesmo telefone é o mesmo cliente dentro da barbearia; entre barbearias não é.
  -- NULL não colide com NULL, então cliente só de e-mail não trava o cadastro.
  unique (tenant_id, telefone)
);

create trigger clientes_atualizado_em
  before update on public.clientes
  for each row execute function public.tocar_atualizado_em();

-- Busca do agente conversacional: "quem é o número que está falando comigo" já é
-- servida pela UNIQUE acima. Esta é a busca por e-mail, que não é identidade.
create index clientes_por_email on public.clientes (tenant_id, lower(email))
  where email is not null;


-- ---------------------------------------------------------------------------
-- agendamentos — o horário marcado. A invariante da agenda vive na constraint de
-- exclusão no fim desta tabela, não em checagem de aplicação.
-- ---------------------------------------------------------------------------
create table public.agendamentos (
  id                  uuid        primary key default gen_random_uuid(),
  tenant_id           uuid        not null references public.tenants (id) on delete cascade,
  -- RESTRICT e não CASCADE: apagar um barbeiro ou um serviço não pode apagar
  -- silenciosamente a agenda dele. Quem sai de operação vira ativo = false.
  barbeiro_id         uuid        not null references public.barbeiros (id) on delete restrict,
  servico_id          uuid        not null references public.servicos (id) on delete restrict,
  cliente_id          uuid        not null references public.clientes (id) on delete restrict,
  inicio_em           timestamptz not null,
  fim_em              timestamptz not null,
  status              text        not null default 'pendente'
                                  check (status in ('pendente', 'confirmado', 'concluido',
                                                    'cancelado', 'nao_compareceu')),
  origem              text        not null default 'painel'
                                  check (origem in ('painel', 'agente', 'site', 'importacao')),
  confirmado_em       timestamptz,
  confirmado_por      text,
  cancelado_em        timestamptz,
  cancelado_por       text,
  motivo_cancelamento text,
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now(),

  constraint agendamentos_intervalo_valido check (fim_em > inicio_em),

  -- A invariante da seção 4. Três decisões que um revisor precisa conferir:
  --
  -- 1. `'[)'` (fim aberto): 10:00-10:30 e 10:30-11:00 não se cruzam. Com '[]' o
  --    segundo corte do dia seria recusado por um instante compartilhado.
  -- 2. `where (status <> 'cancelado')`: horário cancelado volta a ser vendável. O
  --    índice parcial também encolhe — só agenda viva entra nele. 'nao_compareceu'
  --    fica de fora do WHERE de propósito: o horário foi consumido de fato.
  -- 3. tenant_id NÃO entra na constraint. Entrar enfraqueceria: barbeiro_id já
  --    pertence a um único tenant, e comparar tenant_id deixaria passar duas linhas
  --    do mesmo barbeiro gravadas com tenants diferentes — exatamente o bug que
  --    esta constraint existe para pegar.
  constraint agendamentos_sem_sobreposicao exclude using gist (
    barbeiro_id with =,
    tstzrange(inicio_em, fim_em, '[)') with &&
  ) where (status <> 'cancelado')
);

create trigger agendamentos_atualizado_em
  before update on public.agendamentos
  for each row execute function public.tocar_atualizado_em();

-- Agenda do dia, que é a tela inicial do painel.
create index agendamentos_por_tenant_inicio on public.agendamentos (tenant_id, inicio_em);
-- Disponibilidade e agenda de um profissional.
create index agendamentos_por_barbeiro_inicio
  on public.agendamentos (tenant_id, barbeiro_id, inicio_em)
  where status <> 'cancelado';
-- Histórico do cliente, usado pelo agente antes de responder.
create index agendamentos_por_cliente on public.agendamentos (tenant_id, cliente_id, inicio_em desc);


-- ---------------------------------------------------------------------------
-- assinaturas — o que o gateway diz sobre o pagamento desta barbearia.
-- ---------------------------------------------------------------------------
create table public.assinaturas (
  id                    uuid        primary key default gen_random_uuid(),
  tenant_id             uuid        not null references public.tenants (id) on delete cascade,
  gateway               text        not null check (gateway in ('mercadopago', 'asaas', 'stripe')),
  assinatura_externa_id text        not null,
  plano                 text        not null,
  status                text        not null default 'ativa'
                                    check (status in ('ativa', 'inadimplente', 'pausada', 'cancelada')),
  -- Vêm no pagamento.confirmado (seção 3); sem elas não há como auditar cobrança
  -- contra o que o gateway informou.
  valor_centavos        integer     check (valor_centavos is null or valor_centavos >= 0),
  ciclo                 text        check (ciclo is null or ciclo in ('mensal', 'anual')),
  periodo_fim           timestamptz,
  cancelada_em          timestamptz,
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now(),

  -- A assinatura no gateway é global, não por tenant: a mesma assinatura_externa_id
  -- não pode aparecer em duas barbearias. É o que impede reentrega de webhook
  -- provisionar um segundo tenant.
  unique (gateway, assinatura_externa_id)
);

create trigger assinaturas_atualizado_em
  before update on public.assinaturas
  for each row execute function public.tocar_atualizado_em();

create index assinaturas_por_tenant on public.assinaturas (tenant_id, status);
