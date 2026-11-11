# Fluxo B — agendamento vira aviso no WhatsApp do barbeiro

Este é o fluxo que **não existe hoje**. O BarberBook grava o agendamento e
pronto: ninguém é avisado. O barbeiro descobre abrindo o painel.

## O caminho inteiro

```
 1. cliente marca            app.agendamentos.tsx  (painel)
                             agendar.$slug.tsx     (link público)
                             cliente.*             (área do cliente)
                                     │
                                     │ INSERT INTO appointments
                                     ▼
 2. gatilho                  agendamento_para_automacao        [0011]
    (MESMA transação)                │
                          ┌──────────┴──────────┐
                          ▼                     ▼
 3. eventos_saida                        lembretes
    evento=agendamento.criado            disparar_em pela régua de 2h
    dados=contexto_do_agendamento        destino=cliente
                          │                     │
 4. n8n lê         02-notifica-barbeiro    04-regua-lembrete
    (1 min)        reservar_eventos_saida  reservar_lembretes_devidos
                          │                     │
 5. monta texto    converte UTC -> fuso local, formata pt-BR
                          │                     │
                          └──────────┬──────────┘
                                     ▼
 6. envio                    06-enviar-mensagem
                             dedupe por chave_dedupe ANTES de enviar
                                     │
                          ┌──────────┴──────────┐
                          ▼                     ▼
                    WhatsApp Cloud API       e-mail
                                     │
 7. fecha            marcar_evento_entregue / marcar_lembrete_enviado
                     falha -> lease expira -> próxima rodada
                     esgotou -> fila_morta + alerta (99)
```

## Por que gatilho, e não chamada da aplicação

O agendamento nasce em **três** lugares do app. Se a emissão do evento fosse
responsabilidade da aplicação, cada um dos três teria de lembrar de emitir — e
o que fosse esquecido viraria agendamento sem aviso, **em silêncio**, que é a
pior forma de defeito nesse tipo de sistema: parece funcionando.

No gatilho não há como esquecer, e há um ganho que não é pequeno: **o app do
Lovable não precisa de nenhuma alteração.** Nenhum commit no projeto, nenhum
redeploy, nenhum crédito gasto no agente do Lovable.

O custo dessa escolha, para ficar registrado: lógica de negócio dentro de
gatilho é mais difícil de testar e de ver. Mitigação adotada — o gatilho não
decide nada, só **registra fato** (`ao_mudar_agendamento` em `0011` apenas emite
evento e chama `agendar_lembrete`); toda a decisão de conteúdo e canal está no
n8n e em `agendar_lembrete`, que é uma função isolada e testável.

## O padrão outbox, para quem não viu antes

O jeito ingênuo é: grava o agendamento, depois chama o n8n.

```
BEGIN; INSERT appointments; COMMIT;
fetch('https://n8n/webhook/...')     ← e se morrer aqui?
```

Se o processo morre entre o `COMMIT` e o `fetch`, o agendamento existe e o aviso
nunca sai. Não há retry possível, porque ninguém sabe que faltou avisar.

O outbox resolve pondo o evento **dentro** da transação:

```
BEGIN;
  INSERT appointments;
  INSERT eventos_saida;     ← commita junto, atômico
COMMIT;
```

Agora as duas coisas existem ou nenhuma existe. A entrega virou um problema
separado e **recuperável**: há uma linha no banco dizendo "isto precisa sair", e
um poller que insiste até sair. Se o n8n ficar fora do ar duas horas, nada se
perde — ele entrega quando volta.

É também o que torna a pergunta "o que deveria ter saído e não saiu?"
respondível. A view `automacao_saude` (`0012`) é exatamente essa pergunta.

## FOR UPDATE SKIP LOCKED, e o que acontece sem ele

O n8n em queue mode roda N workers. Se o poller fosse

```sql
select * from eventos_saida where entregue_em is null limit 20;
```

os dois workers leriam as **mesmas** 20 linhas no mesmo segundo, e o barbeiro
receberia cada aviso em dobro.

`FOR UPDATE` sozinho também não serve: o segundo worker **bloqueia** esperando o
primeiro, e a vazão da fila cai para a de um worker só — perde-se o paralelismo
que motivou o queue mode.

`FOR UPDATE SKIP LOCKED` dá as duas coisas: o segundo worker não espera, pula as
linhas travadas e pega as próximas.

Em cima disso há um **lease** (`reservado_ate`). SKIP LOCKED só protege durante a
transação; quando ela commita, a linha destrava. Se o worker morrer **depois** do
commit da reserva e **antes** de entregar, sem lease a linha ficaria marcada como
reservada para sempre. Com lease, ela expira e volta à fila.

E o contador de tentativas sobe **na reserva**, não na falha. Worker que morre
sem reportar nada ainda consome uma tentativa — se o contador só subisse no
caminho de erro, um evento que derruba o worker toda vez (payload que quebra o
parser) seria tentado para sempre.

## A mensagem ao barbeiro

Montada em `02-notifica-barbeiro.json`, nó **"Monta a mensagem"**.

| Template | Quando | Variáveis |
|---|---|---|
| `novo_agendamento_barbeiro` | `agendamento.criado` | profissional, cliente, servico, data, hora, telefone_cliente, loja |
| `agendamento_cancelado_barbeiro` | `agendamento.cancelado` | profissional, cliente, servico, data, hora |
| `agendamento_remarcado_barbeiro` | `agendamento.remarcado` | + `antes` (o horário anterior) |
| `agendamento_confirmado_barbeiro` | `agendamento.confirmado` | profissional, cliente, servico, data, hora |

**Para quem vai.** `coalesce(staff.phone, profiles.phone)` — o telefone do
profissional atribuído, ou o do dono quando `appointments.staff_id` é nulo. Sem
esse coalesce, barbearia de um só profissional (que não cria linha em `staff`)
nunca receberia aviso. O canal cai para e-mail quando não há telefone.

**Onde o fuso é convertido.** Só aqui. O banco guarda `timestamptz` e o envelope
transporta UTC com `Z` (função `iso_utc` em `0011`); a conversão para
`America/Sao_Paulo` acontece no nó de montagem, que é a borda de apresentação.
Se a conversão acontecesse antes, o mesmo evento sairia com offset diferente
dependendo de quem o emitiu — painel, webhook ou `psql` têm `TimeZone` de sessão
diferentes.

**Evento sem destino é marcado como entregue de propósito** (nó "Encerra sem
envio"). Deixá-lo na fila faria o poller tentar para sempre e o painel de
"eventos presos" encher de ruído permanente — que é o que faz um painel de saúde
parar de ser olhado.

## Dedupe: a chave descreve o quê, não o quando

```
chave_dedupe = `${evento}:${appointment_id}`      ex: agendamento.criado:a1b2...
```

`UNIQUE (owner_id, chave_dedupe)` em `mensagens_enviadas` é a única coisa entre
uma reentrega do n8n e o barbeiro recebendo a mesma mensagem duas vezes. O
sub-workflow `06` **reserva** a linha antes de chamar o provedor; se o insert
conflitar, é reentrega e o envio não acontece.

Por isso a chave nunca pode conter timestamp nem aleatório: chave que muda a
cada tentativa não deduplica nada.

## Fluxo C — a confirmação sim/não

O lembrete do cliente pede confirmação. A resposta entra pelo webhook da Cloud
API (`05`), que normaliza e repassa ao backend.

**A máquina de estados fica no backend, não no canvas.** O vault registra o
motivo: estado conversacional por número, dentro da janela de 24h da Meta,
modelado em iPaaS visual produz fluxo ilegível. O n8n só traduz e transporta.

Dois cuidados que o `05` tem de ter:

1. **Dedupe pelo id da mensagem da Meta.** A Meta entrega *at-least-once*; sem
   dedupe o cliente confirma duas vezes.
2. **Ignorar `statuses`.** O webhook da Cloud API manda `messages` (gente
   falando) e `statuses` (sent/delivered/read). Tratar `statuses` como mensagem
   faz o bot responder a confirmações de entrega.

Resposta que não é claramente sim nem não **não vira palpite**: devolve a
pergunta. Interpretar "talvez" como "sim" cancela ou confirma corte errado.

## Testar sem WhatsApp

1. Rode as três migrações de `../sql/`.
2. `INSERT INTO appointments (...)` com `scheduled_at = now() + interval '5 hours'`.
3. Confira que o gatilho fez o trabalho:

```sql
select evento, dados -> 'cliente' ->> 'nome', entregue_em
  from eventos_saida order by criado_em desc limit 5;

select tipo, disparar_em, canal, destino, status
  from lembretes order by criado_em desc limit 5;
```

   Esperado: um `agendamento.criado` com `entregue_em` nulo, e um lembrete
   `pendente` com `disparar_em = scheduled_at - 2h`.

4. Importe os workflows e deixe o `02` rodar. `entregue_em` deve preencher.
5. `select * from automacao_saude;` — os cinco números devem ser zero.
