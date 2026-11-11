# Como implementar do zero

Seis passos. Ao fim, todo clique em "falar com um consultor" cai no WhatsApp do
próximo da fila, a distribuição é verificável e a conversão chega ao Google Ads.

Pré-requisitos: um banco PostgreSQL (ou equivalente — ver
[adaptando para outra stack](#adaptando-para-outra-stack)) e um lugar para
rodar código no servidor (função SSR, rota de API, serverless).

---

## Passo 1 — Criar o contador no banco

```sql
CREATE TABLE public.rodizio_estado (
  id         text        PRIMARY KEY,
  contador   bigint      NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.rodizio_estado ENABLE ROW LEVEL SECURITY;  -- Supabase/PostgREST
GRANT ALL ON public.rodizio_estado TO service_role;

INSERT INTO public.rodizio_estado (id, contador) VALUES ('consultores', 0);

CREATE OR REPLACE FUNCTION public.proximo_rodizio(_id text)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO public.rodizio_estado (id, contador) VALUES (_id, 1)
  ON CONFLICT (id) DO UPDATE SET contador = rodizio_estado.contador + 1, updated_at = now()
  RETURNING contador - 1;
$$;

REVOKE ALL ON FUNCTION public.proximo_rodizio(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.proximo_rodizio(text) TO service_role;
```

> **Não pule o `REVOKE`.** Sem ele, qualquer visitante chama a função com a
> chave pública e envenena a fila. Ver
> [DECISOES-DE-ENGENHARIA.md, decisão 3](DECISOES-DE-ENGENHARIA.md#3-security-definer-sem-revoke-é-um-buraco-aberto).

**Teste antes de seguir.** Rode três vezes seguidas, como `service_role`:

```sql
SELECT public.proximo_rodizio('consultores');  -- 0
SELECT public.proximo_rodizio('consultores');  -- 1
SELECT public.proximo_rodizio('consultores');  -- 2
```

Se a primeira não devolver `0`, o `RETURNING contador - 1` ou o `VALUES (_id, 1)`
está diferente do acima.

E confirme que o trinco fechou — esta chamada, com a chave **pública**, tem que
falhar com erro de permissão:

```bash
curl -s -X POST "https://PROJETO.supabase.co/rest/v1/rpc/proximo_rodizio" \
  -H "apikey: SUA_CHAVE_ANON_PUBLICA" \
  -H "Content-Type: application/json" \
  -d '{"_id":"consultores"}'
# esperado: {"code":"42501","message":"permission denied for function proximo_rodizio"}
```

Se isso devolver um número, o `REVOKE` não pegou. Pare e corrija.

---

## Passo 2 — Expor uma função de servidor

```ts
// src/lib/rodizio.functions.ts
import { createServerFn } from "@tanstack/react-start";

export const avancarRodizio = createServerFn({ method: "POST" }).handler(async () => {
  // import DINÂMICO: mantém a chave de serviço fora do bundle do navegador
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");
  const { data, error } = await supabaseAdmin.rpc("proximo_rodizio", { _id: "consultores" });
  if (error) throw new Error(error.message);
  return { posicao: Number(data ?? 0) };
});
```

**Em Next.js (App Router)**, o equivalente é uma Server Action:

```ts
"use server";
export async function avancarRodizio() {
  const { supabaseAdmin } = await import("@/lib/supabase-admin");
  const { data, error } = await supabaseAdmin.rpc("proximo_rodizio", { _id: "consultores" });
  if (error) throw new Error(error.message);
  return { posicao: Number(data ?? 0) };
}
```

**Em qualquer framework com rota de API**, é um `POST /api/rodizio` que devolve
`{ posicao: n }`. O importante é que a chave de serviço **nunca** apareça no
código enviado ao navegador — confira abrindo o bundle e buscando pelo prefixo
da chave.

---

## Passo 3 — Cadastrar o elenco e a ordem

```ts
// src/data/consultores.ts
export const CONSULTORES = [
  { slug: "ana",   nome: "Ana",   email: "ana@empresa.com.br",   whatsappNumber: "5511900000001", whatsappDisplay: "+55 11 90000-0001" },
  { slug: "bruno", nome: "Bruno", email: "bruno@empresa.com.br", whatsappNumber: "5511900000002", whatsappDisplay: "+55 11 90000-0002" },
  { slug: "clara", nome: "Clara", email: "clara@empresa.com.br", whatsappNumber: "5511900000003", whatsappDisplay: "+55 11 90000-0003" },
];

// A ORDEM da fila, separada da LISTA de pessoas.
// Para rodízio ponderado, repita o slug: ["ana","bruno","ana","clara"] → 50% Ana.
export const RODIZIO_BASE = ["ana", "bruno", "clara"];
```

Dois campos para o telefone (`whatsappNumber` só com dígitos e DDI,
`whatsappDisplay` formatado) em vez de derivar um do outro na renderização —
ver [decisão 8](DECISOES-DE-ENGENHARIA.md#8-o-lead-que-se-perde-sem-ninguém-ver).

---

## Passo 4 — A escolha, com fallback

```ts
const RODIZIO_KEY = "rodizio_consultor_idx";

function consultorBySlug(slug: string) {
  return CONSULTORES.find((c) => c.slug === slug) ?? CONSULTORES[0];
}

function proximoConsultorLocal() {
  let slug = RODIZIO_BASE[0];
  try {
    if (typeof window !== "undefined") {
      const atual = Number(localStorage.getItem(RODIZIO_KEY) ?? "0") % RODIZIO_BASE.length;
      slug = RODIZIO_BASE[atual];
      localStorage.setItem(RODIZIO_KEY, String((atual + 1) % RODIZIO_BASE.length));
    }
  } catch { /* modo privado, armazenamento bloqueado */ }
  return consultorBySlug(slug);
}

export async function proximoConsultor() {
  try {
    const { avancarRodizio } = await import("@/lib/rodizio.functions");
    const { posicao } = await avancarRodizio();
    return consultorBySlug(RODIZIO_BASE[posicao % RODIZIO_BASE.length]);
  } catch {
    return proximoConsultorLocal();   // degrada em justiça, não em disponibilidade
  }
}

/** Espia sem avançar — para a tela MOSTRAR o nome sem queimar uma posição. */
export function peekProximoConsultor() {
  try {
    if (typeof window !== "undefined") {
      const atual = Number(localStorage.getItem(RODIZIO_KEY) ?? "0") % RODIZIO_BASE.length;
      return consultorBySlug(RODIZIO_BASE[atual]);
    }
  } catch { /* no-op */ }
  return consultorBySlug(RODIZIO_BASE[0]);
}
```

O `typeof window !== "undefined"` é obrigatório se o arquivo for importado em
rota com SSR: `localStorage` não existe no servidor.

---

## Passo 5 — O link e a abertura da aba

```ts
const WHATSAPP_INSTITUCIONAL = "5511900000000";

function cleanWhatsappNumber(number: string) {
  const cleaned = number.replace(/\D/g, "");
  return cleaned.length >= 10 ? cleaned : WHATSAPP_INSTITUCIONAL;
}

export function whatsappExternalLink(msg: string, number: string) {
  return `https://wa.me/${cleanWhatsappNumber(number)}?text=${encodeURIComponent(msg)}`;
}

/** SÍNCRONA de propósito — não transforme em async. Ver abaixo. */
export function abrirWhatsappRodizio(msg = "Olá, vi o site e gostaria de mais informações.") {
  const win = window.open("about:blank", "_blank");          // [1] dentro do gesto
  proximoConsultor()
    .then((c) => whatsappExternalLink(msg, c.whatsappNumber))
    .then((href) => {
      if (win && !win.closed) {
        try { win.opener = null; } catch { /* no-op */ }      // [2] anti-tabnabbing
        win.location.href = href;
      } else {
        window.location.href = href;                          // [3] plano B
      }
    });
}
```

> ⚠️ **A armadilha.** Transformar `abrirWhatsappRodizio` em `async` e trocar o
> `.then` por `await` deixa o código mais bonito e **quebra o botão**: o
> `window.open` passa a rodar fora do gesto do usuário e o navegador bloqueia
> como pop-up. Ver
> [decisão 5](DECISOES-DE-ENGENHARIA.md#5-abrir-uma-aba-em-branco-antes-de-saber-o-destino).

Uso no componente — handler síncrono:

```tsx
<button data-whatsapp-cta="hero" onClick={() => abrirWhatsappRodizio()}>
  Falar com um consultor
</button>
```

**Como testar o pop-up de verdade:** no Chrome, bloqueie pop-ups para o domínio
(ícone do cadeado → Configurações do site → Pop-ups: Bloquear) e clique. Deve
navegar na própria aba, nunca ficar parado. Teste também no Safari iOS, que é o
mais restritivo.

---

## Passo 6 — Atribuição e auditoria

Sem isto, "o rodízio é justo" é afirmação sem prova.

```sql
CREATE TABLE public.consultor_cliques (
  id         uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  consultor  text NOT NULL,
  origem     text,
  canal      text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.consultor_cliques ENABLE ROW LEVEL SECURITY;

-- append-only para o visitante: insere, não lê, não altera, não apaga
GRANT INSERT ON public.consultor_cliques TO anon, authenticated;
GRANT SELECT ON public.consultor_cliques TO authenticated;
REVOKE UPDATE, DELETE ON public.consultor_cliques FROM authenticated;

CREATE POLICY "public submit" ON public.consultor_cliques
  FOR INSERT TO anon, authenticated WITH CHECK (true);

CREATE POLICY "admins read" ON public.consultor_cliques
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
```

Em formulários, resolva o consultor **antes** do insert e grave o dono dentro do
lead:

```ts
const consultor = await proximoConsultor();          // 1. dono primeiro

await supabase.from("leads").insert({
  /* ...campos do formulário... */
  consultor: consultor.nome,
  email_vendedor: consultor.email || null,           // null, não ""
});

void supabase.from("consultor_cliques").insert({      // 2. void: não espera
  consultor: consultor.nome,
  origem: "formulario-contato",
  canal: "formulario",
});
```

Verificação contínua:

```sql
SELECT consultor, count(*) FROM consultor_cliques GROUP BY consultor ORDER BY 2 DESC;
```

Com o mecanismo funcionando, a diferença entre o maior e o menor nunca passa de 1.

---

## Opcional — Medir os cliques

Copie [codigo/04-whatsapp-tracking.ts](../codigo/04-whatsapp-tracking.ts) e
instale uma vez na raiz:

```tsx
useEffect(instalarRastreamentoWhatsapp, []);
```

Marque os botões sem `href` com `data-whatsapp-cta="origem"` — é o que permite
ao rastreador reconhecê-los, já que o destino de um botão de rodízio só existe
depois da ida ao servidor.

Se o seu site usa **Google Tag Manager**, troque `gtag('event', ...)` por
`dataLayer.push({event: ...})`. Se usa **gtag.js direto** (sem GTM), mantenha
`gtag('event', ...)`. Usar o formato errado não gera erro nenhum — só faz a
conversão nunca aparecer. Ver
[decisão 10](DECISOES-DE-ENGENHARIA.md#10-o-evento-de-conversão-que-nunca-chegava-ao-google).

---

## Adaptando para outra stack

O mecanismo precisa de **uma** coisa: um contador compartilhado com incremento
atômico que devolva o valor anterior. Todo o resto é acessório.

### Redis

```ts
const posicao = (await redis.incr("rodizio:consultores")) - 1;
```

`INCR` é atômico por natureza e já devolve o valor novo. A opção mais simples
de todas — o custo é um serviço a mais para operar, e a persistência depende da
configuração do Redis (um reset de cache zera a fila, o que na prática só
desalinha a justiça por um ciclo).

### MySQL 8+

```sql
CREATE TABLE rodizio_estado (
  id VARCHAR(64) PRIMARY KEY,
  contador BIGINT NOT NULL DEFAULT 0
);

-- MySQL não tem RETURNING; usa-se LAST_INSERT_ID como carona
INSERT INTO rodizio_estado (id, contador) VALUES ('consultores', 1)
ON DUPLICATE KEY UPDATE contador = LAST_INSERT_ID(contador + 1);
SELECT LAST_INSERT_ID() - 1 AS posicao;
```

As duas instruções são seguras juntas porque `LAST_INSERT_ID()` é **por
conexão** — outra sessão incrementando no meio não contamina o valor lido.

### PostgreSQL puro, sem Supabase

Use o mesmo SQL do passo 1, sem as linhas de RLS e sem os grants para
`anon`/`service_role` (que são papéis específicos do Supabase). Chame com um
usuário de aplicação que tenha `EXECUTE` na função e **nenhum** privilégio
direto na tabela — o `SECURITY DEFINER` cobre a escrita.

### Uma sequence do PostgreSQL

```sql
CREATE SEQUENCE rodizio_consultores;
SELECT nextval('rodizio_consultores') - 1;
```

Mais enxuto, e atômico. Duas ressalvas: sequences podem ter *gaps* (um `nextval`
em transação abortada queima o número — o que desalinha a justiça em um
passo), e não há onde guardar `updated_at` nem metadados da fila.

### Sem backend nenhum

Não dá. Qualquer coisa que rode só no navegador tem o problema da
[decisão 1](DECISOES-DE-ENGENHARIA.md#1-por-que-o-contador-não-pode-morar-no-navegador):
visitante novo começa do zero, e visitante novo é a maioria do tráfego.

Se realmente não houver backend, a alternativa honesta é `Math.random()` —
aceitando que, em volume baixo, o desvio será grande. Não chame isso de
rodízio.

---

## Checklist de produção

- [ ] A chamada direta à função com a chave **pública** falha com `42501`
- [ ] Três chamadas consecutivas devolvem `0, 1, 2`
- [ ] A chave de serviço **não** aparece no bundle do navegador
      (abra o JS publicado e busque o prefixo da chave)
- [ ] Com pop-ups bloqueados, o botão navega na própria aba
- [ ] Com a rede desligada (DevTools → Offline), o botão ainda abre o WhatsApp
- [ ] O link abre a conversa certa, com a mensagem **inteira** e acentuada
- [ ] Clicar 9 vezes distribui 3/3/3 em `consultor_cliques`
- [ ] A tela que mostra o nome do consultor usa `peek`, não `proximoConsultor`
- [ ] O evento `whatsapp_click` aparece no tempo real do Google Analytics
- [ ] Remontar o componente não duplica o evento de clique
