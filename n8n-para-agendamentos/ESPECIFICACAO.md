# Especificação canônica — FastChair / n8n para agendamentos

> **Fonte da verdade desta pasta.** Todo arquivo de código, workflow e documento
> aqui obedece a este arquivo. Divergência entre um arquivo e esta especificação
> é defeito do arquivo, não da especificação.

## 0. Procedência — leia antes de confiar

Este material **não foi extraído de um sistema existente.** Em 10/11/2026 não
havia código do FastChair em lugar algum: o projeto existia como arquitetura
estudada (vault `fastchair-visao-geral` / `fastchair-tecnico`, status `pendente`),
site institucional estático e quatro decisões abertas. Tudo aqui foi **escrito
do zero** a partir da arquitetura já registrada no vault, implementando o
desenho que as notas recomendam.

O que vem do vault (decisão anterior, respeitada):

| Vem de lá | Onde aparece aqui |
|---|---|
| **n8n self-hosted**, não Make/Zapier — custo por execução mata a régua | `docs/06-operacao.md` |
| **Contrato por evento de domínio**, nunca payload cru de Google/Meta | `docs/01-contrato-de-eventos.md` |
| Linha de corte: backend é dono da agenda, disponibilidade, agente e máquina de estados; n8n é adaptador de borda | `docs/00-visao-geral.md` |
| **Régua: >2h de antecedência avisa 2h antes; em cima da hora avisa na hora** (reunião de 27/08/2026) | `docs/04-regua-de-lembrete.md` |
| Isolamento por inquilino se resolve **no desenho do banco** | `backend/supabase/migracoes/` (RLS) |
| E-mail ~100x mais barato que mensagem → canal é escolha do cliente final | campo `canal_preferido` |
| **D-2 reaberta: não fechar com Z-API por enquanto** (risco de banimento) | `docs/05-seguranca.md` §6 |

## 1. Stack fixada

| Camada | Escolha | Por quê |
|---|---|---|
| Frontend | Lovable (Vite + React + TS) | é onde o app nasce; fora do escopo desta pasta, só o contrato de login |
| Banco + Auth | **Supabase** (Postgres 15, Auth, RLS) | o Auth já resolve "gerar usuário e primeira senha"; RLS resolve isolamento por inquilino no banco |
| Backend de domínio | **Supabase Edge Functions** (Deno, TypeScript) | mesmo projeto, segredo no servidor, sem infra extra nesta fase |
| Orquestração de borda | **n8n self-hosted** (Docker, queue mode, Postgres próprio) | decisão do vault |
| Pagamento | Mercado Pago · Asaas · Stripe | três adaptadores normalizando para um evento só |
| WhatsApp | **Cloud API oficial da Meta** (padrão) + adaptador trocável | D-2 está aberta; o código não pode travar nela |
| E-mail | SMTP / Resend | canal alternativo, ~100x mais barato |

**Premissa D-1:** este desenho é **multi-tenant**. Não é D-1 fechada — é o que o
pedido exige (pagamento gera inquilino novo). Se o produto virar single-tenant,
`docs/08-decisoes-abertas.md` §1 diz o que cai fora.

## 2. Nomes

Português, como o domínio. `tenant` = barbearia. `barbeiro` = profissional que
atende. `cliente` = quem corta o cabelo. `agendamento` = o horário marcado.

Tabelas e colunas em `snake_case` português. Arquivos em `kebab-case`.
Workflow do n8n: `NN-assunto` (`01-pagamento-provisionamento`).

Data no banco: **UTC** (`timestamptz`, sempre gravado em UTC). Conversão para
horário local só na borda de apresentação e na montagem da mensagem.

Dinheiro: inteiro em **centavos**, nunca float.

Telefone: **E.164 sem `+`** (`5531988887777`). Normalizar na entrada, incluindo
o nono dígito — número de 10 dígitos não é necessariamente fixo.

## 3. Envelope de evento — o contrato entre backend e n8n

Todo evento que cruza a fronteira usa este envelope. **Nenhum payload cru de
gateway ou da Meta atravessa.** É isso que permite trocar o n8n depois sem
reescrever o núcleo.

```json
{
  "evento": "agendamento.criado",
  "versao": 1,
  "id": "0f8e0f3a-5b7c-4d2e-9f10-1a2b3c4d5e6f",
  "ocorrido_em": "2026-11-10T14:03:11.402Z",
  "tenant_id": "a1b2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
  "origem": "backend",
  "dados": {}
}
```

- `id` — UUID do evento. **É a chave de idempotência.** Reentrega com o mesmo
  `id` não produz efeito novo.
- `versao` — inteiro. Campo novo é compatível; campo removido ou com significado
  alterado exige `versao` nova, e o consumidor passa a tratar as duas.
- `origem` — `backend` | `n8n` | `gateway:<nome>`.

### Catálogo de eventos

| Evento | Quem emite | Quem consome | `dados` |
|---|---|---|---|
| `pagamento.confirmado` | n8n (normalizador) | backend | `gateway`, `evento_externo_id`, `pagador{nome,email,telefone}`, `plano`, `valor_centavos`, `assinatura_externa_id`, `ciclo` |
| `pagamento.falhou` | n8n | backend | `gateway`, `evento_externo_id`, `assinatura_externa_id`, `motivo` |
| `assinatura.cancelada` | n8n | backend | `gateway`, `assinatura_externa_id`, `cancelada_em` |
| `tenant.provisionado` | backend | n8n | `tenant_id`, `nome_barbearia`, `dono{nome,email,telefone}`, `credenciais{email,senha_temporaria,url_primeiro_acesso,expira_em}` |
| `agendamento.criado` | backend | n8n | `agendamento_id`, `inicio_em`, `fim_em`, `servico{nome,duracao_min,preco_centavos}`, `cliente{nome,telefone,canal_preferido}`, `barbeiro{nome,telefone,canal_preferido}`, `origem` |
| `agendamento.confirmado` | backend | n8n | `agendamento_id`, `confirmado_em`, `confirmado_por` |
| `agendamento.cancelado` | backend | n8n | `agendamento_id`, `cancelado_em`, `cancelado_por`, `motivo` |
| `agendamento.remarcado` | backend | n8n | `agendamento_id`, `inicio_em_antigo`, `inicio_em` |
| `lembrete.devido` | backend (poller) | n8n | `lembrete_id`, `agendamento_id`, `tipo`, `canal`, `destino`, `variaveis{}` |

`credenciais.senha_temporaria` é **o único campo sensível do catálogo**. Ele
existe porque o pedido pede a primeira senha gerada; `docs/05-seguranca.md` §4
registra o custo dessa escolha e como desligá-la (`PROVISIONAR_ENVIA_SENHA=false`,
que entrega só o link one-time).

## 4. Tabelas

Toda tabela de dado de cliente tem `tenant_id` e **RLS ligada**.

| Tabela | Papel |
|---|---|
| `tenants` | a barbearia. `id`, `nome`, `slug`, `status`, `plano`, `fuso`, `criado_em` |
| `usuarios_tenant` | liga `auth.users` ao tenant. `usuario_id`, `tenant_id`, `papel` (`dono`/`barbeiro`/`recepcao`), `trocar_senha` |
| `barbeiros` | profissional. `tenant_id`, `nome`, `telefone`, `canal_preferido`, `usuario_id?`, `ativo` |
| `servicos` | `tenant_id`, `nome`, `duracao_min`, `preco_centavos`, `ativo` |
| `clientes` | `tenant_id`, `nome`, `telefone`, `email`, `canal_preferido`, `optin_whatsapp_em`, `optin_email_em` |
| `agendamentos` | `tenant_id`, `barbeiro_id`, `servico_id`, `cliente_id`, `inicio_em`, `fim_em`, `status`, `origem` |
| `assinaturas` | `tenant_id`, `gateway`, `assinatura_externa_id`, `plano`, `status`, `periodo_fim` |
| `webhooks_recebidos` | **idempotência da borda.** `gateway`, `evento_externo_id` UNIQUE, `corpo_hash`, `recebido_em`, `processado_em`, `resultado` |
| `eventos_saida` | **outbox.** `id`, `tenant_id`, `evento`, `versao`, `dados jsonb`, `criado_em`, `entregue_em`, `tentativas`, `ultimo_erro` |
| `lembretes` | **relógio durável.** `tenant_id`, `agendamento_id`, `tipo`, `disparar_em`, `canal`, `destino`, `status`, `tentativas`, `enviado_em` |
| `mensagens_enviadas` | log + dedupe. UNIQUE `(tenant_id, chave_dedupe)` |
| `primeiro_acesso` | token one-time. `token_hash`, `usuario_id`, `expira_em`, `usado_em` |
| `fila_morta` | o que esgotou retry. `origem`, `evento`, `payload jsonb`, `erro`, `criado_em` |

Invariante da agenda: **sem dois agendamentos ativos no mesmo barbeiro em
horários que se cruzam.** Garantido por constraint de exclusão no banco
(`EXCLUDE USING gist`), não por checagem na aplicação — checar na aplicação
perde a corrida entre dois pedidos simultâneos.

## 5. Os três fluxos

### Fluxo A — pagamento → usuário e primeira senha

```
Gateway ──POST──> n8n /webhook/pagamento/:gateway
                     │ 1. valida HMAC do gateway (timing-safe)
                     │ 2. responde 200 AGORA (webhook não faz trabalho pesado)
                     │ 3. dedupe: INSERT em webhooks_recebidos ON CONFLICT DO NOTHING
                     │    já existia -> encerra, não reprocessa
                     │ 4. reconsulta o gateway pelo id (o corpo do webhook não é fonte)
                     │ 5. normaliza -> pagamento.confirmado v1
                     ▼
          Edge Function  POST /provisionar-tenant     (transacional)
                     │ cria tenants
                     │ cria usuário no Auth + senha temporária forte
                     │ cria usuarios_tenant (papel=dono, trocar_senha=true)
                     │ cria barbeiros (o dono é o 1º profissional)
                     │ gera token de primeiro acesso (hash no banco, TTL 72h)
                     │ grava assinaturas
                     │ emite tenant.provisionado no outbox
                     ▼
          n8n entrega credenciais pelo canal escolhido (WhatsApp ou e-mail)
                     │
                     └─ falhou tudo -> backoff -> fila_morta + alerta
```

O passo 4 não é zelo: **o webhook do Mercado Pago manda só o `id`**, sem valor
nem plano. Quem confia no corpo do webhook aceita provisionamento forjado.

### Fluxo B — agendamento → WhatsApp do barbeiro

Latência e garantia ao mesmo tempo, com dois caminhos sobre o **mesmo**
sub-workflow de envio:

1. **Caminho rápido** — o backend grava `agendamentos` **e** `eventos_saida` na
   mesma transação (padrão outbox: não existe agendamento sem evento nem evento
   sem agendamento) e chama o webhook do n8n logo depois.
2. **Reconciliador** — Schedule Trigger de 1 min lê `eventos_saida` com
   `entregue_em IS NULL` usando `FOR UPDATE SKIP LOCKED`, e entrega o que o
   caminho rápido perdeu (n8n fora do ar, rede, deploy).

A chamada direta pode falhar; a transação não. É por isso que o outbox é a
fonte e a chamada direta é só otimização de latência.

No mesmo evento o backend cria o `lembrete` do cliente pela regra da régua.

### Fluxo C — resposta sim/não do cliente

WhatsApp inbound → n8n normaliza → backend `/responder-confirmacao`. **A máquina
de estados fica no backend**, não no canvas: o vault registra que modelar estado
conversacional em iPaaS visual produz fluxo ilegível.

## 6. A régua — requisito, não detalhe

Decidido na reunião de 27/08/2026:

- agendamento com início **> 2h** no futuro → um lembrete em `inicio_em - 2h`
- agendamento com início **≤ 2h** → um lembrete **imediato**

Isso fixa **uma mensagem de lembrete por agendamento**, e esse número é a
variável de custo da precificação. Mexer na régua mexe no preço do produto —
`docs/04-regua-de-lembrete.md` registra o vínculo.

`canal` do lembrete sai de `clientes.canal_preferido`. E-mail é ~100x mais
barato, então o custo variável por agendamento tem duas curvas, não uma.

## 7. Variáveis de ambiente

Nenhum segredo no JSON do workflow nem no código. n8n usa Credentials; a Edge
Function usa segredo do projeto.

```
# Supabase
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=      # só no servidor e no n8n, nunca no navegador
SUPABASE_ANON_KEY=

# fronteira n8n <-> backend
SEGREDO_PONTE=                  # HMAC-SHA256 das chamadas n8n -> Edge Function
N8N_WEBHOOK_BASE=               # https://n8n.seudominio/webhook
N8N_SEGREDO_ENTRADA=            # HMAC das chamadas backend -> n8n

# gateways
MERCADOPAGO_ACCESS_TOKEN=
MERCADOPAGO_WEBHOOK_SECRET=
ASAAS_API_KEY=
ASAAS_WEBHOOK_TOKEN=
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=

# WhatsApp (Cloud API)
WHATSAPP_TOKEN=
WHATSAPP_PHONE_NUMBER_ID=
WHATSAPP_VERIFY_TOKEN=
WHATSAPP_PROVEDOR=cloud_api     # cloud_api | generico_http

# e-mail
SMTP_URL=
EMAIL_REMETENTE=

# comportamento
APP_URL=                        # base do link de primeiro acesso
PROVISIONAR_ENVIA_SENHA=false   # true = manda senha no canal (ver 05-seguranca §4)
FUSO_PADRAO=America/Sao_Paulo
```

## 8. Convenção de workflow do n8n

JSON importável por **Workflows → Import from File**. Formato obrigatório:

```json
{
  "name": "01 - Pagamento e provisionamento",
  "nodes": [
    {
      "parameters": { "httpMethod": "POST", "path": "pagamento/mercadopago", "responseMode": "responseNode", "options": {} },
      "id": "11111111-1111-4111-8111-111111111111",
      "name": "Webhook pagamento",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 2,
      "position": [-200, 0],
      "webhookId": "11111111-1111-4111-8111-111111111111"
    }
  ],
  "connections": {
    "Webhook pagamento": { "main": [[{ "node": "Valida assinatura", "type": "main", "index": 0 }]] }
  },
  "settings": { "executionOrder": "v1" },
  "pinData": {},
  "staticData": null,
  "tags": [],
  "meta": { "instanceId": "fastchair" }
}
```

Regras:

- `connections` é indexado pelo **`name`** do nó, e todo destino tem de existir.
- `id` e `webhookId`: UUID v4 literal, fixo no arquivo (importação reusa).
- `position`: `[x, y]`, passo de 200 no x, para o canvas não virar espaguete.
- Tipos permitidos (só estes — o validador recusa o resto):
  `webhook`(2) · `respondToWebhook`(1.1) · `httpRequest`(4.2) · `code`(2) ·
  `if`(2) · `switch`(3) · `set`(3.4) · `postgres`(2.4) · `scheduleTrigger`(1.2) ·
  `splitInBatches`(3) · `noOp`(1) · `errorTrigger`(1) · `executeWorkflow`(1.2) ·
  `stopAndError`(1) · `wait`(1.1) · `merge`(3) · `emailSend`(2.1) · `crypto`(1)
  — todos com prefixo `n8n-nodes-base.`
- Credencial referenciada por **nome**, nunca com valor embutido.
- Todo workflow com chamada externa tem retry no nó (`retryOnFail`,
  `maxTries`, `waitBetweenTries`) e saída de erro para a `fila_morta`.

Valide com `node n8n/ferramentas/validar-workflows.mjs` antes de dizer que está pronto.

## 9. Onde cada coisa mora

```
n8n-para-agendamentos/
├── ESPECIFICACAO.md              ← este arquivo
├── README.md                     ← porta de entrada
├── docs/
│   ├── 00-visao-geral.md         o sistema e a linha de corte backend × n8n
│   ├── 01-contrato-de-eventos.md envelope, catálogo, versionamento
│   ├── 02-fluxo-pagamento.md     webhook → usuário → primeira senha → login
│   ├── 03-fluxo-agendamento.md   atendimento → WhatsApp do barbeiro
│   ├── 04-regua-de-lembrete.md   a regra de 2h e o vínculo com preço
│   ├── 05-seguranca.md           HMAC, idempotência, senha, LGPD, D-2
│   ├── 06-operacao.md            docker, queue mode, backup, observabilidade
│   ├── 07-instalacao.md          do zero ao primeiro agendamento
│   └── 08-decisoes-abertas.md    D-1..D-4 e o que este desenho assumiu
├── n8n/
│   ├── workflows/*.json          os workflows importáveis
│   ├── ferramentas/              validador
│   └── credenciais.md            quais credenciais criar (sem segredo)
├── backend/
│   ├── supabase/migracoes/*.sql  schema + RLS + constraints
│   ├── supabase/functions/       Edge Functions (Deno/TS)
│   └── lib/                      código compartilhado (hmac, telefone, erros)
├── exemplos/                     payloads reais de cada gateway e do envelope
└── testes/                       teste de isolamento, régua, idempotência
```
