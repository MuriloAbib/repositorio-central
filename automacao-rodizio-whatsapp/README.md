# Automação de rodízio de número de WhatsApp

Distribuição automática e **justa** de leads entre vários consultores de vendas,
em um site de e-commerce/catálogo. Cada visitante que clica em "falar com um
consultor" é enviado para o WhatsApp do próximo da fila — e a fila é a mesma
para todos os visitantes do mundo.

Extraído de um sistema **em produção**: site de venda de máquinas de sorvete
expresso (ticket médio ~R$ 17.000), 3 consultores, rodízio 1:1:1.

```
┌──────────────┐   clique    ┌─────────────────┐    RPC     ┌──────────────────┐
│  Visitante   │ ──────────> │ Função de       │ ─────────> │ PostgreSQL       │
│  (navegador) │             │ servidor (SSR)  │            │ proximo_rodizio()│
└──────────────┘             └─────────────────┘            └──────────────────┘
       │                                                              │
       │                       posição (0, 1, 2, 3, ...)              │
       │ <────────────────────────────────────────────────────────────┘
       │
       │  RODIZIO_BASE[posicao % 3]  →  Consultor B
       │
       v
┌──────────────────────────────────┐        ┌───────────────────────────┐
│ wa.me/55119...?text=Olá,%20vi... │        │ consultor_cliques         │
│ (abre no WhatsApp do consultor)  │        │ (auditoria da justiça)    │
└──────────────────────────────────┘        └───────────────────────────┘
```

---

## O problema que isto resolve

Um site com **um** número de WhatsApp e **três** consultores tem três saídas
possíveis, e duas delas são ruins:

| Abordagem | O que acontece na prática |
|---|---|
| Número fixo | Um consultor recebe 100% dos leads. Os outros dois não têm o que fazer, e o primeiro não dá conta no pico. |
| `Math.random()` no clique | Com ~30 leads/mês, a aleatoriedade tem desvio grande: é perfeitamente normal um consultor receber 15 e outro receber 5 no mesmo mês. Em amostra pequena, sorteio não é justiça. |
| **Rodízio com contador global** | Exatamente 1 de cada 3, sempre, de forma verificável. É o que está implementado aqui. |

E tem um detalhe que derruba a solução ingênua: **o contador não pode morar no
navegador.** Ver [docs/DECISOES-DE-ENGENHARIA.md](docs/DECISOES-DE-ENGENHARIA.md#1-por-que-o-contador-não-pode-morar-no-navegador)
— é o erro mais caro e menos óbvio deste problema.

---

## O código, em cinco arquivos

Leia nesta ordem. Cada arquivo é o código real de produção, comentado linha a
linha explicando **por que** está daquele jeito.

| # | Arquivo | O que é | Linhas que importam |
|---|---|---|---|
| 1 | [codigo/01-banco-rodizio.sql](codigo/01-banco-rodizio.sql) | O contador global e a função atômica no PostgreSQL. **O coração do mecanismo.** | 21 |
| 2 | [codigo/02-rodizio.functions.ts](codigo/02-rodizio.functions.ts) | A função de servidor que chama o banco, e a fronteira que mantém a chave secreta fora do navegador. | 9 |
| 3 | [codigo/03-rodizio-cliente.ts](codigo/03-rodizio-cliente.ts) | A lista, a ordem da fila, o fallback, o saneamento do número e o truque do pop-up. | ~120 |
| 4 | [codigo/04-whatsapp-tracking.ts](codigo/04-whatsapp-tracking.ts) | Um único listener delegado que mede todo clique de WhatsApp do site. | 30 |
| 5 | [codigo/05-uso-nos-componentes.tsx](codigo/05-uso-nos-componentes.tsx) | Os dois modos de consumo (botão direto e formulário) e a atribuição do lead. | — |

O mecanismo inteiro cabe em **~60 linhas de lógica**. O resto é cuidado com os
casos de borda, e é aí que mora a diferença entre funcionar na demonstração e
funcionar em produção.

---

## Documentação

- **[docs/COMO-FUNCIONA.md](docs/COMO-FUNCIONA.md)** — o caminho completo de um
  clique, do dedo do visitante até a conversa aberta no WhatsApp do consultor.
  Passo a passo, com o que acontece em cada camada.
- **[docs/DECISOES-DE-ENGENHARIA.md](docs/DECISOES-DE-ENGENHARIA.md)** — as dez
  decisões que fazem o código ser assim, cada uma com o bug que ela evita.
  Inclui as armadilhas que não são óbvias: race condition no contador,
  pop-up blocker depois de `await`, envenenamento da fila, tabnabbing, e o
  evento de conversão que não chegava ao Google.
- **[docs/COMO-IMPLEMENTAR.md](docs/COMO-IMPLEMENTAR.md)** — passo a passo para
  replicar isto do zero em outro projeto, incluindo como adaptar para quem não
  usa Supabase nem TanStack Start.

---

## Stack

| Camada | Tecnologia |
|---|---|
| Banco / contador | PostgreSQL (via Supabase), função `SECURITY DEFINER` |
| Servidor | TanStack Start 1.168 (`createServerFn`), função SSR |
| Front-end | React 19, TypeScript 5.8, Tailwind CSS 4 |
| Validação de formulário | Zod 3 |
| Hospedagem do app | Netlify (função SSR) |
| Domínio e e-mail | Hostinger (DNS aponta para a Netlify; MX/SPF/DKIM ficam na Hostinger) |
| Medição | Google Analytics / Google Ads via `gtag` |

O mecanismo **não depende** dessa stack. A única exigência real é um
contador compartilhado com incremento atômico — ver
[docs/COMO-IMPLEMENTAR.md](docs/COMO-IMPLEMENTAR.md#adaptando-para-outra-stack)
para as variantes em Redis, MySQL e Postgres puro.

---

## O que este código tem de incomum

Os pontos que valem a leitura, mesmo para quem não vai implementar rodízio:

1. **Uma instrução SQL em vez de uma transação.** `INSERT ... ON CONFLICT DO
   UPDATE ... RETURNING contador - 1` lê, incrementa e devolve o valor anterior
   num só comando. Nenhuma race condition é possível porque não existe janela
   entre leitura e escrita.
   ([arquivo 1](codigo/01-banco-rodizio.sql))

2. **Abrir uma aba em branco antes de saber o destino.** O navegador só permite
   `window.open` dentro do gesto do usuário, mas o número só é conhecido depois
   de uma ida ao servidor. A aba é aberta síncrona em `about:blank` e só depois
   navegada. É a diferença entre o botão funcionar e o pop-up ser bloqueado.
   ([arquivo 3](codigo/03-rodizio-cliente.ts))

3. **`SECURITY DEFINER` com `REVOKE` para `anon`.** Sem o revoke, qualquer
   visitante poderia chamar a função mil vezes com um `curl` e travar a fila no
   índice de um consultor — fazendo todos os leads reais caírem para ele.
   ([arquivo 1](codigo/01-banco-rodizio.sql))

4. **Import dinâmico como fronteira de segurança.** Em TanStack Start, um
   `*.functions.ts` vai para o bundle do navegador. O `await import()` do
   cliente admin dentro do handler é o que impede a chave de serviço de ser
   publicada no JavaScript do site.
   ([arquivo 2](codigo/02-rodizio.functions.ts))

5. **Degradação em vez de erro.** Servidor fora do ar não pode significar botão
   que não abre: cai para um contador local, menos justo, e o lead é atendido.
   Em um produto de R$ 17 mil, um `throw` num clique de WhatsApp é uma venda
   perdida. ([arquivo 3](codigo/03-rodizio-cliente.ts))

6. **Auditoria como parte do mecanismo.** Cada posição entregue é gravada em
   `consultor_cliques`. Sem isso, "distribuo 1:1:1" é uma afirmação sem prova —
   e discussão de consultor no fim do mês não se resolve com opinião.
   ([arquivo 1](codigo/01-banco-rodizio.sql), [arquivo 5](codigo/05-uso-nos-componentes.tsx))

As limitações conhecidas e o que eu mudaria estão em
[docs/DECISOES-DE-ENGENHARIA.md](docs/DECISOES-DE-ENGENHARIA.md#o-que-eu-mudaria).

---

## Nota sobre os dados

Os nomes, e-mails e telefones dos consultores foram substituídos por exemplos
(`Consultor A`, `+55 11 90000-0001`). São dados pessoais de terceiros e não
cabem num repositório público. **A estrutura do código é idêntica à de
produção** — nenhuma lógica foi simplificada, removida ou "arrumada" para a
vitrine, incluindo o `as any` que sobrou de uma migração de tipos e está
documentado como dívida técnica no [arquivo 2](codigo/02-rodizio.functions.ts).
