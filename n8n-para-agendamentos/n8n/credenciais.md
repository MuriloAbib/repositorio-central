# Credenciais do n8n

Os workflows referenciam credencial **por nome**. Nenhum valor mora em arquivo
deste repositório — ele é público, e o validador
(`ferramentas/validar-workflows.mjs`) recusa workflow com segredo embutido.

Crie em **Settings → Credentials** com exatamente estes nomes.

| Nome | Tipo | Onde pegar | Escopo mínimo |
|---|---|---|---|
| `FastChair Supabase Postgres` | Postgres | Supabase → Settings → Database → Connection string (use o **pooler**, porta 6543) | um papel que alcance `public` e as funções de `sql/`. Não use `postgres` se puder criar papel próprio |
| `FastChair Supabase Service` | HTTP Header Auth | Supabase → Settings → API → `service_role` | só servidor. Esta chave ignora RLS: nunca no navegador |
| `FastChair WhatsApp Cloud` | HTTP Header Auth | Meta → App → WhatsApp → token permanente | `whatsapp_business_messaging` |
| `FastChair Stripe` | HTTP Header Auth | Stripe → Developers → API keys | chave **restrita** com leitura de Checkout Sessions e Subscriptions. A chave secreta plena não é necessária |
| `FastChair SMTP` | SMTP | provedor de e-mail | envio |

## Variáveis de ambiente do n8n

Os nós `Code` leem de `$env`. Defina no container (ver `docs/06-instalacao.md`):

```
FUSO_PADRAO=America/Sao_Paulo
SEGREDO_PONTE=                  # HMAC das chamadas n8n -> backend
STRIPE_WEBHOOK_SECRET=          # validação da assinatura do Stripe
MERCADOPAGO_WEBHOOK_SECRET=     # só se usar Mercado Pago
ASAAS_WEBHOOK_TOKEN=            # só se usar Asaas
WHATSAPP_PHONE_NUMBER_ID=
WHATSAPP_VERIFY_TOKEN=          # verificação do webhook da Meta (GET hub.challenge)
META_APP_SECRET=                # validação do X-Hub-Signature-256
EMAIL_REMETENTE=
APP_URL=
```

Para o n8n expor variável a nó `Code`, é preciso
`N8N_BLOCK_ENV_ACCESS_IN_NODE=false`. Com `true` (padrão em algumas versões),
`$env` volta vazio e a validação de assinatura passa a comparar contra
`undefined` — ou seja, **falha aberta**. Confira isso antes de confiar no fluxo.

## Rotação

Ordem que não derruba o fluxo: cria a credencial nova com nome temporário →
troca no workflow → testa → apaga a antiga. Trocar o valor da credencial
existente derruba as execuções em curso.

Se algum segredo vazar: rotacione no provedor **primeiro** (invalida o vazado),
depois no n8n. O inverso deixa uma janela com o segredo vazado ainda válido.
