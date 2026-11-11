# autom8-lab

**Três automações no n8n, do zero até o webhook respondendo.**

Esse repositório é o meu caderno de laboratório do n8n. Cada pasta é uma automação
pequena, inteira, que roda — com o workflow exportado em JSON pronto pra importar,
o passo a passo do que eu cliquei, o comando pra testar e a lista do que deu errado
no caminho.

A ideia não é ter um fluxo gigante e impressionante. É ter três fluxos pequenos que
cobrem, juntos, o vocabulário que todo mundo usa e quase ninguém explica: webhook,
payload, nó, trigger, cron, expressão, credencial, idempotência, fallback, retry e
estado entre execuções.

---

## Os três projetos

| # | Projeto | O que faz | O que ele ensina | Precisa de credencial? |
|---|---------|-----------|------------------|------------------------|
| 1 | **[Captur8](01-captur8/)** | Recebe lead de formulário e grava na planilha | Webhook, payload, validação, resposta HTTP | Google Sheets (OAuth2) |
| 2 | **[Notific8](02-notific8/)** | Vigia um site de 5 em 5 min e avisa no Telegram quando cai | Schedule Trigger (cron), estado entre execuções, anti-flood | Telegram Bot (token) |
| 3 | **[Valid8](03-valid8/)** | Recebe um pedido, consulta o CEP e devolve frete e prazo | Enriquecimento de dados, referência entre nós, Switch com fallback | Nenhuma |

Os nomes seguem o apelido da casa: o **8** do `n8n` no fim do verbo da automação —
**captur**-8, **notific**-8, **valid**-8.

---

## Ordem recomendada

Dá pra fazer em qualquer ordem, mas na sequência abaixo cada projeto usa o conceito
do anterior:

1. **[Subir o n8n](docs/00-subindo-o-n8n.md)** — Docker ou npx, e a diferença entre
   URL de teste e URL de produção. Dez minutos.
2. **[Captur8](01-captur8/)** — aqui você entende o que é um webhook de verdade:
   um endereço que fica esperando alguém bater nele.
3. **[Notific8](02-notific8/)** — o oposto do Captur8: ninguém chama, o relógio
   dispara. E a primeira vez que você precisa guardar memória entre execuções.
4. **[Valid8](03-valid8/)** — junta os dois mundos: webhook na entrada, chamada a
   uma API externa no meio, roteamento condicional na saída.

Palavra que apareceu e você não conhece? Está no **[GLOSSÁRIO](GLOSSARIO.md)**.

---

## Como usar um projeto daqui

Todo projeto tem a mesma estrutura, e o `workflow.json` é importável direto:

1. No n8n, canto superior direito: **⋯ → Import from File**.
2. Escolha o `workflow.json` da pasta do projeto.
3. O canvas abre com um **Sticky Note amarelo/laranja** explicando o fluxo por dentro.
4. Troque o que está marcado com `TROQUE_` (credencial, ID de planilha, chat do Telegram).
5. Siga o `README.md` da pasta a partir do passo de teste.

> **Sobre credenciais:** nenhum token, senha ou ID real foi versionado aqui. Todo
> lugar que precisa de segredo está com um marcador `TROQUE_PELA_SUA_CREDENCIAL`.
> Credencial no n8n vive no banco do n8n, não no JSON do workflow — o export só
> guarda uma referência a ela. Isso é proposital: é o que torna seguro publicar
> workflow em repositório público.

---

## Estrutura

```
autom8-lab/
├── README.md                     ← você está aqui
├── GLOSSARIO.md                  ← toda palavra difícil, em uma linha
├── docs/
│   ├── 00-subindo-o-n8n.md       ← instalação e o básico do canvas
│   └── imagens/                  ← prints do canvas de cada projeto
├── 01-captur8/
│   ├── README.md                 ← passo a passo
│   ├── workflow.json             ← importável no n8n
│   └── testar.sh                 ← curl de teste (caso bom e caso ruim)
├── 02-notific8/
│   ├── README.md
│   └── workflow.json
└── 03-valid8/
    ├── README.md
    ├── workflow.json
    └── testar.sh
```

---

## O que eu levei desses três

Três coisas que eu não sabia antes e que valem mais que os fluxos em si:

1. **O nó que falha para o fluxo inteiro.** Um site caído fazia a execução morrer
   em vermelho antes de conseguir avisar que o site estava caído. A correção é a
   opção **Never Error** no nó HTTP: transformar a falha em dado (um `statusCode`)
   em vez de em exceção. Falha que você consegue ler é falha que você consegue tratar.

2. **Webhook tem dois endereços, e o de teste não funciona sozinho.** A URL de teste
   só responde enquanto a aba está aberta com *Listen for test event* ligado. A de
   produção só existe depois de **Active**. Perdi tempo achando que o fluxo estava
   quebrado quando era só isso.

3. **Automação sem trava de repetição é spam.** O Notific8 funcionava e me mandava
   12 mensagens por hora sobre a mesma queda. O que resolve não é piorar a condição
   do alerta — é guardar estado e avisar **na virada**: caiu, voltou.

---

## Licença

MIT — use, copie, mude. Se algum fluxo daqui te poupar uma tarde, já valeu.
