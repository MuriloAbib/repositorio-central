// =============================================================================
// 5/5 — OS DOIS MODOS DE CONSUMO, E A ATRIBUIÇÃO DO LEAD
// =============================================================================
// Trechos reais de:
//   src/components/site/SiteRuntime.tsx        (instalação do rastreamento)
//   src/components/site/ContatoMenu.tsx        (modo 1: botão direto)
//   src/components/site/MachinePesquisaForm.tsx (modo 2: formulário)
//   src/routes/contato.tsx                     (modo 2 + tela de sucesso)
//
// O rodízio é consumido de DUAS formas diferentes, e a diferença não é estética:
//   Modo 1 — botão direto:  o visitante sai do site para o WhatsApp. Não há
//                           formulário, não há dado nenhum além do clique.
//   Modo 2 — formulário:    o lead é gravado no banco COM o consultor da vez
//                           dentro do registro, e só então a tela diz com quem
//                           ele vai falar.
// =============================================================================

import { useEffect, useRef, useState } from "react";
import { useRouterState } from "@tanstack/react-router";
import { instalarRastreamentoWhatsapp } from "@/lib/whatsapp-tracking";
import { abrirWhatsappRodizio, proximoConsultor, whatsappExternalLink } from "@/data/site";
import { WhatsappIcon } from "@/components/site/WhatsappIcon";
import { toast } from "sonner";


// =============================================================================
// INSTALAÇÃO DO RASTREAMENTO — uma vez, na raiz do site
// =============================================================================
export function SiteRuntime() {
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const ultimaPagina = useRef<string | null>(null);

  // `useEffect(instalarRastreamentoWhatsapp, [])` — a função é passada DIRETO,
  // sem arrow envolvendo. Funciona porque ela devolve exatamente o que o
  // useEffect espera de uma função de efeito: o cleanup. Array de dependências
  // vazio = instala uma vez e desinstala na desmontagem. É a assinatura do
  // arquivo 4 pagando dividendo aqui.
  useEffect(instalarRastreamentoWhatsapp, []);

  useEffect(() => {
    if (ultimaPagina.current === pathname) return;
    ultimaPagina.current = pathname;
    // ... conversão de página e analytics
  }, [pathname]);

  return null;
}


// =============================================================================
// MODO 1 — BOTÃO DIRETO: o caso mais comum, e o mais frágil
// =============================================================================
export function ContatoCta({ onNavigate }: { onNavigate?: () => void }) {
  function abrirWhatsappDireto() {
    // Chamada SÍNCRONA dentro do onClick. Nada de `async function` aqui, nada
    // de await — e é por isso que o arquivo 3 fez questão de deixar
    // `abrirWhatsappRodizio` síncrona. Se este handler fosse async, a abertura
    // da aba cairia depois do gesto do usuário e o pop-up seria bloqueado.
    abrirWhatsappRodizio();
    onNavigate?.();
  }

  return (
    <button
      // `data-whatsapp-cta` faz DUAS coisas:
      //   1. marca o botão como CTA de WhatsApp para o rastreador (o arquivo 4
      //      precisa desse sinal, porque este botão NÃO tem href — o destino só
      //      é conhecido depois da ida ao servidor);
      //   2. nomeia a origem, que vai no parâmetro `cta_origem` do evento.
      //      "contato", "showroom", "catalogo"... é assim que se descobre qual
      //      seção da página gera conversa de verdade.
      data-whatsapp-cta="contato"
      onClick={abrirWhatsappDireto}
      className="inline-flex items-center gap-2.5 rounded-xl bg-[color:var(--whatsapp)] px-6 py-3.5 text-base font-medium text-white"
    >
      <WhatsappIcon mono className="h-6 w-6" /> Clique e fale com um consultor
    </button>
  );
}


// =============================================================================
// MODO 2 — FORMULÁRIO: aqui o rodízio vira ATRIBUIÇÃO, não só roteamento
// =============================================================================
export function PesquisaForm({ maquinaSlug, maquinaNome }: { maquinaSlug: string; maquinaNome: string }) {
  const [loading, setLoading] = useState(false);

  async function enviar(dados: { estado: string; segmento: string; horizonte: string; email: string }) {
    setLoading(true);
    try {
      // A ORDEM IMPORTA: resolve o consultor ANTES do insert, porque o
      // consultor é coluna do próprio lead. Fazer o insert primeiro e tentar
      // atualizar depois criaria uma janela em que o lead existe sem dono — e
      // se a segunda chamada falhasse, ele ficaria órfão no banco para sempre.
      const consultor = await proximoConsultor();

      const { supabase } = await import("@/integrations/supabase/client");

      // Grava o dono do lead DENTRO do lead. Isto é o que transforma "rodízio"
      // em "atribuição": o CRM sabe de quem é cada ficha, não só quantos
      // cliques cada um recebeu.
      const { error } = await supabase.from("leads_pesquisa").insert({
        maquina_slug: maquinaSlug,
        maquina_nome: maquinaNome,
        estado: dados.estado,
        segmento: dados.segmento,
        horizonte_investimento: dados.horizonte,
        email: dados.email.trim().toLowerCase(),
        consultor: consultor.nome,
        // `|| null` e não `|| ""`: consultor sem e-mail precisa gravar NULL,
        // senão a rotina de envio tentaria disparar para string vazia.
        email_vendedor: consultor.email || null,
      });

      // Erro de insert NÃO interrompe o fluxo: o visitante segue para o
      // WhatsApp e recebe o PDF. O lead perdido no banco é prejuízo; o lead
      // perdido na tela é prejuízo E vexame. Vai para o console (e, em
      // produção, para o log do servidor).
      if (error) console.error(error);

      // `void` na frente: dispara e não espera. A auditoria do rodízio não
      // pode adicionar latência ao caminho do cliente. Se ela falhar, perde-se
      // uma linha de estatística — não a venda.
      void supabase.from("consultor_cliques").insert({
        consultor: consultor.nome,
        origem: `pesquisa-${maquinaSlug}`,  // qual máquina gerou o lead
        canal: "formulario",                // diferencia do canal "whatsapp"
      });
    } catch (err) {
      console.error(err);
      toast.error("Erro ao enviar. Tente novamente.");
    } finally {
      setLoading(false);
    }
  }

  return <form onSubmit={(e) => { e.preventDefault(); /* ...validação com zod... */ }} />;
}


// =============================================================================
// A TELA DE SUCESSO — por que ela recebe o consultor como prop
// =============================================================================
export function SucessoComConsultor({ consultor }: { consultor: { nome: string; whatsappNumber: string } }) {
  // O consultor chega de FORA, resolvido lá no submit. A tela não chama
  // `proximoConsultor()` de novo — se chamasse, avançaria o contador uma
  // segunda vez pelo mesmo lead (quebrando o 1:1:1) e poderia exibir um nome
  // diferente do que foi gravado no banco. O visitante falaria com alguém que
  // não tem a ficha dele.
  const mensagem = `Olá ${consultor.nome}, acabei de enviar uma solicitação pelo site e gostaria de falar agora.`;

  return (
    <div className="mx-auto max-w-xl px-6 py-14 text-center">
      <h1 className="font-display text-3xl font-bold">Solicitação recebida!</h1>
      <p className="mt-3 text-muted-foreground">
        Recebemos sua solicitação. Um de nossos consultores entrará em contato em breve.
      </p>

      {/* Aqui o link JÁ TEM href (o número está decidido), então usa-se
          `whatsappExternalLink` — a versão que não avança o rodízio. E o
          rastreador do arquivo 4 pega este clique pelo href wa.me, sem
          precisar do data-attribute. */}
      <a
        href={whatsappExternalLink(mensagem, consultor.whatsappNumber)}
        target="_blank"
        rel="noopener noreferrer"
        className="mt-6 inline-flex items-center gap-2 rounded-xl bg-[color:var(--whatsapp)] px-6 py-3 text-white"
      >
        <WhatsappIcon mono className="h-5 w-5" /> Falar agora com {consultor.nome}
      </a>
    </div>
  );
}

// -----------------------------------------------------------------------------
// Nota sobre `rel="noopener noreferrer"` acima:
// -----------------------------------------------------------------------------
// É o mesmo cuidado do `win.opener = null` do arquivo 3, na versão declarativa.
// Vale a pena notar que são dois caminhos para o mesmo destino (WhatsApp) com
// mecanismos de proteção diferentes, porque um é <a> e o outro é window.open.
// Quem revisar o código e só conhecer o `rel` vai achar que o window.open está
// desprotegido — está no arquivo 3, em forma de atribuição.
