# N8N para agendamentos — FastChair / BarberBook

Camada de automação de atendimento para o sistema de agendamento de barbearia:
o webhook de pagamento que cria o usuário e a primeira senha, o aviso automático
no WhatsApp do barbeiro quando entra um agendamento, e a régua de lembrete do
cliente. Orquestração em **n8n self-hosted**, domínio no **Supabase** que o app
já usa.

---

## Procedência — leia antes de confiar em qualquer linha

Esta pasta mistura duas coisas de naturezas diferentes, e confundi-las dá
problema:

| | O que é | Confiança |
|---|---|---|
| `extraido-do-lovable/` | Código **real**, lido do projeto **BarberBook** no Lovable (`2d90406c-ef03-4279-b60b-cfa2ad3b7983`, último commit de 04/08/2026) | é o que está rodando |
| `docs/01-sistema-atual.md` | Descrição desse código real | verificado contra o código |
| `sql/`, `n8n/`, demais docs | **Escrito do zero** em 10/11/2026. Não existia nada disso. **Nunca rodou** — nem em desenvolvimento | é proposta, não sistema |
| `desenho-de-referencia-greenfield/` | Schema alternativo, **não compatível** com o banco atual. Ver o `LEIA-ME.md` de lá antes de rodar qualquer coisa | não rodar em produção |

O BarberBook **é** o FastChair: foi dele que saiu o `fastchair-landing.html`
(ver `.lovable/plan.md` no projeto). O nome do projeto no Lovable ficou
BarberBook; a marca é FastChair.

**O que existe hoje e o que não existe**, medido no código:

- **Existe:** agendamento (painel, link público, área do cliente), serviços,
  produtos, funcionários, comissões, dashboard financeiro, `billing-guard`, e o
  webhook do Stripe que cria o usuário do barbeiro e define a primeira senha.
- **Não existe:** nenhuma integração de WhatsApp. A busca por `whatsapp` no
  projeto inteiro retorna **duas ocorrências, as duas texto de marketing**
  ("compartilhe seu link no WhatsApp"). Não há envio de mensagem, nem régua de
  lembrete, nem n8n, nem idempotência de webhook, nem fila de retentativa.

Ou seja: a parte de pagamento → usuário → senha que você descreveu **existe de
verdade**; a parte de avisar o barbeiro no WhatsApp **não existe** e é o que
`sql/` + `n8n/` constroem.

Há uma **revisão do webhook de pagamento** com seis pontos a corrigir, dois
deles de gravidade alta. Ela não está neste repositório de propósito: descreve
fragilidade ainda não corrigida de um sistema em produção, e este repositório é
público. Ela fica em `LOCAL-NAO-PUBLICAR/` na cópia de trabalho.

---

## Mapa

```
n8n-para-agendamentos/
├── README.md                      você está aqui
├── ESPECIFICACAO.md               contrato canônico: eventos, convenções, env
│
├── extraido-do-lovable/
│   └── schema-real.md             as 9 tabelas e 6 enums que existem no banco
│
├── docs/
│   ├── 01-sistema-atual.md               o que o BarberBook faz hoje
│   ├── 03-fluxo-pagamento.md             pagamento → usuário → senha → login
│   ├── 04-fluxo-agendamento.md           agendamento → WhatsApp do barbeiro
│   ├── 05-regua-de-lembrete.md           a regra de 2h, e por que ela é preço
│   └── 06-instalacao.md                  do zero ao primeiro aviso entregue
│
├── sql/                           a camada nova, encaixada no schema REAL
│   ├── 0010-automacao.sql         outbox, lembretes, dedupe, fila morta, RLS
│   ├── 0011-gatilhos-e-regua.sql  gatilho no appointments + a régua de 2h
│   └── 0012-reserva-de-fila.sql   SKIP LOCKED + lease, e a view de saúde
│
├── n8n/
│   ├── workflows/                 5 workflows importáveis, validados
│   ├── ferramentas/
│   │   └── validar-workflows.mjs  valida antes de importar
│   └── credenciais.md             as credenciais a criar, sem nenhum valor
│
└── desenho-de-referencia-greenfield/   NÃO compatível com o banco atual
```

## Comece por aqui

1. `docs/01-sistema-atual.md` — o que já roda, para não construir em cima de
   suposição.
2. `docs/04-fluxo-agendamento.md` — o aviso no WhatsApp do barbeiro, que é o que
   não existe.
3. `docs/06-instalacao.md` — a ordem de execução.

## A decisão de desenho que mais importa

O aviso ao barbeiro é disparado por **gatilho no banco**, não por chamada da
aplicação. Consequência prática: **o app do Lovable não precisa de nenhuma
alteração** para passar a avisar o barbeiro.

O motivo não é comodidade. O BarberBook grava agendamento de três lugares
diferentes — painel (`app.agendamentos.tsx`), link público (`agendar.$slug.tsx`)
e área do cliente (`cliente.*`). Se o evento fosse emitido pela aplicação, cada
um desses três teria de lembrar de emitir, e o que fosse esquecido viraria
agendamento sem aviso, em silêncio. No gatilho, não há como esquecer.

```
         app do Lovable (sem alteração)
                    │ INSERT em appointments
                    ▼
         gatilho agendamento_para_automacao        ← mesma transação
                    │
         ┌──────────┴──────────┐
         ▼                     ▼
   eventos_saida          lembretes
   (outbox)               (relógio durável)
         │                     │
         │ n8n lê a cada 1min  │ n8n lê a cada 5min
         ▼                     ▼
   02-notifica-barbeiro   04-regua-lembrete
         └──────────┬──────────┘
                    ▼
            06-enviar-mensagem   ← dedupe antes de enviar
                    │
         ┌──────────┴──────────┐
         ▼                     ▼
   WhatsApp Cloud API       e-mail
```

## Os três fluxos

**A — pagamento vira usuário e senha** (existe hoje)

```
Stripe ──checkout.session.completed──> /api/public/webhooks/stripe
   valida assinatura · acha ou cria usuário no Auth
   define a senha inicial · atualiza profiles (plano, status, stripe ids)
   upsert staff kind=owner
```

**B — agendamento vira aviso no WhatsApp do barbeiro** (não existe; é o novo)

```
INSERT appointments -> gatilho -> eventos_saida -> n8n 02 -> 06 -> WhatsApp
```

**C — lembrete do cliente e confirmação sim/não** (não existe; é o novo)

```
gatilho -> lembretes(disparar_em) -> n8n 04 -> 06 -> cliente responde -> 05
```

## O que falta para isto virar produção

Honestamente, e em ordem:

1. **Tratar os seis itens da revisão do provisionamento** (em
   `LOCAL-NAO-PUBLICAR/`), dois deles de gravidade alta. Isso vem antes de
   qualquer funcionalidade nova.
2. **Decidir D-2** — WhatsApp pela Cloud API oficial ou por BSP. O código está
   com adaptador trocável justamente porque a decisão está aberta, e a reunião
   de 27/08/2026 decidiu não fechar com provedor não oficial por enquanto.
3. **Aprovar os templates** no WhatsApp. Mensagem fora da janela de 24h exige
   template aprovado; sem isso o fluxo B só funciona em conversa já aberta.
4. **Medir o custo por mensagem.** O vault registra que é esse número que trava
   a precificação, e ele ainda não existe.
5. **Nada disto foi executado.** As migrações não rodaram, os workflows não
   foram importados. O `validar-workflows.mjs` prova que o JSON é importável, o
   que é bem menos do que provar que o fluxo funciona.
