# Glossário

Toda palavra difícil que aparece nos três projetos, explicada do jeito que eu queria
ter lido na primeira vez. Ordem de utilidade, não alfabética.

---

## O básico do n8n

**Nó (*node*)** — uma caixinha no canvas. Faz uma coisa só: recebe dados, mexe neles,
passa pra frente. Um fluxo é uma fila de caixinhas.

**Workflow (fluxo)** — o desenho inteiro: os nós e as linhas entre eles. É o que você
exporta/importa como `.json`.

**Trigger (gatilho)** — o primeiro nó, o único que não tem entrada. É o que faz o fluxo
começar. Dois tipos aparecem aqui:
- **Webhook** — espera alguém bater num endereço (reativo).
- **Schedule Trigger** — dispara pelo relógio (ativo).

**Execução (*execution*)** — uma rodada do fluxo, do começo ao fim. Verde = terminou,
vermelho = quebrou no meio. Fica salva em *Executions*, onde você vê o que passou
por dentro de cada nó.

**Item** — o n8n não trabalha com "um dado", trabalha com uma **lista** de itens. Se
entram 10 itens num nó, ele roda 10 vezes (ou uma vez pra todos, se for nó de código
em modo *Run Once for All Items*). É a causa nº 1 de confusão de quem começa.

**`$json`** — dentro de uma expressão, é o item que está passando por ali naquele
momento. `{{ $json.email }}` = "o campo email do item atual".

**Expressão** — campo que começa com `=` e usa `{{ }}` pra calcular algo em vez de
ter valor fixo. `={{ $json.subtotal >= 299 ? 0 : 29.9 }}` é uma expressão com
**ternário** (um `if` de uma linha: `condição ? então : senão`).

**`$('Nome do nó')`** — alcança a saída de um nó **anterior**, não só do nó imediatamente
atrás. É como você não perde o dado original depois de uma chamada HTTP no meio do
caminho. Usado no Valid8 e no Captur8.

**Credencial** — onde o n8n guarda token, senha e chave de API. Fica no banco do n8n,
**separada** do workflow. Por isso dá pra publicar o `workflow.json` num repositório
público sem vazar segredo: o export só guarda o *nome* e o *id* da credencial.

**Sticky Note** — post-it no canvas. Não faz nada, só documenta. Todo fluxo deste
repositório tem um, com a explicação de como rodar.

---

## Palavras de web/HTTP

**Webhook** — um endereço (URL) que fica parado esperando alguém mandar dados pra ele.
A diferença de uma API normal: aqui **você** é quem recebe, não quem chama. É o
"interfone" do seu fluxo.

**Endpoint** — o endereço final de um serviço. `https://seu-n8n.com/webhook/captur8`
é um endpoint.

**Payload** — a carga, o conteúdo que veio junto da requisição. No n8n, o payload de
um POST chega dentro de **`body`**: é por isso que o código dos projetos começa com
`item.json.body`, e não `item.json`.

**Método HTTP** — o verbo da requisição. `GET` = me dá; `POST` = tome, guarda isso;
`PUT`/`PATCH` = altera; `DELETE` = apaga. Os webhooks daqui são todos POST.

**JSON** — o formato de texto em que os dados viajam: `{"nome": "Ana", "qtd": 2}`.
Chave e valor entre chaves. É a língua nativa do n8n.

**Código de status** — o número que a resposta devolve. `200` deu certo, `201` criou,
`400` você mandou errado, `401` você não se identificou, `403` não pode, `404` não
existe, `422` entendi mas os dados não servem, `429` calma, `500` o erro foi meu.

**`curl`** — programa de linha de comando pra bater num endereço. É o jeito mais
rápido de testar webhook sem precisar de formulário nenhum.

**REST / API pública** — serviço que você consulta por HTTP. A ViaCEP, usada no Valid8,
é pública: não precisa de chave, só bater na URL.

**Timeout** — tempo máximo de espera antes de desistir da chamada. Sem timeout, um
servidor travado trava o seu fluxo junto.

---

## Palavras de automação

**Cron** — a notação de agendamento (`*/5 * * * *` = de 5 em 5 minutos). O
Schedule Trigger do n8n deixa você escolher pelo menu, mas o nome por baixo é cron.

**Polling** — ficar perguntando de tempo em tempo "e agora, mudou?". É o que o
Notific8 faz. O oposto de webhook (que avisa só quando muda). Polling é mais burro
e mais confiável; webhook é mais elegante e depende do outro lado colaborar.

**Idempotência** — a propriedade de poder repetir a mesma operação sem duplicar o
efeito. Se o formulário dispara duas vezes, você quer **um** lead, não dois. Resolve-se
com uma **chave de idempotência** (no Captur8, o e-mail): algo estável que identifica
"isso aqui eu já vi".

**Estado entre execuções** — memória que sobrevive ao fim da execução. No n8n é
`$getWorkflowStaticData('global')`: um objeto que você escreve numa rodada e lê na
seguinte. É o que impede o Notific8 de virar spam.

**Retry** — tentar de novo automaticamente quando falha. Nos nós: *Settings → Retry
On Fail*, com número de tentativas e intervalo. Serve pra falha passageira (rede,
limite de API), não pra erro de lógica — repetir um dado errado só erra mais rápido.

**Fallback** — o caminho do "nenhuma das anteriores". No nó Switch é uma saída extra
onde cai o que não casou com regra nenhuma. Fluxo sem fallback engole dado em silêncio,
que é o pior tipo de bug: o que não aparece.

**Never Error / Continue on Fail** — opção que transforma a falha em **dado** em vez
de exceção. Em vez da execução morrer, ela segue com o erro dentro do item, e você
decide o que fazer. Essencial em qualquer fluxo cujo trabalho é justamente detectar
falha.

**Enriquecimento de dados** — completar o que o cliente mandou com informação de outra
fonte. O Valid8 recebe 8 dígitos de CEP e devolve rua, bairro, cidade e UF.

**Flood / anti-flood** — a enxurrada de notificações repetidas, e a trava que evita
ela. Avisar na virada de estado, não em toda verificação.

---

## Armadilhas com nome próprio

**200 mentiroso** — o servidor responde `200 OK` e entrega uma página de erro. Checar
só o código de status não detecta isso; é por isso que o Notific8 também procura um
texto que *tem* que estar na página.

**O erro que a API esconde no corpo** — a ViaCEP não devolve `404` pra CEP inexistente:
devolve `200` com `{"erro": true}`. Cada API inventa a sua; sempre olhe o corpo da
resposta antes de confiar no status.

**URL de teste ≠ URL de produção** — `/webhook-test/...` só responde com a aba aberta
e *Listen for test event* ligado. `/webhook/...` só existe com o workflow **Active**.
Quase todo "meu webhook não funciona" é isso.
