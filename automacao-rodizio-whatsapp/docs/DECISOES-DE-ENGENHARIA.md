# Decisões de engenharia

Dez decisões, cada uma com o bug que ela evita. A ordem é de impacto: as
primeiras quebram o sistema, as últimas custam dinheiro de forma silenciosa.

---

## 1. Por que o contador não pode morar no navegador

**A solução ingênua.** `localStorage` guarda o índice atual, incrementa a cada
clique, pronto — sem servidor, sem banco, sem custo.

**Por que ela não funciona.** `localStorage` é por navegador. Um visitante novo
tem o contador em zero, então recebe sempre o **primeiro** consultor da fila.

E quem é o visitante de um site de catálogo? Alguém que acabou de clicar num
anúncio e nunca esteve ali antes. O perfil dominante do tráfego **é** o
visitante novo. A consequência:

| Tipo de visitante | Quem atende |
|---|---|
| 1º clique (maioria absoluta) | sempre o Consultor B (índice 0) |
| 2º clique na mesma sessão | Consultor A |
| 3º clique na mesma sessão | Consultor C |

Um visitante raramente clica duas vezes. O resultado é um rodízio que distribui
quase tudo para um consultor — exatamente o problema que ele existia para
resolver, agora com código a mais e a aparência de estar resolvido.

**A decisão.** O contador é uma linha no PostgreSQL, compartilhada por todos os
visitantes. O primeiro clique da Maria em São Paulo e o primeiro clique do João
em Recife avançam o **mesmo** número.

**Custo aceito.** Um round-trip ao servidor antes de abrir o WhatsApp (~100–300
ms) e uma dependência de rede no caminho do clique. O segundo custo é coberto
pela decisão 6; o primeiro é invisível porque a aba já abriu (decisão 5).

---

## 2. Uma instrução SQL em vez de uma transação

**A solução ingênua.**

```ts
const { data } = await db.from("rodizio_estado").select("contador").eq("id", "consultores").single();
const novo = data.contador + 1;
await db.from("rodizio_estado").update({ contador: novo }).eq("id", "consultores");
return data.contador;
```

**Por que ela não funciona.** Entre o `select` e o `update` existe uma janela.
Dois cliques simultâneos:

```
tempo   clique A              clique B           contador no banco
─────   ────────              ────────           ─────────────────
t0      SELECT → 5                               5
t1                            SELECT → 5         5
t2      UPDATE → 6                               6
t3                            UPDATE → 6         6
```

Ambos recebem a posição 5 → **o mesmo consultor atende os dois, e o próximo da
fila é pulado.** Com três consultores e tráfego de anúncio em horário de pico,
isto acontece de verdade. E é o pior tipo de bug: intermitente, não
reproduzível localmente, e invisível até alguém somar a distribuição no fim do
mês.

**A decisão.** Eliminar a janela em vez de protegê-la. `INSERT ... ON CONFLICT
DO UPDATE ... RETURNING` é **uma** instrução: o PostgreSQL trava a linha,
incrementa e devolve o valor anterior sem ceder o controle no meio.

```sql
INSERT INTO public.rodizio_estado (id, contador) VALUES (_id, 1)
ON CONFLICT (id) DO UPDATE SET contador = rodizio_estado.contador + 1, updated_at = now()
RETURNING contador - 1;
```

Nenhuma transação explícita, nenhum `SELECT FOR UPDATE`, nenhum nível de
isolamento para configurar. A atomicidade vem da forma do comando, não de
disciplina de quem o chama.

**Detalhe do `UPSERT` em vez de só `UPDATE`.** O `INSERT` com `ON CONFLICT`
cobre o caso da linha não existir (banco novo, restauração, fila nova criada em
tempo de execução). O `VALUES (_id, 1)` com `RETURNING contador - 1` faz a
primeira chamada da vida devolver `0` também nesse caminho — as duas pernas da
instrução concordam no resultado.

---

## 3. `SECURITY DEFINER` sem `REVOKE` é um buraco aberto

**O problema.** A função precisa de `SECURITY DEFINER` para escrever numa tabela
com RLS ligada e nenhuma policy. Mas `SECURITY DEFINER` significa "roda com o
privilégio do dono, não de quem chama" — e, por padrão, **qualquer um pode
chamar.**

A chave pública (`anon`) do Supabase está no bundle do site, por definição: é
ela que faz o front-end falar com o banco. Então o ataque é trivial:

```bash
# envenenar a fila: 1000 avanços em um laço
for i in $(seq 1000); do
  curl -s -X POST "https://PROJETO.supabase.co/rest/v1/rpc/proximo_rodizio" \
    -H "apikey: CHAVE_ANON_PUBLICA" \
    -H "Content-Type: application/json" \
    -d '{"_id":"consultores"}' > /dev/null
done
```

Mil chamadas custam segundos. Com `1000 % 3 == 1`, quem souber fazer a conta
deixa o contador parado onde quiser — e **todos os leads reais seguintes vão
para o consultor escolhido pelo atacante.** Um concorrente, ou um consultor
insatisfeito, faz isso de um celular.

**A decisão.** Fechar a execução para todos e abrir só para o servidor:

```sql
REVOKE ALL ON FUNCTION public.proximo_rodizio(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.proximo_rodizio(text) TO service_role;
```

O `service_role` só existe em `process.env` no servidor. O navegador não tem
como chamar a função, nem direta nem indiretamente — a única porta é a função
de servidor, que é código nosso.

**O complemento.** `SET search_path = public` na definição. Sem isso, uma função
`SECURITY DEFINER` pode ser induzida a resolver um nome de tabela para um
schema hostil que o chamador controla — classe de vulnerabilidade conhecida em
PostgreSQL e recomendação explícita da documentação.

---

## 4. Import dinâmico como fronteira de segurança

**O problema.** Em TanStack Start, um arquivo `*.functions.ts` é compilado para
**os dois lados**: o corpo do handler fica no servidor, mas o módulo também
entra no bundle do navegador, porque é de lá que a chamada parte.

Se o cliente admin fosse importado no topo:

```ts
import { supabaseAdmin } from "@/integrations/supabase/client.server";  // ERRADO AQUI
```

o bundler criaria uma aresta estática no grafo de módulos e arrastaria
`client.server.ts` — e com ele a `SUPABASE_SERVICE_ROLE_KEY`, que ignora RLS
— para o JavaScript público do site. Vazamento total do banco, em um arquivo
que qualquer um baixa com Ctrl+U.

**A decisão.**

```ts
.handler(async () => {
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
```

O import dinâmico dentro do handler é tratado pelo bundler como fronteira: o
módulo só é resolvido em tempo de execução, no servidor.

Esta não é uma inferência — é uma regra escrita no próprio `client.server.ts`
do projeto:

> `Top-level import is safe only in other .server.ts modules — route files and *.functions.ts ship to the client bundle.`

**Por que vale documentar.** É um erro que não dá sintoma: o código funciona
perfeitamente nos dois casos. A diferença só aparece se alguém abrir o bundle e
procurar pela chave. Segurança que depende de ninguém errar a forma do import
precisa estar escrita.

---

## 5. Abrir uma aba em branco antes de saber o destino

**O problema.** Dois requisitos que se contradizem:

1. O número do consultor exige uma ida ao servidor → o código é assíncrono.
2. `window.open` só abre aba nova se chamado **dentro do gesto do usuário** →
   depois de um `await`, o gesto já expirou e o navegador bloqueia como pop-up.

O resultado da versão ingênua: o visitante clica, nada acontece, e talvez
apareça um aviso discreto de pop-up bloqueado na barra de endereço. Lead
perdido com o botão "funcionando".

**A decisão.** Separar **abrir** de **navegar**:

```ts
export function abrirWhatsappRodizio(msg = DEFAULT_WHATSAPP_MESSAGE) {
  const win = window.open("about:blank", "_blank");   // [1] síncrono, no gesto
  whatsappRoundRobinLink(msg).then((href) => {        // [2] assíncrono, depois
    if (win && !win.closed) {
      try { win.opener = null; } catch { /* no-op */ }
      win.location.href = href;                       // [3] navega a aba que já existe
    } else {
      window.location.href = href;                    // [4] plano B
    }
  });
}
```

O que precisava da permissão do gesto era **abrir** a aba, não navegá-la. Uma
aba `about:blank` por 200 ms não incomoda ninguém.

**A sutileza que sustenta isso.** A função é **síncrona** — não é `async`, não
tem `await`. É o que permite pendurá-la direto num `onClick` sem que o handler
se torne assíncrono e empurre o `window.open` para depois do gesto. Se alguém
"melhorar" o código transformando-a em `async function` e trocando o `.then`
por `await`, o pop-up volta a ser bloqueado — e o código vai parecer mais
limpo.

---

## 6. Degradar em justiça, nunca em disponibilidade

**A pergunta.** O servidor está fora do ar. O que o botão de WhatsApp faz?

**A decisão.**

```ts
try {
  const { posicao } = await avancarRodizio();
  return consultorBySlug(RODIZIO_BASE[posicao % RODIZIO_BASE.length]);
} catch {
  return proximoConsultorLocal();   // localStorage: menos justo, mas vivo
}
```

Um `catch` sem distinção de tipo de erro, deliberadamente: rede caída, função
fora do ar, banco indisponível, timeout, resposta malformada — a reação é a
mesma, e é sempre "atenda o cliente".

**O raciocínio em números.** O produto custa ~R$ 17.000. Um lead perdido
porque o botão não abriu custa uma venda. Uma hora de distribuição torta custa
no máximo alguns leads indo para o consultor errado — que continuam sendo
leads atendidos. A assimetria é de ordens de grandeza, e a arquitetura segue a
assimetria.

**O que isso implica.** O fallback local não sabe em que posição o servidor
estava. Depois de uma queda, a sequência pode repetir um consultor. Isso é
aceito, e é mensurável: a tabela `consultor_cliques` mostra o desvio
acumulado. Escolha consciente com custo conhecido, não omissão.

**Onde o `try/catch` NÃO está.** Na função de servidor (arquivo 2), o erro
**sobe**:

```ts
if (error) throw new Error(error.message);
```

Se o fallback estivesse ali dentro, o cliente nunca saberia que o servidor
falhou — o contador local seria usado silenciosamente, para sempre, e o bug
real (banco fora do ar) ficaria escondido atrás de um comportamento que parece
funcionar. Tratar erro na camada errada não é resiliência, é mascaramento.

---

## 7. Espiar não é consumir

Duas funções quase idênticas, de propósito:

| Função | Avança o contador? | Para quê |
|---|---|---|
| `peekProximoConsultor()` | não | mostrar na tela "você será atendido por..." |
| `proximoConsultor()` | sim | entregar o lead de verdade |

**O bug que isso evita.** Se a tela usasse a função que avança apenas para
exibir um nome, **cada renderização queimaria uma posição da fila** — incluindo
renderizações de robôs de busca, pré-carregamentos do navegador e re-renders do
React. E o consultor exibido não seria o que receberia o lead, porque o clique
avançaria outra vez.

**Por que duas funções e não um parâmetro.** `proximoConsultor(avancar = false)`
é onde alguém, seis meses depois, chama sem o argumento e desalinha o rodízio
inteiro sem nenhum sintoma visível. Dois nomes distintos tornam a intenção
explícita no ponto de uso — quem lê `peek` sabe que está só olhando.

---

## 8. O lead que se perde sem ninguém ver

**O problema.** Um link `wa.me/` com número inválido **não dá erro**. O
WhatsApp abre numa tela de "número de telefone inválido". O visitante fecha e
vai embora. E o site registra um clique bem-sucedido.

É a pior classe de bug que existe: a métrica diz que deu certo.

**A decisão.**

```ts
function cleanWhatsappNumber(number: string) {
  const cleaned = number.replace(/\D/g, "");
  return cleaned.length >= 10 ? cleaned : WHATSAPP_INSTITUCIONAL;
}
```

Dois passos. Primeiro tira tudo que não é dígito — porque a mesma base de
dados guarda `"+55 11 90000-0001"` para exibir e o parêntese/hífen/espaço não
pode entrar na URL. Depois valida o tamanho mínimo e, se não passar, usa o
número institucional.

**O princípio.** Mandar o lead para o número errado da empresa é ruim; mandar
para o limbo é pior. Entre falhar visivelmente (alguém recebe uma conversa que
não era dele e avisa) e falhar invisivelmente (ninguém recebe nada), escolhe-se
a primeira sempre.

**O mesmo cuidado na mensagem.** `encodeURIComponent(msg)` não é opcional: as
mensagens são montadas em tempo real com dados de formulário, e carregam `&`,
`:` e acentos. Sem o encode, o texto chega cortado no primeiro `&` e o
consultor recebe meia frase — perdendo o contexto do lead que o site acabou de
coletar.

**E os dois campos separados.** `whatsappNumber` (só dígitos, com DDI) e
`whatsappDisplay` (formatado para humano) existem como colunas distintas em vez
de uma ser derivada da outra na hora de renderizar. Derivação na view é onde
nasce o link quebrado: alguém esquece o DDI, ou deixa a máscara passar.

---

## 9. Um listener na captura, não um `onClick` por botão

**O problema.** O site tem CTA de WhatsApp em dezenas de lugares: hero, menu de
navegação, menu mobile, rodapé, cartão de cada máquina, página de showroom,
telas de sucesso de quatro formulários diferentes, botão flutuante. Instrumentar
cada um é garantia de esquecer alguns — e os esquecidos não dão erro, só não
aparecem no relatório.

**A decisão.** Um único listener delegado, instalado na raiz:

```ts
document.addEventListener("click", registrar, true);
//                                           ^^^^ fase de captura
```

**Por que a fase de captura e não a bolha.** A captura desce do `document` até o
alvo **antes** de a bolha subir. Na bolha, qualquer componente no caminho pode
sumir com o evento chamando `stopPropagation()` — o que bibliotecas de menu,
dropdown e diálogo (Radix, shadcn) fazem com frequência, legitimamente.
Medição não pode depender do comportamento interno de um componente de
terceiro.

**Por que `closest("a,button")`.** O clique quase nunca cai no `<a>` ou no
`<button>`: cai no `<svg>` do ícone, no `<span>` do texto, no `<path>` dentro
do svg. Sem subir a árvore, o rastreamento perderia a maioria dos cliques — e
perderia de forma **enviesada**, contando só os que caem na borda do botão.

**Por que quatro sinais de detecção.** Os CTAs não são uniformes:

| Forma do CTA | Como é reconhecido |
|---|---|
| `<a href="https://wa.me/...">` | regex no `href` |
| `<button onClick={abrirWhatsappRodizio}>` | `data-whatsapp-cta` — **não tem href** |
| botão só com ícone | filho com `[data-whatsapp-icon]` |
| CTA acessível | `aria-label` contendo "whatsapp" |

A segunda linha é a que obriga a ter mais de um sinal: num rodízio, **o `href`
não existe no momento do clique**. Um rastreador que só olhasse `href` mediria
zero justamente nos botões mais importantes do site.

**E o cleanup.** A função devolve o desfazedor, e é chamada via
`useEffect(instalarRastreamentoWhatsapp, [])`. Sem o cleanup, cada remontagem
empilharia um listener novo — dobrando, triplicando a contagem de cada clique,
e inflando a conversão reportada ao Google Ads.

---

## 10. O evento de conversão que nunca chegava ao Google

Este não é um risco hipotético: foi um bug em produção, corrigido em commit
próprio ("Corrige rastreamento de clique no WhatsApp: formato errado nunca
chegava ao Google"). O comentário ficou no código.

**O erro.**

```ts
window.dataLayer.push({ event: "whatsapp_click", ... });   // ERRADO neste site
```

**Por que é errado aqui.** `dataLayer.push({event: ...})` é a convenção do
**Google Tag Manager** — um container que escuta o array e processa os eventos.
Este site não carrega o GTM; carrega o `gtag.js` direto. Sem container, os
objetos ficam empilhados num array que ninguém lê.

**Por que é difícil de pegar.** Nada falha. O array recebe o objeto, nenhum erro
aparece no console, o clique funciona, a aba abre, o visitante conversa com o
consultor. Só a conversão não existe — e a campanha de anúncio otimiza no
escuro por semanas, gastando orçamento sem saber quais criativos geram
conversa, até alguém conferir o relatório e perceber o zero.

**A correção.**

```ts
if (browser.gtag) {
  browser.gtag("event", "whatsapp_click", params);
} else {
  browser.dataLayer ??= [];
  function gtag(..._args: unknown[]) { browser.dataLayer?.push(arguments); }
  gtag("event", "whatsapp_click", params);
}
```

O `else` cobre o clique nos primeiros milissegundos, antes de o `gtag.js`
carregar. E note que ele empilha `arguments` — o objeto de argumentos — e não
um objeto literal: essa é a assinatura que o `gtag.js` reprocessa quando
carrega. É a mesma fila, no formato certo.

**A lição que generaliza.** Instrumentação é a única parte do sistema que falha
sem sintoma. Todo o resto grita quando quebra: a tela fica branca, o formulário
não envia, o botão não abre. Medição errada apenas... mede errado. Por isso o
formato do evento merece um comentário no código explicando por que é aquele,
e não o outro que parece equivalente.

---

## Auditoria: por que o rodízio registra a si mesmo

Dizer "distribuo 1:1:1" sem medir é promessa, não engenharia. Toda posição
entregue vai para `consultor_cliques`, e o lead guarda o dono dentro de si
(`consultor`, `email_vendedor`).

Isso resolve três problemas de uma vez:

1. **Prova.** `SELECT consultor, count(*) ... GROUP BY consultor` mostra a
   distribuição real. Com o mecanismo funcionando, a diferença entre o maior e
   o menor nunca passa de 1.
2. **Detecção.** Se o desvio crescer, algo aconteceu: fallback local usado numa
   queda, consultor adicionado no meio do caminho, ou chamada fora do fluxo.
   O número aparece antes da reclamação.
3. **Arbitragem.** Discussão de consultor sobre quem recebeu mais lead no mês
   se resolve com uma consulta, não com opinião.

Um detalhe de permissão que vale notar — as duas tabelas deste sistema têm RLS
ligada, e políticas **opostas**:

| Tabela | Policy | Por quê |
|---|---|---|
| `rodizio_estado` | nenhuma (deny all) | é **estado de decisão**: se o visitante pudesse escrever, ele escolheria o próprio consultor |
| `consultor_cliques` | `INSERT` para `anon` | é **registro de fato consumado**: inserir não muda decisão nenhuma, e precisa vir do navegador porque é lá que o clique acontece |

A tabela de auditoria é *append-only* para o visitante: pode inserir, não pode
ler (`REVOKE SELECT ... FROM anon`), não pode alterar nem apagar
(`REVOKE UPDATE, DELETE`). Ler a auditoria é privilégio de admin
(`USING (public.has_role(auth.uid(), 'admin'))`).

A pergunta aplicada nos dois casos foi a mesma — *"o que o pior visitante
possível consegue fazer com esse privilégio?"* — e as respostas diferentes
geraram grants diferentes.

---

## O que eu mudaria

Limitações conhecidas, em ordem de prioridade. Nenhuma delas está escondida no
código.

### 1. A lista de consultores deveria vir do banco

Hoje `RODIZIO_BASE` é um array em TypeScript. O banco **já tem** a tabela
`consultores` com as colunas `ordem` e `ativo` — mas o rodízio ainda não a lê.
Consequência prática: ativar ou desativar um consultor (férias, desligamento,
contratação) exige deploy.

O caminho é ler a tabela filtrando por `ativo = true` e ordenando por `ordem`,
com cache curto para não pagar um round-trip a mais. O `%` continua
funcionando: o tamanho da fila passa a ser dinâmico.

### 2. O `as any` sobrou

```ts
await (supabaseAdmin as any).rpc("proximo_rodizio", { _id: "consultores" });
```

Resto de quando a função SQL era nova e os tipos gerados não a conheciam. Hoje
`src/integrations/supabase/types.ts` já declara
`proximo_rodizio: { Args: { _id: string }; Returns: number }` — o cast não é
mais necessário e está jogando fora a tipagem do retorno, que é justamente o
que o `Number(data ?? 0)` logo abaixo tenta recuperar à mão.

### 3. O fallback local não sabe onde o servidor parou

Depois de uma queda, a sequência local pode repetir um consultor. Aceito
(decisão 6), mas melhorável: o servidor poderia devolver a posição junto com
um timestamp, e o cliente guardaria a última posição conhecida para continuar
de lá em vez de do zero.

### 4. Não há rodízio ponderado

Hoje é estritamente 1:1:1. Um consultor novo, em treinamento, deveria receber
menos. A estrutura já suporta sem mudança de código — basta repetir slugs em
`RODIZIO_BASE` (`[A, B, A, C]` dá 50% para A) — mas isso é configuração por
array, não por peso declarado, e não escala para proporções finas.

### 5. Não há consciência de horário nem de disponibilidade

O rodízio entrega para o próximo da fila mesmo que ele esteja de folga, fora do
horário comercial ou com a caixa cheia. Um lead que cai no domingo de manhã no
WhatsApp de quem só volta na terça é um lead frio. A evolução natural é uma
janela de disponibilidade por consultor, com o rodízio pulando quem está fora
— o que transforma o `%` simples em uma busca pelo próximo elegível.

### 6. O contador nunca reseta

`bigint` cobre ~9,2 × 10¹⁸ incrementos. Não é um problema prático, mas vale
registrar que é uma escolha (contador monotônico) e não um descuido: resetar
introduziria uma janela de race condition exatamente do tipo que a decisão 2
eliminou.
