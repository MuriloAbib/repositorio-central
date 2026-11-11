// =============================================================================
// 3/5 — A LÓGICA DO LADO DO CLIENTE: ESCOLHER, MONTAR O LINK, ABRIR A ABA
// =============================================================================
// Arquivo original no projeto: src/data/site.ts (linhas 28–147)
//
// ATENÇÃO — DADOS SUBSTITUÍDOS: os nomes, e-mails e telefones reais dos
// consultores foram trocados por exemplos. A ESTRUTURA é idêntica à de
// produção; só os dados pessoais de terceiros saíram. Nada mais foi alterado.
// =============================================================================

export type WhatsappConsultor = {
  slug: string;
  nome: string;
  email: string;
  whatsappDisplay: string;  // formatado para humano ler na tela
  whatsappNumber: string;   // só dígitos, com DDI, para a URL do wa.me
  inicial: string;
  rotulo: string;
};

// Número institucional — rede de segurança do cleanWhatsappNumber.
const WHATSAPP_INSTITUCIONAL = "5511900000000";

export const DEFAULT_WHATSAPP_MESSAGE =
  "Olá, vi o site e gostaria de receber mais informações sobre as máquinas de sorvete.";
export const DEFAULT_PROPOSTA_MESSAGE =
  "Olá, vi o site e gostaria de solicitar um orçamento.";

// -----------------------------------------------------------------------------
// O elenco da fila.
// -----------------------------------------------------------------------------
// whatsappNumber e whatsappDisplay são campos SEPARADOS de propósito. O humano
// precisa ler "+55 21 98215-4293"; a URL precisa de "5521982154293". Derivar um
// do outro na hora de renderizar é onde nasce o link quebrado — alguém esquece
// o DDI, ou deixa o hífen passar para dentro do wa.me/.
//
// email pode ser vazio: um dos consultores reais não recebe cópia por e-mail,
// os leads dele ficam só no CRM. O código trata com (consultor.email || null)
// na hora de gravar, então vazio não vira string "" no banco.
export const WHATSAPP_CONSULTORES: WhatsappConsultor[] = [
  {
    slug: "consultor-a",
    nome: "Consultor A",
    email: "consultor.a@exemplo.com.br",
    whatsappDisplay: "+55 11 90000-0001",
    whatsappNumber: "5511900000001",
    inicial: "A",
    rotulo: "Consultor A",
  },
  {
    slug: "consultor-b",
    nome: "Consultor B",
    email: "consultor.b@exemplo.com.br",
    whatsappDisplay: "+55 11 90000-0002",
    whatsappNumber: "5511900000002",
    inicial: "B",
    rotulo: "Consultor B",
  },
  {
    slug: "consultor-c",
    nome: "Consultor C",
    email: "", // sem e-mail: leads ficam apenas no CRM
    whatsappDisplay: "+55 11 90000-0003",
    whatsappNumber: "5511900000003",
    inicial: "C",
    rotulo: "Consultor C",
  },
];

// -----------------------------------------------------------------------------
// A ORDEM da fila, separada da LISTA de pessoas.
// -----------------------------------------------------------------------------
// Rodízio justo 1:1:1 — partes iguais, alternando a cada lead.
//
// Por que um array de slugs em vez de usar a ordem de WHATSAPP_CONSULTORES:
//   1. Trocar a ordem do rodízio não mexe no cadastro, e mexer no cadastro
//      (corrigir um telefone) não embaralha a fila.
//   2. É aqui que um rodízio PONDERADO entraria sem tocar em mais nada:
//      ["a","b","c","a"] dá 50% para A. O resto do código não muda uma linha,
//      porque tudo que ele faz é (posicao % RODIZIO_BASE.length).
const RODIZIO_BASE: Array<WhatsappConsultor["slug"]> = ["consultor-b", "consultor-a", "consultor-c"];

const RODIZIO_KEY = "rodizio_consultor_idx";

// Nunca devolve undefined. Se um slug de RODIZIO_BASE não existir no cadastro
// (erro de digitação num deploy), cai no primeiro consultor em vez de estourar
// um TypeError dentro de um clique de botão.
function consultorBySlug(slug: WhatsappConsultor["slug"]) {
  return WHATSAPP_CONSULTORES.find((c) => c.slug === slug) ?? WHATSAPP_CONSULTORES[0];
}

// -----------------------------------------------------------------------------
// Saneamento do número: o lead que se perde sem ninguém ver.
// -----------------------------------------------------------------------------
// Um link wa.me/ com número inválido não dá erro: abre o WhatsApp numa tela de
// "número inválido". O visitante desiste, e o site registra um clique
// bem-sucedido. É a pior classe de bug — a métrica diz que deu certo.
//
// Daí os dois passos: tira tudo que não é dígito, e se o resultado for curto
// demais para ser um telefone com DDI, usa o institucional. Mandar o lead para
// o número errado da empresa é ruim; mandar para o limbo é pior.
function cleanWhatsappNumber(number: string) {
  const cleaned = number.replace(/\D/g, "");
  return cleaned.length >= 10 ? cleaned : WHATSAPP_INSTITUCIONAL;
}

// -----------------------------------------------------------------------------
// ESPIAR NÃO É CONSUMIR
// -----------------------------------------------------------------------------
/** Espia o próximo consultor do rodízio sem avançar o contador. */
export function peekProximoConsultor(): WhatsappConsultor {
  // Existe porque a tela às vezes quer DIZER com quem a pessoa vai falar
  // ("você será atendido por...") antes de ela clicar. Se isso usasse a função
  // que avança, só renderizar a página queimaria uma posição da fila — e o
  // consultor exibido não seria o que receberia o lead.
  //
  // Duas funções em vez de um parâmetro booleano: proximo(avancar = false) é
  // onde alguém passa o default errado e desalinha o rodízio sem perceber.
  try {
    if (typeof window !== "undefined") {
      const atual = Number(localStorage.getItem(RODIZIO_KEY) ?? "0") % RODIZIO_BASE.length;
      return consultorBySlug(RODIZIO_BASE[atual]);
    }
  } catch { /* no-op */ }
  return consultorBySlug(RODIZIO_BASE[0]);
}

// -----------------------------------------------------------------------------
// O plano B: contador local.
// -----------------------------------------------------------------------------
// Isto NÃO é o mecanismo principal — é a rede. Ver docs/DECISOES-DE-ENGENHARIA.md,
// "Por que localStorage sozinho não resolve": o contador do navegador começa em
// zero para cada visitante novo, e visitante novo é justamente o perfil de quem
// chega por anúncio. Sozinho, isso manda a maioria dos leads para um consultor.
//
// Como rede, porém, serve: é melhor uma distribuição imperfeita durante uma
// queda do servidor do que um botão de WhatsApp que não abre.
//
// O (typeof window !== "undefined") é obrigatório: este arquivo é importado em
// rotas renderizadas no servidor (SSR), onde localStorage não existe. E o
// try/catch cobre navegador em modo privado ou com armazenamento bloqueado,
// onde o simples acesso a localStorage LANÇA exceção.
function proximoConsultorLocal(): WhatsappConsultor {
  let slug: WhatsappConsultor["slug"] = RODIZIO_BASE[0];
  try {
    if (typeof window !== "undefined") {
      const atual = Number(localStorage.getItem(RODIZIO_KEY) ?? "0") % RODIZIO_BASE.length;
      slug = RODIZIO_BASE[atual];
      localStorage.setItem(RODIZIO_KEY, String((atual + 1) % RODIZIO_BASE.length));
    }
  } catch { /* no-op */ }
  return consultorBySlug(slug);
}

// -----------------------------------------------------------------------------
// A porta de entrada: servidor primeiro, local se o servidor falhar.
// -----------------------------------------------------------------------------
/**
 * Retorna o próximo consultor do rodízio global (1:1), usando o contador do servidor
 * compartilhado por todos os visitantes. Se o servidor falhar, usa o contador local.
 */
export async function proximoConsultor(): Promise<WhatsappConsultor> {
  try {
    const { avancarRodizio } = await import("@/lib/rodizio.functions");
    const { posicao } = await avancarRodizio();

    // O resto da divisão é o que faz o contador infinito do banco virar índice
    // de array. O banco conta 0, 1, 2, 3, 4...; com 3 consultores isso dá
    // 0,1,2,0,1,... Acrescentar um quarto consultor não exige migração nem
    // resetar nada: o mesmo contador passa a girar em 4.
    return consultorBySlug(RODIZIO_BASE[posicao % RODIZIO_BASE.length]);
  } catch {
    // Catch sem distinção de erro, de propósito: rede caída, função fora do ar,
    // banco indisponível, timeout — a reação é a mesma, e é sempre "atenda o
    // cliente". Um throw aqui transformaria instabilidade de infraestrutura em
    // venda perdida de dezenas de milhares de reais.
    return proximoConsultorLocal();
  }
}

// -----------------------------------------------------------------------------
// Montagem do link.
// -----------------------------------------------------------------------------
export function whatsappExternalLink(
  msg = DEFAULT_WHATSAPP_MESSAGE,
  number = WHATSAPP_CONSULTORES[0].whatsappNumber,
) {
  // encodeURIComponent não é opcional: a mensagem padrão tem vírgula, e as
  // mensagens montadas em tempo real (ver arquivo 5) trazem "&", ":" e acento
  // vindos de campo de formulário. Sem o encode, o texto chega cortado no
  // primeiro "&" — o consultor recebe meia frase e perde o contexto do lead.
  return `https://wa.me/${cleanWhatsappNumber(number)}?text=${encodeURIComponent(msg)}`;
}

export async function whatsappRoundRobinLink(msg = DEFAULT_WHATSAPP_MESSAGE) {
  const c = await proximoConsultor();
  return whatsappExternalLink(msg, c.whatsappNumber);
}

// =============================================================================
// O PONTO MAIS SUTIL DO ARQUIVO INTEIRO: ABRIR ABA DEPOIS DE UM AWAIT
// =============================================================================
/** Abre o WhatsApp do próximo consultor do rodízio (abre a aba já no clique para não ser bloqueada). */
export function abrirWhatsappRodizio(msg = DEFAULT_WHATSAPP_MESSAGE) {
  // O problema:
  //   O navegador só deixa window.open abrir aba nova se a chamada acontecer
  //   DENTRO do gesto do usuário (o tique do clique). Mas descobrir o número
  //   exige ida ao servidor — e depois de um await, o gesto já expirou. Um
  //   window.open ali é bloqueado como pop-up. O usuário clica, nada abre.
  //
  // A solução, em três tempos:

  // 1) Ainda DENTRO do clique, abre uma aba vazia. Não sabemos o destino ainda,
  //    e não precisamos: o que precisava do gesto era ABRIR, não navegar.
  const win = window.open("about:blank", "_blank");

  // 2) Resolve o rodízio em paralelo. Note que NÃO há await nesta função — ela
  //    é síncrona de ponta a ponta, e por isso é segura de pendurar direto num
  //    onClick. O trabalho assíncrono vive dentro do .then.
  whatsappRoundRobinLink(msg).then((href) => {
    if (win && !win.closed) {
      // 3) Corta o cordão antes de navegar: sem isso, a página de destino
      //    recebe uma referência window.opener para o nosso site e pode
      //    reescrever a aba de origem (tabnabbing). É o equivalente ao
      //    rel="noopener" de um link, que window.open programático não tem.
      //    Dentro de try porque alguns navegadores proíbem a atribuição.
      try { win.opener = null; } catch { /* no-op */ }
      win.location.href = href;
    } else {
      // Bloqueador agressivo, ou usuário que fechou a aba em branco: navega na
      // própria aba. Perde-se o site, não se perde o lead. Esta é a ordem de
      // prioridade correta para um botão que vale uma venda.
      window.location.href = href;
    }
  });
}
