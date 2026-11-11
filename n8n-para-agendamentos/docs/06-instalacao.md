# Instalação — do zero ao primeiro aviso entregue

Nada aqui foi executado. Este é o roteiro proposto, com um portão verificável no
fim de cada etapa. Se um portão não passa, **pare ali** — seguir adiante só
move o defeito para onde é mais difícil de achar.

Tempo realista: meia tarde, sendo a aprovação de template do WhatsApp o item que
pode levar dias e não depende de você.

---

## 0. Antes de começar

Leia `LOCAL-NAO-PUBLICAR/02-revisao-do-provisionamento.md`. Dois dos seis itens
são de gravidade alta e um deles está no caminho de autenticação. Subir
automação nova em cima disso é construir sobre o problema.

Você vai precisar de:

- acesso ao projeto Supabase do BarberBook (service role e connection string)
- uma máquina com Docker e **endereço público com TLS válido** — webhook não
  funciona em `localhost`, e a Meta exige HTTPS com certificado válido
- conta Meta Business com número de WhatsApp (ou a decisão D-2 tomada)
- as chaves do Stripe

---

## 1. Backup, antes de qualquer migração

```bash
pg_dump "$SUPABASE_DB_URL" --schema=public --schema=auth -Fc -f backup-pre-automacao.dump
```

**Portão:** o arquivo existe, tem mais de alguns KB, e
`pg_restore --list backup-pre-automacao.dump | head` lista objetos. Backup que
nunca foi testado não é backup.

---

## 2. As migrações

Na ordem. Elas **não alteram nenhuma tabela existente** — só criam tabelas,
funções, uma view e um gatilho.

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f sql/0010-automacao.sql
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f sql/0011-gatilhos-e-regua.sql
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f sql/0012-reserva-de-fila.sql
```

`ON_ERROR_STOP=1` não é opcional: sem ele o `psql` segue depois do primeiro erro
e você termina com metade da camada instalada.

**Não rode nada de `desenho-de-referencia-greenfield/`.** Aquele schema não é
compatível com este banco — ver o `LEIA-ME.md` de lá.

**Portão:**

```sql
select count(*) from information_schema.tables
 where table_schema='public'
   and table_name in ('webhooks_recebidos','eventos_saida','lembretes',
                      'mensagens_enviadas','fila_morta','primeiro_acesso');
-- esperado: 6

select * from automacao_saude;
-- esperado: cinco zeros
```

---

## 3. O gatilho funciona? (teste sem n8n, sem WhatsApp)

Este é o portão mais importante do roteiro, e roda só com SQL.

```sql
-- use ids que existam no seu banco
insert into appointments (barber_id, client_id, service_id, scheduled_at, duration_min, total_price)
values ('<uuid-do-dono>', '<uuid-do-cliente>', '<uuid-do-servico>',
        now() + interval '5 hours', 30, 50.00)
returning id;
```

**Portão:**

```sql
select evento, entregue_em, dados -> 'cliente' ->> 'nome' as cliente,
       dados -> 'profissional' ->> 'telefone' as tel_profissional
  from eventos_saida order by criado_em desc limit 1;
-- esperado: agendamento.criado, entregue_em NULL, cliente e telefone preenchidos

select tipo, disparar_em, canal, destino, status
  from lembretes order by criado_em desc limit 1;
-- esperado: confirmacao, disparar_em = scheduled_at - 2h, status pendente
```

Agora teste a **outra perna da régua** — agendamento em cima da hora:

```sql
insert into appointments (barber_id, client_id, service_id, scheduled_at, duration_min, total_price)
values ('<uuid-do-dono>', '<uuid-do-cliente>', '<uuid-do-servico>',
        now() + interval '30 minutes', 30, 50.00);

select disparar_em <= now() + interval '1 minute' as dispara_agora
  from lembretes order by criado_em desc limit 1;
-- esperado: t
```

E o cancelamento:

```sql
update appointments set status='cancelled' where id='<id-do-primeiro>';

select status from lembretes where appointment_id='<id-do-primeiro>';
-- esperado: cancelado  (lembrete de corte que não existe mais não pode sair)
```

Se os três passam, o núcleo está certo e o resto é transporte.

---

## 4. O n8n

`docker-compose.yml`, em queue mode. Os segredos vêm de um `.env` **fora** do
controle de versão.

```yaml
services:
  n8n-postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: n8n
      POSTGRES_USER: n8n
      POSTGRES_PASSWORD: ${N8N_DB_SENHA}
    volumes: [n8n-db:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n"]
      interval: 10s

  redis:
    image: redis:7-alpine
    volumes: [redis:/data]

  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    depends_on:
      n8n-postgres: { condition: service_healthy }
    ports: ["5678:5678"]
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: n8n-postgres
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: ${N8N_DB_SENHA}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_HOST: ${N8N_HOST}
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${N8N_HOST}/
      GENERIC_TIMEZONE: America/Sao_Paulo
      # sem isto, $env volta vazio nos nós Code e a validação de assinatura
      # passa a comparar contra undefined — falha ABERTA
      N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: "336"
      FUSO_PADRAO: America/Sao_Paulo
      SEGREDO_PONTE: ${SEGREDO_PONTE}
      STRIPE_WEBHOOK_SECRET: ${STRIPE_WEBHOOK_SECRET}
      WHATSAPP_PHONE_NUMBER_ID: ${WHATSAPP_PHONE_NUMBER_ID}
      WHATSAPP_VERIFY_TOKEN: ${WHATSAPP_VERIFY_TOKEN}
      META_APP_SECRET: ${META_APP_SECRET}
      APP_URL: ${APP_URL}
    volumes: [n8n:/home/node/.n8n]

  n8n-worker:
    image: n8nio/n8n:latest
    command: worker
    restart: unless-stopped
    depends_on: [n8n, redis]
    environment:
      # mesmas variáveis do serviço n8n
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: n8n-postgres
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: n8n
      DB_POSTGRESDB_PASSWORD: ${N8N_DB_SENHA}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"
      FUSO_PADRAO: America/Sao_Paulo
      SEGREDO_PONTE: ${SEGREDO_PONTE}
    volumes: [n8n:/home/node/.n8n]

volumes: { n8n: {}, n8n-db: {}, redis: {} }
```

Dois pontos que mordem:

- **`N8N_ENCRYPTION_KEY` precisa ser o mesmo no `n8n` e no `n8n-worker`.**
  Diferente, o worker não consegue descriptografar as credenciais e todo nó com
  credencial falha com erro que não diz isso.
- **Guarde essa chave junto do backup.** Restaurar o banco do n8n sem ela
  significa recadastrar todas as credenciais à mão.

**Portão:** a interface abre em `https://$N8N_HOST`, e
`docker compose logs n8n-worker | grep -i "waiting for"` mostra o worker
conectado à fila.

---

## 5. Credenciais e workflows

1. Crie as credenciais com os nomes exatos de `../n8n/credenciais.md`.
2. Valide antes de importar:

```bash
node n8n/ferramentas/validar-workflows.mjs
# esperado: APROVADO — nenhum erro
```

3. Importe os cinco JSONs (**Workflows → Import from File**), nesta ordem — o
   `06` é chamado pelos outros, então entra primeiro:

```
06-enviar-mensagem.json
99-erro-fila-morta.json
02-notifica-barbeiro.json
04-regua-lembrete.json
01-pagamento-provisionamento.json
```

4. Em **Settings → Error Workflow** de cada um, aponte para
   `99 - Erro e fila morta`. Sem isso, falha vira execução vermelha que ninguém
   vê — e falha silenciosa é o pior defeito de uma infra de entrega.
5. Ative `02` e `04`. Deixe `01` e `05` inativos até o passo 7.

**Portão:** com o evento do passo 3 ainda pendente, ative o `02` e espere um
minuto.

```sql
select evento, entregue_em from eventos_saida order by criado_em desc limit 1;
-- esperado: entregue_em preenchido
```

Se continuar nulo: olhe a execução no n8n. Se nem executou, o Schedule Trigger
não está ativo. Se executou e falhou, o erro está na credencial do Postgres.

---

## 6. WhatsApp

1. Meta Business → app → produto WhatsApp → número.
2. **Aqueça o número.** O vault registra isso como requisito, não zelo: número
   novo disparando volume é banido. Comece com poucas mensagens por dia.
3. Cadastre os templates e espere aprovação:

```
novo_agendamento_barbeiro
agendamento_cancelado_barbeiro
agendamento_remarcado_barbeiro
agendamento_confirmado_barbeiro
lembrete_cliente_2h
lembrete_cliente_agora
```

   Mensagem fora da janela de 24h **exige** template aprovado. Sem isso o fluxo
   só funciona em conversa já aberta pelo cliente.
4. Webhook da Meta → `https://$N8N_HOST/webhook/whatsapp` com o
   `WHATSAPP_VERIFY_TOKEN`. Assine o campo `messages`.

**Portão:** mande uma mensagem de teste pelo `06` para o seu próprio número e
confira `select * from mensagens_enviadas order by criado_em desc limit 1;` com
`status = 'enviado'`.

---

## 7. O webhook de pagamento

Só depois de tratados os itens altos da revisão.

1. Stripe → Developers → Webhooks → endpoint
   `https://$N8N_HOST/webhook/pagamento/stripe`, com os cinco eventos de
   `03-fluxo-pagamento.md`.
2. Copie o signing secret para `STRIPE_WEBHOOK_SECRET`.
3. Rode o teste de `curl` de `03-fluxo-pagamento.md`, **incluindo a repetição** —
   é ela que prova a idempotência.
4. Ative o `01`.

**Portão:** assinatura válida → 200 e uma linha em `webhooks_recebidos`; mesmo
comando repetido → 200 e **nenhuma** linha nova; assinatura inválida → 400 e
nenhuma linha.

---

## 8. O que olhar depois, todo dia

```sql
select * from automacao_saude;
```

Os cinco números devem ser zero. Qualquer um diferente de zero significa
**cliente ou barbeiro não avisado**:

| Coluna | O que investigar |
|---|---|
| `eventos_presos` | workflow `02` inativo, ou credencial do Postgres quebrada |
| `lembretes_atrasados` | workflow `04` inativo, ou `06` falhando |
| `lembretes_falhados` | esgotou tentativas — ver `ultimo_erro` na linha |
| `fila_morta_aberta` | ler `fila_morta`, corrigir a causa, reprocessar à mão |
| `webhooks_nao_processados` | `01` falhando depois do 200 |

Vale um alerta automático em cima dessa view. Painel que depende de alguém
lembrar de abrir não é monitoramento.
