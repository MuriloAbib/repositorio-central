# Fluxo A — pagamento vira perfil, usuário e primeira senha

Este fluxo **existe hoje**, em `src/routes/api/public/webhooks.stripe.ts` do
projeto no Lovable. Este documento descreve o que ele faz e qual é o desenho
proposto para endurecê-lo com o n8n na frente.

> A revisão detalhada do arquivo atual, com seis pontos a corrigir, está em
> `LOCAL-NAO-PUBLICAR/` na cópia de trabalho. Ela não entra neste repositório
> porque descreve fragilidade ainda não corrigida de um sistema em produção, e
> este repositório é público. Leia-a antes de mexer no fluxo.

## O que acontece hoje

```
cliente escolhe plano em /planos
        │
        ▼
Stripe Checkout  (4 preços: mensal, trimestral, semestral, anual)
        │
        │ checkout.session.completed
        ▼
POST /api/public/webhooks/stripe
        │
        ├─ valida a assinatura do Stripe sobre o CORPO CRU
        │  (constructEventAsync(body, signature, webhookSecret))
        │  assinatura inválida -> 400, nada é processado
        │
        ├─ extrai e-mail de customer_details.email ou customer_email
        ├─ extrai CPF de session.custom_fields ou session.metadata
        ├─ define a senha inicial
        ├─ listLineItems -> price_id -> plano
        ├─ subscriptions.retrieve -> current_period_end
        │
        ├─ acha ou cria o usuário no Supabase Auth
        │  createUser({ email, password, email_confirm: true,
        │               user_metadata: { role: 'barber', full_name } })
        │
        ├─ UPDATE profiles SET plan, payment_status='active',
        │         stripe_customer_id, stripe_subscription_id, cpf,
        │         current_period_end
        │
        └─ UPSERT staff (owner_id, user_id, email, full_name,
                         kind='owner', comissão 100%)
                         onConflict: (owner_id, email)
        │
        ▼
billing-guard.tsx libera /app/*  quando payment_status = 'active'
```

Os cinco eventos tratados:

| Evento | Efeito |
|---|---|
| `checkout.session.completed` | provisiona: usuário, senha, perfil, staff |
| `invoice.payment_succeeded` | `payment_status = 'active'`, renova `current_period_end` |
| `invoice.payment_failed` | `payment_status = 'past_due'`, grava `payment_failed_at` |
| `customer.subscription.updated` | renova `current_period_end` |
| `customer.subscription.deleted` | `payment_status = 'expired'` |

Os três últimos filtram por `.eq("lifetime", false)`, protegendo acesso
vitalício de ser marcado inadimplente.

## Onde o perfil, o usuário e a senha nascem

Mapeando o que você descreveu para o código real:

| Você descreveu | Onde acontece | Tabela/sistema |
|---|---|---|
| "pega os hooks das formas de pagamento" | `constructEventAsync` sobre o corpo cru | Stripe |
| "gerar o perfil do cara" | `UPDATE profiles` + `UPSERT staff` | `profiles`, `staff` |
| "gerar o usuário" | `supabaseAdmin.auth.admin.createUser` | `auth.users` |
| "gerar a primeira senha" | `initialPassword` passado ao `createUser` | `auth.users` |
| "e login" | `billing-guard` + `use-auth` | Supabase Auth |

O `role: 'barber'` vai em `user_metadata`. Vale registrar que
**`user_metadata` é alterável pelo próprio usuário** pela API de update do
Supabase; papel que decide autorização pertence a `app_metadata`, que só muda
pela Admin API. Hoje a autorização efetiva não depende desse campo (depende de
`profiles.role` e das funções `is_owner`/`get_owner_id` no banco), mas é uma
armadilha armada para quem vier escrever uma policy lendo o metadata errado.

## O desenho proposto: n8n na frente

O workflow `01-pagamento-provisionamento.json` põe uma borda antes do
provisionamento. Ele cobre três gateways — Stripe, Mercado Pago e Asaas — porque
você falou em "formas de pagamento" no plural, e normaliza os três para **um**
evento de domínio.

```
Gateway ──> Webhook  path: pagamento/:gateway
              │
              ├─ 1. "Valida assinatura"   Code, por gateway, timing-safe
              │
              ├─ 2. "Responde 200"        AGORA, antes de qualquer trabalho
              │
              ├─ 3. "Registra webhook"    INSERT webhooks_recebidos
              │        ON CONFLICT DO NOTHING RETURNING
              │      "Primeira entrega?"  não retornou linha = reentrega, encerra
              │
              ├─ 4. "Qual gateway?"       Switch
              │      "Consulta <gateway>" reconsulta a API pelo id
              │
              ├─ 5. "Normaliza pagamento" -> pagamento.confirmado v1
              │
              ├─ 6. "Pagamento aprovado?" não -> pagamento.falhou, encerra
              │
              ├─ 7. "Assina chamada da ponte" HMAC com SEGREDO_PONTE
              │      "Provisiona tenant"      POST no backend, retry 3x
              │
              └─ erro -> "Fila morta"
```

### Por que responder 200 antes de trabalhar

O Stripe espera resposta em ~20s e **retenta no timeout**. Com idempotência
ausente, um pico de latência não causa só lentidão — causa reprocessamento do
provisionamento inteiro. Responder primeiro e trabalhar depois elimina a classe
inteira de problema.

### Por que reconsultar o gateway

Não é zelo. **O webhook do Mercado Pago manda só o `id` e o `topic`** — sem
valor, sem plano, sem pagador. Qualquer sistema que trate o corpo do webhook do
MP como fonte de verdade está aceitando provisionamento forjado por quem souber
o formato. A única fonte é `GET /v1/payments/{id}` com o access token.

No Stripe o corpo é assinado e confiável, mas `current_period_end` ainda exige
`subscriptions.retrieve` — e é o que o código atual já faz, corretamente.

### A assinatura de cada gateway

| Gateway | Header | Como se valida |
|---|---|---|
| Stripe | `Stripe-Signature` | `t=<ts>,v1=<hex>`; HMAC-SHA256 de `"<t>.<corpo cru>"` com o webhook secret; tolerância de 300s contra replay |
| Mercado Pago | `x-signature` + `x-request-id` | `ts=<ts>,v1=<hex>`; HMAC-SHA256 do manifest `id:<data.id>;request-id:<x-request-id>;ts:<ts>;` |
| Asaas | `asaas-access-token` | token compartilhado, comparado em tempo constante |

Três pontos que fazem a diferença entre validar e parecer validar:

1. **HMAC sobre o corpo cru**, nunca sobre o JSON reserializado. `JSON.parse`
   seguido de `JSON.stringify` reordena chaves e muda espaços: a assinatura
   deixa de bater e a tentação é desligar a verificação.
2. **Comparação em tempo constante.** `===` em string de assinatura retorna no
   primeiro byte diferente, e o tempo de resposta revela quantos bytes estavam
   certos. Compare por XOR acumulado sobre buffers do mesmo tamanho.
3. **Janela de tempo.** Sem conferir o `ts`, uma requisição assinada capturada
   hoje continua válida para sempre.

### Idempotência

```sql
constraint webhooks_recebidos_unico unique (gateway, evento_externo_id)
```

A unicidade é por `(gateway, evento_externo_id)` e não só pelo id: ids do Stripe
e do Mercado Pago vivem em espaços separados e podem colidir.

O teste é `INSERT ... ON CONFLICT DO NOTHING RETURNING`: **se não retornou
linha, é reentrega.** Por constraint do banco, não por um `if` — dois webhooks
simultâneos passariam juntos por um `if`.

A coluna `corpo_hash` existe para um caso específico: dois eventos com o mesmo
id externo e **corpos diferentes** significam que alguém está forjando
reentrega, ou que o gateway mudou o payload. Isso merece alarme, não
processamento silencioso.

## A primeira senha, e a alternativa

`ESPECIFICACAO.md` §7 tem a chave `PROVISIONAR_ENVIA_SENHA`, com padrão
**`false`**. O padrão entrega **link de primeiro acesso**, não senha.

A tabela que sustenta isso é `primeiro_acesso`, em `../sql/0010-automacao.sql`:

```sql
token_hash  text not null unique,
expira_em   timestamptz not null,
usado_em    timestamptz
```

Guarda **só o hash** do token. Consequência: vazamento do banco não vira login, e
nem quem tem acesso ao banco consegue entrar na conta de um cliente.

O desenho: token aleatório por `crypto.getRandomValues` → hash gravado → link
entregue → o dono define a própria senha → `usado_em` preenchido, token morre.
Token usado, expirado ou inexistente devem dar a **mesma** resposta: diferenciar
revela qual dos três foi.

O tradeoff de ligar `PROVISIONAR_ENVIA_SENHA=true`, para ficar explícito: senha
em texto no WhatsApp fica no histórico de um aplicativo de terceiro, visível a
quem tiver o aparelho, e não há como revogá-la depois de enviada. O ganho é
fricção menor no primeiro acesso. Para um produto cujo usuário é dono de
negócio e cuja conta controla a agenda e o financeiro, o link custa menos.

## Testar sem gateway

O `01` pode ser exercitado com `curl`, assinando na mão. Para o Stripe:

```bash
CORPO='{"id":"evt_teste_1","type":"checkout.session.completed","data":{"object":{}}}'
TS=$(date +%s)
SIG=$(printf '%s.%s' "$TS" "$CORPO" \
      | openssl dgst -sha256 -hmac "$STRIPE_WEBHOOK_SECRET" -hex \
      | sed 's/^.*= //')

curl -i -X POST "$N8N_WEBHOOK_BASE/pagamento/stripe" \
  -H 'Content-Type: application/json' \
  -H "Stripe-Signature: t=$TS,v1=$SIG" \
  --data-raw "$CORPO"
```

O que conferir, em ordem:

1. **200 imediato.** Se demorar, o passo 2 do fluxo está no lugar errado.
2. `select * from webhooks_recebidos order by recebido_em desc limit 1;` — uma
   linha nova.
3. **Repita o mesmo comando.** Ainda 200, e **nenhuma** linha nova. Se aparecer
   segunda linha, a idempotência não está funcionando.
4. Com assinatura errada (mude um caractere do `SIG`): **400**, e nenhuma linha.
