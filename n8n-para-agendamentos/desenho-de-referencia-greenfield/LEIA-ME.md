# Desenho de referência (greenfield) — NÃO RODAR NO BANCO ATUAL

## O aviso, primeiro

Estes quatro arquivos SQL **não são compatíveis com o banco do BarberBook.**
Eles criam um schema próprio, com tabelas `tenants`, `barbeiros`, `clientes`,
`servicos` e `agendamentos`, e uma noção de inquilino por `tenant_id`.

O banco real não tem nada disso: a barbearia é identificada pelo
`auth.users.id` do dono, que aparece como `barber_id` em `appointments`,
`services` e `products`, como `user_id` em `barbers` e como `owner_id` em
`staff`. Ver `../extraido-do-lovable/schema-real.md`.

Rodar isto no banco de produção criaria um **segundo** modelo de dados paralelo
ao que o app usa. O app continuaria gravando em `appointments` e nada aqui
seria preenchido.

A camada que de fato encaixa no banco atual é a de `../sql/`.

## Então por que estes arquivos existem

Por duas razões.

**1. É o desenho-alvo, se o produto for reestruturado.** O vault registra que
toda a análise do FastChair assume multi-tenant, e que "um SaaS onde a agenda de
um estabelecimento pode ser lida pela conta de outro é um incidente de dados,
não um bug" — e que isso se resolve no desenho do banco. O `0003-rls.sql` daqui
é esse desenho levado a sério: RLS em toda tabela, `tenant_atual()` lendo o
`tenant_id` de `app_metadata` (e não de `user_metadata`, que o próprio usuário
consegue alterar), e `FORCE ROW LEVEL SECURITY`.

**2. Resolve, em SQL, dois problemas que o banco atual tem em aberto.** Vale ler
mesmo sem intenção de migrar:

- **Sobreposição de horário** (`0001-schema-base.sql`): a constraint
  `agendamentos_sem_sobreposicao`, com `EXCLUDE USING gist` sobre
  `tstzrange(inicio_em, fim_em, '[)')` e `barbeiro_id with =`, filtrada por
  `where (status <> 'cancelado')`. O intervalo com fim aberto `'[)'` é o que
  permite 10:00–10:30 e 10:30–11:00 coexistirem. Hoje essa garantia está na
  aplicação (`src/lib/slots.ts`), onde ela perde a corrida entre dois pedidos
  simultâneos.
- **Atomicidade entre agendamento, evento e lembrete** (`0004-funcoes.sql`,
  função `criar_agendamento`): os três nascem na mesma transação.

## Conteúdo

| Arquivo | O que tem |
|---|---|
| `0001-schema-base.sql` | tabelas de domínio, a constraint de exclusão, índices |
| `0002-infra-entrega.sql` | outbox, lembretes, idempotência, dedupe, fila morta |
| `0003-rls.sql` | RLS em todas as tabelas, `tenant_atual()`, FORCE |
| `0004-funcoes.sql` | `criar_agendamento`, `agendar_lembrete`, reserva de fila |

A régua de 2h está implementada aqui também, em `agendar_lembrete` de
`0004-funcoes.sql`, com a mesma regra de `../sql/0011`. Se a régua mudar, as
duas mudam — ou esta cópia passa a mentir.

## Status

Escrito em 10/11/2026. **Nunca executado**, em nenhum banco.
