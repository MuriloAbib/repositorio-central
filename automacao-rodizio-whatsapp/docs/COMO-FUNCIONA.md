# Como funciona: o caminho de um clique

Este documento segue **um** clique, do dedo do visitante até a conversa aberta
no WhatsApp do consultor. Oito passos, em quatro camadas.

---

## O trajeto completo

```
NAVEGADOR                      SERVIDOR (Netlify)           POSTGRESQL
─────────                      ──────────────────           ──────────

[1] clique no botão
    │
[2] window.open("about:blank")
    │  (aba vazia já abriu)
    │
[3] proximoConsultor() ─────────> [4] avancarRodizio()
                                      │  await import(admin)
                                      │
                                      └──> [5] rpc proximo_rodizio
                                               │
                                               │  INSERT..ON CONFLICT
                                               │  ..RETURNING contador-1
                                               │
                                      [6] <────┘  posicao: 7
    │                                  │
    │ <────── { posicao: 7 } ──────────┘
    │
[7] RODIZIO_BASE[7 % 3] = RODIZIO_BASE[1] = "consultor-a"
    │   whatsappExternalLink(msg, "5511900000001")
    │
[8] win.opener = null
    win.location.href = "https://wa.me/5511900000001?text=Ol%C3%A1..."
    │
    v
    WhatsApp abre a conversa com o consultor da vez
```

---

## Passo a passo

### [1] O clique

O botão é um `<button>`, não um `<a>`. Não poderia ser um link: **o destino
ainda não existe** no momento em que a página é renderizada. Qual consultor vai
atender só se sabe depois de consultar o servidor, e isso só pode acontecer
quando o visitante clica — se acontecesse no carregamento da página, cada
visita queimaria uma posição da fila, inclusive as visitas de robôs de busca.

```tsx
<button data-whatsapp-cta="contato" onClick={abrirWhatsappDireto}>
  Clique e fale com um consultor
</button>
```

O `data-whatsapp-cta` serve a dois propósitos: marca o botão para o rastreador
(que não tem `href` para reconhecer) e nomeia a origem do clique.

### [2] A aba vazia abre antes de tudo

```ts
const win = window.open("about:blank", "_blank");
```

Esta é a primeira linha executada, e a ordem é obrigatória. O navegador só
autoriza `window.open` **dentro do gesto do usuário** — a janela de permissão
dura o tique do clique e fecha. Como o passo [3] é assíncrono, qualquer
`window.open` depois dele seria tratado como pop-up não solicitado e bloqueado.

A saída é separar **abrir** de **navegar**: abre-se agora, sem destino; navega-se
depois, quando o destino chegar. Uma aba `about:blank` não incomoda ninguém por
200 ms.

### [3] A chamada ao rodízio

```ts
const { avancarRodizio } = await import("@/lib/rodizio.functions");
const { posicao } = await avancarRodizio();
```

Isto roda no navegador, mas `avancarRodizio` é uma **função de servidor**: o
TanStack Start transforma a chamada em um POST para o próprio site, e o corpo
da função nunca existe no bundle do cliente.

Está dentro de um `try`. O `catch` cai no contador local (passo [3b]).

### [4] A fronteira de segurança

```ts
export const avancarRodizio = createServerFn({ method: "POST" }).handler(async () => {
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
```

Aqui já estamos no servidor. O `await import()` **dentro** do handler, e não no
topo do arquivo, é o que impede o bundler de arrastar a chave de serviço
(`SUPABASE_SERVICE_ROLE_KEY`) para dentro do JavaScript público — porque este
arquivo, sendo um `*.functions.ts`, é compilado para os dois lados.

### [5] A instrução atômica

```sql
INSERT INTO public.rodizio_estado (id, contador) VALUES (_id, 1)
ON CONFLICT (id) DO UPDATE SET contador = rodizio_estado.contador + 1, updated_at = now()
RETURNING contador - 1;
```

Uma linha da tabela, um comando, três efeitos: trava a linha, incrementa o
contador e devolve o valor **anterior**. Dez cliques simultâneos recebem dez
posições distintas, porque o PostgreSQL serializa o acesso à linha dentro da
própria instrução.

O `RETURNING contador - 1` existe para que a posição já venha como índice de
array base-zero: o primeiro chamador da vida recebe `0`.

### [6] A posição volta

```json
{ "posicao": 7 }
```

Um número. Não o nome do consultor, não o telefone — **o servidor não conhece
os consultores**. Essa divisão é intencional: a fila é infraestrutura (um
contador), o elenco é configuração (um array no front-end). Trocar a ordem dos
consultores ou adicionar um quarto não exige migração de banco nem deploy de
função de servidor.

### [7] De contador infinito a consultor

```ts
return consultorBySlug(RODIZIO_BASE[posicao % RODIZIO_BASE.length]);
```

O resto da divisão faz o contador monotônico (que nunca reseta e chega a
milhões) virar um índice válido. Com `RODIZIO_BASE = [B, A, C]`:

| posicao | `% 3` | consultor |
|---|---|---|
| 0 | 0 | Consultor B |
| 1 | 1 | Consultor A |
| 2 | 2 | Consultor C |
| 3 | 0 | Consultor B |
| 7 | 1 | Consultor A |

Em seguida, `whatsappExternalLink` monta a URL — passando o número por
`cleanWhatsappNumber` (tira máscara, valida tamanho) e a mensagem por
`encodeURIComponent` (sem isso, o texto quebra no primeiro `&`).

### [8] A navegação

```ts
try { win.opener = null; } catch { /* no-op */ }
win.location.href = href;
```

`win.opener = null` antes de navegar: corta a referência que a página de
destino teria para a nossa aba. Sem isso, a página aberta pode reescrever a
aba de origem — o ataque conhecido como *tabnabbing*. É o equivalente
programático do `rel="noopener"`.

Se a aba não existir (bloqueador agressivo, ou o visitante a fechou), navega-se
na própria aba: `window.location.href = href`. Perde-se o site, não se perde o
lead.

---

## Os desvios do caminho principal

### [3b] Servidor indisponível → contador local

```ts
} catch {
  return proximoConsultorLocal();
}
```

Rede caída, função fora do ar, timeout do banco: a reação é sempre a mesma, e é
sempre "atenda o cliente". O contador local (`localStorage`) é menos justo —
começa em zero para cada navegador — mas mantém o botão funcionando.

Durante uma queda, portanto, o rodízio **degrada em justiça, não em
disponibilidade.** A escolha é deliberada: o prejuízo de uma distribuição
torta por uma hora é menor que o de um botão de WhatsApp morto em um site de
produto de R$ 17 mil.

### Fluxo alternativo: formulário em vez de botão

Quando o lead vem de formulário (pesquisa de máquina, download de catálogo,
SAC, proposta), o rodízio é resolvido **antes** do insert, porque o consultor é
coluna do próprio lead:

```ts
const consultor = await proximoConsultor();     // 1. resolve o dono
await supabase.from("leads_pesquisa").insert({  // 2. grava o lead COM o dono
  /* ...dados do formulário... */
  consultor: consultor.nome,
  email_vendedor: consultor.email || null,
});
void supabase.from("consultor_cliques").insert({ // 3. audita, sem esperar
  consultor: consultor.nome,
  origem: `pesquisa-${maquinaSlug}`,
  canal: "formulario",
});
```

A ordem evita a janela em que um lead existe sem dono. E o `void` no insert de
auditoria é proposital: estatística não pode adicionar latência ao caminho do
cliente.

Só **depois** disso a tela de sucesso mostra o nome do consultor — recebido por
prop, nunca resolvido de novo. Chamar `proximoConsultor()` na tela de sucesso
avançaria o contador uma segunda vez pelo mesmo lead e poderia exibir um nome
diferente do que foi gravado no banco.

---

## E a medição?

Em paralelo a tudo isso, um único listener instalado na raiz do site
(`useEffect(instalarRastreamentoWhatsapp, [])`) escuta **todo** clique do
documento na fase de captura, reconhece os CTAs de WhatsApp por quatro sinais
diferentes e dispara `gtag('event', 'whatsapp_click', {...})`.

Ele é independente do rodízio de propósito: funciona para links `wa.me`
estáticos, para botões de rodízio sem `href`, e para qualquer CTA novo que
alguém adicione amanhã sem lembrar de instrumentar.

Detalhes e o bug que esse arquivo documenta:
[codigo/04-whatsapp-tracking.ts](../codigo/04-whatsapp-tracking.ts).

---

## Como verificar que o rodízio está justo

A pergunta certa não é "o código parece correto?", é "a distribuição está 1:1:1
em produção?". Duas consultas respondem:

```sql
-- Distribuição de verdade, por consultor
SELECT consultor, count(*) AS cliques
FROM consultor_cliques
GROUP BY consultor
ORDER BY cliques DESC;

-- Estado atual da fila
SELECT id, contador, updated_at FROM rodizio_estado WHERE id = 'consultores';
```

Com rodízio funcionando, a diferença entre o maior e o menor nunca passa de 1
no total acumulado. Diferença maior significa uma de três coisas: alguém chamou
a função fora do fluxo, o fallback local foi usado durante uma queda, ou um
consultor foi adicionado/removido no meio do caminho.

No projeto original isso está exposto na aba **"Cliques por consultor"** do
painel administrativo — a verificação roda em produção, não só em teste.
