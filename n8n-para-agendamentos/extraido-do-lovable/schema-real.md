# O schema real do BarberBook

Lido de `src/integrations/supabase/types.ts` do projeto
`2d90406c-ef03-4279-b60b-cfa2ad3b7983` (Lovable), que é gerado pelo Supabase a
partir do banco — portanto é o schema de verdade, não um desenho.

Stack: **TanStack Start** (não Vite + React Router), Supabase, Stripe, shadcn/ui,
bun. Migrações em `supabase/migrations/`, 13 arquivos, de 24/06 a 09/07/2026.

## O modelo de inquilino

**Não existe tabela `tenants`.** A barbearia é identificada pelo
`auth.users.id` do dono, e esse id aparece com três nomes diferentes:

| Tabela | Coluna | O que é |
|---|---|---|
| `appointments` | `barber_id` | id do usuário dono da barbearia |
| `services` | `barber_id` | idem |
| `products` | `barber_id` | idem |
| `barbers` | `user_id` | idem (é a linha de configuração da loja) |
| `staff` | `owner_id` | idem |
| `commission_entries` | `owner_id` | idem |

A camada de automação em `../sql/` chama isso de `owner_id` e usa o mesmo valor.
Inventar um `tenant_id` novo criaria duas noções de inquilino no mesmo banco, e
a consulta que esquecesse de casar as duas vazaria dado entre barbearias.

Há três funções de apoio no banco: `get_owner_id(_uid)`, `get_staff_id(_uid)` e
`is_owner(_uid)`.

## As nove tabelas

### `profiles`
A linha de conta. `id` **é** o `auth.users.id` (não é coluna separada).

`id`, `full_name`, `phone`, `cpf`, `role` (`barber`|`client`),
`plan` (`mensal`|`trimestral`|`semestral`|`anual`|`lifetime`),
`payment_status` (`active`|`past_due`|`expired`), `payment_failed_at`,
`current_period_end`, `lifetime` (bool), `stripe_customer_id`,
`stripe_subscription_id`, `created_at`, `updated_at`.

**Não tem coluna de e-mail** — o e-mail vive em `auth.users`. Isso importa:
`../sql/0011` busca o e-mail do cliente em `auth.users` por causa disso.

### `barbers`
Configuração da loja e da agenda. `user_id`, `slug` (usado no link público
`/agendar/$slug`), `shop_name`, `bio`, `photo_url`, `open_time`, `close_time`,
`break_start`, `break_end`, `work_days` (`number[]`), `slot_gap_min`.

A disponibilidade sai daqui mais `staff`; o cálculo está em `src/lib/slots.ts`.

### `staff`
Profissional que atende. `owner_id`, `user_id` (nulo se o funcionário não tem
login), `email`, `full_name`, `display_name`, `phone`, `kind`
(`owner`|`employee`), `commission_service_pct`, `commission_product_pct`,
`specialties` (`string[]`), `active`, e horário próprio opcional
(`open_time`, `close_time`, `break_*`, `work_days`, `slot_gap_min`) que
sobrepõe o da loja quando preenchido.

O dono também tem linha em `staff`, com `kind='owner'` e comissão 100% — criada
pelo webhook do Stripe. A UNIQUE usada no upsert é `(owner_id, email)`.

### `appointments`
`barber_id`, `client_id`, `staff_id` (nulo = atende o dono), `service_id`,
`scheduled_at` (timestamptz), `duration_min`, `total_price` (numeric, **em
reais, não centavos**), `status` (`pending`|`confirmed`|`completed`|`cancelled`),
`notes`, `created_at`, `updated_at`.

Dois pontos que a camada de automação tem de respeitar:

1. **`total_price` é numeric em reais.** O resto deste repositório usa centavos
   inteiros; a conversão acontece em `contexto_do_agendamento`
   (`round(total_price * 100)`). Dinheiro em numeric não é erro, mas misturar as
   duas unidades sem marcar onde a fronteira está é.
2. **Não há constraint impedindo dois agendamentos sobrepostos** no mesmo
   profissional. A proteção é o cálculo de slot em `src/lib/slots.ts`, que roda
   na aplicação — e checagem na aplicação perde a corrida entre dois pedidos
   simultâneos. Dois clientes clicando no mesmo horário no mesmo segundo podem
   gravar os dois. O `desenho-de-referencia-greenfield/0001-schema-base.sql`
   mostra como seria com `EXCLUDE USING gist`.

### `appointment_products`
Produto vendido no atendimento. `appointment_id`, `product_id`, `staff_id`,
`quantity`, `unit_price`.

### `services`
`barber_id`, `name`, `description`, `duration_min`, `price`, `active`.

### `products`
`barber_id`, `name`, `description`, `price`, `stock`, `min_stock`,
`commission_pct`. O `min_stock` alimenta o alerta de estoque do dashboard.

### `commission_entries`
`owner_id`, `staff_id`, `source_type` (`service`|`product`), `source_id`,
`gross_amount`, `pct`, `amount`, `earned_at`.

### `commission_payments`
`owner_id`, `staff_id`, `amount`, `paid_at`, `notes`.

## Os seis enums

```
appointment_status  pending | confirmed | completed | cancelled
billing_plan        mensal | semestral | anual | lifetime | trimestral
commission_source   service | product
payment_status      active | past_due | expired
staff_kind          owner | employee
user_role           barber | client
```

O `appointment_status` já tem `confirmed`, que é exatamente o estado que o fluxo
de confirmação sim/não (workflow 05) precisa. Não é preciso enum novo.

## O que o schema NÃO tem, e a automação precisa

| Falta | Para quê | Onde é criado |
|---|---|---|
| tabela de idempotência de webhook | reentrega do Stripe não reprocessar | `../sql/0010` |
| outbox de evento | agendamento nunca ficar sem aviso | `../sql/0010` |
| relógio durável de lembrete | a régua de 2h sobreviver a restart | `../sql/0010` |
| dedupe de mensagem enviada | reentrega não virar duas mensagens | `../sql/0010` |
| fila morta | falha parar de ser silenciosa | `../sql/0010` |
| token de primeiro acesso | primeiro login sem senha derivada de CPF | `../sql/0010` |
| preferência de canal do cliente | e-mail é ~100x mais barato que mensagem | **não criado** — a regra hoje é "WhatsApp se houver telefone, senão e-mail", em `contexto_do_agendamento` |
