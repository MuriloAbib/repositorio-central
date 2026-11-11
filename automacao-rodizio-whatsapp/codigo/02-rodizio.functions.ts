// =============================================================================
// 2/5 — A FUNÇÃO DE SERVIDOR QUE AVANÇA A FILA
// =============================================================================
// Arquivo original no projeto: src/lib/rodizio.functions.ts
//
// São 9 linhas. O que importa aqui não é o que o código faz — é onde ele RODA
// e o que ele deliberadamente não faz.
// =============================================================================

import { createServerFn } from "@tanstack/react-start";

/** Avança o contador global do rodízio (único para todos os visitantes) e devolve a posição. */
export const avancarRodizio = createServerFn({ method: "POST" }).handler(async () => {
  // ---------------------------------------------------------------------------
  // POR QUE `await import()` AQUI DENTRO, E NÃO UM IMPORT NO TOPO DO ARQUIVO
  // ---------------------------------------------------------------------------
  // `client.server.ts` lê SUPABASE_SERVICE_ROLE_KEY de process.env. Essa chave
  // ignora RLS: quem a tem, tem o banco inteiro.
  //
  // O arquivo em que você está (`*.functions.ts`) é compilado para OS DOIS
  // lados: o handler fica no servidor, mas o módulo também vai para o bundle do
  // navegador, porque é de lá que a chamada parte. Um `import` no topo viraria
  // uma aresta estática no grafo do bundler e arrastaria o client.server.ts —
  // e a chave — para dentro do JavaScript público.
  //
  // O import dinâmico dentro do handler quebra essa aresta: o bundler trata
  // como fronteira, e o módulo só é resolvido em tempo de execução, no servidor.
  //
  // Isto não é zelo teórico: é uma regra escrita no próprio client.server.ts
  // ("Top-level import is safe only in other .server.ts modules — route files
  // and *.functions.ts ship to the client bundle").
  const { supabaseAdmin } = await import("@/integrations/supabase/client.server");

  // Uma chamada RPC, uma instrução SQL, uma posição de volta.
  // `_id: "consultores"` nomeia QUAL fila avançar.
  const { data, error } = await (supabaseAdmin as any).rpc("proximo_rodizio", { _id: "consultores" });

  // Erro sobe. Quem trata é o chamador, que tem um plano B (ver arquivo 3).
  // Esta função não tem opinião sobre fallback: ela sabe falar com o banco, e
  // é só isso. Misturar o plano B aqui esconderia a falha do servidor — o
  // contador local seria usado sem ninguém nunca saber que o servidor caiu.
  if (error) throw new Error(error.message);

  // `?? 0` porque um RETURNING vazio (linha some, banco recém-restaurado) não
  // pode virar NaN e quebrar o `% 3` do outro lado. Na dúvida, o primeiro
  // consultor atende — ninguém fica sem resposta.
  return { posicao: Number(data ?? 0) };
});

// -----------------------------------------------------------------------------
// NOTA DE DÍVIDA TÉCNICA (honestidade > vitrine)
// -----------------------------------------------------------------------------
// O `as any` no `supabaseAdmin` é resto de quando a função SQL era nova e os
// tipos gerados do Supabase ainda não a conheciam. Hoje
// `src/integrations/supabase/types.ts` já declara:
//
//     proximo_rodizio: { Args: { _id: string }; Returns: number }
//
// ou seja, o cast não é mais necessário e está mascarando a tipagem do retorno.
// A limpeza correta é remover o `as any` e deixar `data` vir como `number`.
// Está catalogado em docs/DECISOES-DE-ENGENHARIA.md, seção "O que eu mudaria".
