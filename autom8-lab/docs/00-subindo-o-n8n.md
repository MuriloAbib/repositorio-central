# 00 — Subindo o n8n

Antes dos três projetos: ter um n8n rodando e entender quatro coisas do canvas.
Dez minutos.

---

## Qual jeito escolher

| Jeito | Comando | Quando usar |
|-------|---------|-------------|
| **npx** | `npx n8n` | só pra experimentar agora, no seu PC |
| **Docker** | ver abaixo | o jeito que eu uso: dado persiste, sobe junto com o sistema |
| **n8n Cloud** | conta no site | se você não quer administrar nada e topa pagar |

Os três projetos deste repositório rodam igual nos três.

### npx (o mais rápido)

```bash
npx n8n
```

Abre em `http://localhost:5678`. Fecha o terminal, para tudo. Os dados ficam em
`~/.n8n`, então na próxima vez que você rodar o fluxo ainda está lá.

### Docker (o que eu uso)

```bash
docker volume create n8n_data

docker run -d \
  --name n8n \
  -p 5678:5678 \
  -v n8n_data:/home/node/.n8n \
  -e GENERIC_TIMEZONE="America/Sao_Paulo" \
  -e TZ="America/Sao_Paulo" \
  docker.n8n.io/n8nio/n8n
```

Três detalhes que importam:

- **`-v n8n_data:/home/node/.n8n`** — sem esse volume, apagar o contêiner apaga
  seus workflows e credenciais. Com ele, `docker rm` não dói.
- **`GENERIC_TIMEZONE`** — é o fuso que o **Schedule Trigger** usa. Sem isso o
  cron roda em UTC e o seu "todo dia às 9h" vira 6h da manhã.
- **porta 5678** — se já tiver algo nela, troque o lado de fora: `-p 5679:5678`.

Primeiro acesso em `http://localhost:5678`: ele pede pra criar o usuário dono.
É local, mas use senha de verdade — esse painel vai guardar seus tokens.

---

## Os quatro conceitos do canvas

### 1. O fluxo anda da esquerda pra direita

O primeiro nó é o **trigger** (gatilho) — o único sem entrada do lado esquerdo.
Sem trigger, o fluxo não tem como começar.

### 2. Teste nó por nó, não o fluxo todo

Cada nó tem um botão de **play** só dele. Clique nele e veja, no painel da direita,
o que entrou e o que saiu. É assim que se depura n8n: olhando o dado, não adivinhando.

### 3. Dado vem em lista, sempre

O painel mostra `INPUT` e `OUTPUT` em tabela porque o n8n sempre trabalha com uma
**lista de itens**. Um item só ainda é uma lista de um. Se um nó recebe 10 itens,
ele roda 10 vezes — menos nó de código em modo *Run Once for All Items*.

### 4. Para arrastar um campo, não digite o caminho

No painel do nó, arraste o campo da coluna `INPUT` para dentro do campo que você
quer preencher. O n8n escreve a expressão sozinho (`{{ $json.email }}`) e você não
erra o nome. Digitar o caminho na mão é a origem da metade dos `undefined`.

---

## Webhook: as duas URLs

Esse é **o** tropeço do início. Todo nó Webhook tem dois endereços:

| | URL | Quando responde |
|---|-----|-----------------|
| **Teste** | `http://localhost:5678/webhook-test/captur8` | só com a aba do n8n aberta **e** o botão *Listen for test event* ligado. Pega **uma** requisição e para. |
| **Produção** | `http://localhost:5678/webhook/captur8` | sempre — desde que o workflow esteja **Active** (a chavinha no topo). |

Então:

- Testando e ninguém chega? Confira se clicou em *Listen for test event*.
- Ativou e chamou a URL de teste? Dá `404`. Troque `webhook-test` por `webhook`.
- `localhost` só funciona pra você. Pra um serviço de fora chamar (Typeform, Shopify,
  Z-API), o n8n precisa de endereço público: `ngrok http 5678` pra testar, ou um
  domínio de verdade pra valer. Nesse caso configure também
  `-e WEBHOOK_URL="https://seu-dominio.com.br/"`, senão o n8n mostra na tela a URL
  `localhost` em vez da pública.

---

## Importando os workflows deste repositório

1. Canto superior direito: **⋯ → Import from File**
2. Escolha o `workflow.json` da pasta do projeto
3. O canvas abre com tudo montado e um post-it explicando o fluxo
4. Procure os campos marcados com `TROQUE_` e preencha com os seus
5. Teste nó por nó antes de ativar

Importar **não** traz credencial — credencial não viaja no JSON, de propósito. Os nós
que precisam de uma vão aparecer com um aviso até você escolher a sua no campo
*Credential to connect with*.

---

## Onde ver o que aconteceu

Menu lateral → **Executions**. Toda rodada fica registrada: o que entrou, o que saiu
de cada nó, quanto tempo levou e, se quebrou, em qual nó.

Para fluxo com trigger de relógio (o Notific8), é o único lugar onde você vê o que
rolou às 3h da manhã. Vale olhar depois da primeira noite ativado — é lá que aparece
o erro que você não viu acontecer.

> Dica: numa execução que deu certo, clique em **Pin** no nó de entrada. O dado fica
> grudado (*pinned data*) e os próximos testes usam ele em vez de chamar o serviço
> de novo. Isso poupa requisição em API paga e deixa o teste repetível.

---

Pronto. Próximo: **[01 — Captur8](../01-captur8/)**.
