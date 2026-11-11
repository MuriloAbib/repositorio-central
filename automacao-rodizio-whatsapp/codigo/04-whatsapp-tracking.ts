// =============================================================================
// 4/5 — RASTREAMENTO DO CLIQUE: UM LISTENER PARA DEZENAS DE BOTÕES
// =============================================================================
// Arquivo original no projeto: src/lib/whatsapp-tracking.ts
//
// O rodízio distribui; isto MEDE. Sem esta peça não há como saber quantos
// cliques de WhatsApp o site gerou, de qual página, e a conversão não chega
// ao Google Ads — o que significa pagar anúncio sem saber o que ele devolve.
// =============================================================================

type AnalyticsWindow = Window & { gtag?: (...args: unknown[]) => void; dataLayer?: unknown[] };

export function instalarRastreamentoWhatsapp() {
  const registrar = (event: MouseEvent) => {
    const target = event.target;
    if (!(target instanceof Element)) return;

    // -------------------------------------------------------------------------
    // Por que `closest`, e não `event.target` direto.
    // -------------------------------------------------------------------------
    // O clique quase nunca cai no <a> ou no <button>: cai no <svg> do ícone, no
    // <span> do texto, na <path> dentro do svg. `closest` sobe a árvore até
    // achar o controle de verdade. Sem isso, o rastreamento perderia a maior
    // parte dos cliques — e perderia de forma silenciosa e enviesada (só os
    // cliques na borda do botão seriam contados).
    const control = target.closest<HTMLElement>("a,button");
    if (!control) return;

    // -------------------------------------------------------------------------
    // Quatro sinais para reconhecer um CTA de WhatsApp.
    // -------------------------------------------------------------------------
    // O site tem CTA de WhatsApp em dezenas de lugares, e eles NÃO são iguais:
    //   - alguns são <a href="https://wa.me/...">        → pega pelo href
    //   - outros são <button onClick={abrirWhatsappRodizio}> e não têm href
    //     nenhum (o destino só existe depois da ida ao servidor)
    //     → pega pelo data-whatsapp-cta, que também diz a ORIGEM
    //   - outros são botões só com ícone               → pega pelo filho
    //                                                    [data-whatsapp-icon]
    //   - e os de acessibilidade com aria-label         → pega pelo rótulo
    //
    // O caso do meio é o que obriga a ter mais de um sinal: num rodízio, o
    // href não existe no momento do clique. Um rastreador que só olhasse href
    // mediria zero justamente nos botões mais importantes.
    const href = control.getAttribute("href") ?? "";
    const isWhatsapp = /(?:wa\.me|api\.whatsapp\.com|whatsapp:\/\/)/i.test(href) ||
      control.dataset.whatsappCta !== undefined ||
      Boolean(control.querySelector('[data-whatsapp-icon]')) ||
      /whatsapp/i.test(control.getAttribute("aria-label") ?? "");
    if (!isWhatsapp) return;

    // -------------------------------------------------------------------------
    // O BUG REAL QUE ESTE COMENTÁRIO DOCUMENTA
    // -------------------------------------------------------------------------
    // (comentário preservado literalmente do código de produção; virou commit
    //  próprio: "Corrige rastreamento de clique no WhatsApp: formato errado
    //  nunca chegava ao Google")
    //
    // gtag('event', ...), não dataLayer.push({event:...}): esse segundo formato
    // é convenção do Google Tag Manager, que o site não carrega — ficaria
    // empilhado no array sem nenhum container pra processar, e a conversão
    // nunca apareceria no Google Ads/Analytics.
    //
    // Por que é um bug difícil: nada falha. O array recebe o objeto, nenhum
    // erro aparece no console, o clique funciona. Só a conversão não existe —
    // e a campanha otimiza no escuro por semanas até alguém conferir.
    const browser = window as AnalyticsWindow;
    const params = {
      page_path: window.location.pathname,
      cta_origem: control.dataset.whatsappCta ?? "contato",  // de qual CTA saiu
      link_type: "whatsapp",
    };
    if (browser.gtag) {
      browser.gtag("event", "whatsapp_click", params);
    } else {
      // gtag ainda não carregou (clique nos primeiros milissegundos da página).
      // A fila oficial do gtag.js é o próprio dataLayer com a assinatura de
      // ARGUMENTOS (o objeto `arguments`), não um objeto literal: quando o
      // script carrega, ele reprocessa a fila nesse formato. É por isso que a
      // função usa `arguments` em vez dos parâmetros nomeados.
      browser.dataLayer ??= [];
      function gtag(..._args: unknown[]) { browser.dataLayer?.push(arguments); }
      gtag("event", "whatsapp_click", params);
    }
  };

  // ---------------------------------------------------------------------------
  // Um listener no document, na FASE DE CAPTURA.
  // ---------------------------------------------------------------------------
  // Delegação, e não um onClick por botão: os CTAs estão espalhados por rotas,
  // componentes de UI de terceiros (shadcn/Radix) e cartões gerados em laço.
  // Pendurar rastreamento em cada um seria garantia de esquecer alguns.
  //
  // E `true` (captura) em vez da bolha: a captura desce do document até o alvo
  // ANTES de a bolha subir, então nenhum componente no caminho consegue sumir
  // com o evento chamando stopPropagation() — o que bibliotecas de menu e
  // diálogo fazem com frequência. Medir não pode depender do comportamento
  // interno de um componente de terceiro.
  document.addEventListener("click", registrar, true);

  // Devolve o desfazedor: isto é chamado de dentro de um useEffect no runtime
  // do site, e sem o cleanup cada remontagem empilharia um listener novo —
  // dobrando, triplicando a contagem de cada clique.
  return () => document.removeEventListener("click", registrar, true);
}
