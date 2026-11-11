# O que o BarberBook faz hoje

Levantado lendo o projeto `2d90406c-ef03-4279-b60b-cfa2ad3b7983` no Lovable em
11/11/2026. Último commit do projeto: **04/08/2026**.

O BarberBook **é** o FastChair. O nome no Lovable ficou BarberBook; a marca é
FastChair, e foi desse projeto que saiu o `fastchair-landing.html`
(ver `.lovable/plan.md`).

## Stack real

| | |
|---|---|
| Framework | **TanStack Start** (não Vite + React Router) — rotas em `src/routes/`, arquivo `routeTree.gen.ts` gerado |
| UI | shadcn/ui completo (48 componentes em `src/components/ui/`), Tailwind |
| Banco e auth | Supabase — `src/integrations/supabase/` |
| Pagamento | Stripe — assinatura recorrente com 4 preços (mensal, trimestral, semestral, anual) + `lifetime` |
| Runtime/pacote | bun (`bun.lock`, `bunfig.toml`) |
| Migrações | `supabase/migrations/`, 13 arquivos, de 24/06 a 09/07/2026 |

O schema está detalhado em `../extraido-do-lovable/schema-real.md`.

## As rotas

**Público**

| Rota | O que é |
|---|---|
| `index.tsx` | landing do FastChair |
| `planos.tsx` | preços e checkout |
| `agendar.$slug.tsx` | **link público de agendamento** — é o que o barbeiro compartilha |
| `barbeiro.$slug.tsx` | página do profissional |
| `contato.tsx` | contato |
| `termos`, `privacidade`, `cookies`, `reembolso`, `exclusao-de-dados` | legais |

**Barbeiro** (prefixo `app.`, protegido por `app.tsx` + `billing-guard.tsx`)

| Rota | O que é |
|---|---|
| `app.dashboard.tsx` | visão financeira |
| `app.agenda.tsx` | grade de horários |
| `app.agendamentos.tsx` | lista e gestão de agendamentos |
| `app.clientes.tsx` | base de clientes |
| `app.servicos.tsx` | serviços, duração e preço |
| `app.produtos.tsx` | produtos e estoque (com alerta de mínimo) |
| `app.funcionarios.tsx` | equipe e percentual de comissão |
| `app.comissoes.tsx` | apuração e pagamento de comissão |
| `app.configuracoes.tsx` | horário de funcionamento, intervalo, dias |
| `app.link.tsx` | o link público para compartilhar |
| `app.meu-perfil.tsx` | perfil do dono |

**Cliente** (prefixo `cliente.`)

`cliente.tsx` (shell), `cliente.novo.tsx`, `cliente.agendamentos.tsx`,
`cliente.perfil.tsx`.

**API**

`api/public/webhooks.stripe.ts` — o único endpoint de servidor. É o webhook de
pagamento.

## As peças de lógica

| Arquivo | Papel |
|---|---|
| `src/lib/slots.ts` | cálculo de disponibilidade: horário da loja ou do profissional, intervalo, dias de trabalho, duração do serviço, agendamentos já ocupados |
| `src/lib/stripe.functions.ts` | server functions do Stripe (checkout, portal) |
| `src/lib/staff.functions.ts` | server functions de equipe |
| `src/components/billing-guard.tsx` | bloqueia o painel quando `payment_status` não é `active` |
| `src/hooks/use-auth.ts` | sessão |
| `src/integrations/supabase/client.ts` / `client.server.ts` | cliente do navegador e cliente com service role |
| `src/integrations/supabase/auth-middleware.ts` / `auth-attacher.ts` | sessão no servidor do TanStack Start |

## O fluxo de cobrança, que é o que já funciona

```
/planos  ->  Stripe Checkout  ->  checkout.session.completed
                                        │
                              api/public/webhooks.stripe.ts
                                        │
             cria (ou acha) o usuário no Supabase Auth, define a senha inicial,
             atualiza profiles (plan, payment_status, stripe_customer_id,
             stripe_subscription_id, current_period_end) e faz upsert da linha
             de staff com kind='owner' e comissão 100%
                                        │
                              billing-guard libera o painel
```

Eventos tratados: `checkout.session.completed`, `invoice.payment_failed`,
`invoice.payment_succeeded`, `customer.subscription.updated`,
`customer.subscription.deleted`.

O filtro `.eq("lifetime", false)` nos updates de status protege quem tem acesso
vitalício de ser marcado inadimplente.

> Há uma revisão deste arquivo com seis pontos a corrigir, dois de gravidade
> alta. Ela está em `LOCAL-NAO-PUBLICAR/` na cópia de trabalho e não neste
> repositório, porque descreve fragilidade não corrigida de sistema em produção
> e este repositório é público.

## O que NÃO existe — e é o que esta pasta constrói

Verificado por busca no projeto inteiro, não por suposição:

| Falta | Evidência |
|---|---|
| **Qualquer integração de WhatsApp** | busca por `whatsapp`: 2 ocorrências, ambas texto de marketing (`app.link.tsx:66`, `index.tsx:94`) |
| Aviso ao barbeiro quando entra agendamento | nenhum envio de mensagem em lugar nenhum |
| Régua de lembrete ao cliente | nenhuma tabela de lembrete, nenhum job agendado |
| Confirmação sim/não | `appointment_status` tem `confirmed`, mas nada o preenche automaticamente |
| Idempotência de webhook | nenhuma tabela registra `event.id` do Stripe |
| Fila de retentativa / dead letter | falha vira `console.error` |
| n8n | nenhuma referência |
| Sync com Google Calendar | nenhuma referência (é componente 2 dos 5 declarados no vault) |
| Régua de Instagram | nenhuma referência (componente 5) |
| Agente conversacional / LLM | nenhuma referência (componente 3) |

Dos cinco componentes que o vault declara para o FastChair, **só o primeiro
existe**: a agenda. Os outros quatro — Google Calendar, orquestrador/agente,
WhatsApp outbound e Instagram — não foram começados.

## Duas observações de engenharia sobre o que existe

**1. Não há constraint contra sobreposição de horário.** A proteção é o cálculo
em `src/lib/slots.ts`, que roda na aplicação. Checagem na aplicação perde a
corrida entre dois pedidos simultâneos: dois clientes clicando no mesmo horário
no mesmo segundo podem gravar os dois agendamentos. O arquivo
`../desenho-de-referencia-greenfield/0001-schema-base.sql` mostra como isso se
resolve no banco, com `EXCLUDE USING gist`.

**2. `appointments.total_price` é numeric em reais**, enquanto o resto deste
repositório trabalha em centavos inteiros. A fronteira entre as duas unidades
está em `contexto_do_agendamento` (`../sql/0011`), com `round(total_price * 100)`.
Numeric para dinheiro não é erro; misturar duas unidades sem marcar onde a
conversão acontece é.
