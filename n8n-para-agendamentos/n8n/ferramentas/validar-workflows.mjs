#!/usr/bin/env node
/**
 * Validador dos workflows do n8n desta pasta.
 *
 * Checa o que o n8n só reclamaria na importação (ou pior: em produção):
 * JSON válido, tipos de nó permitidos, typeVersion coerente, nome de nó único,
 * conexão apontando para nó que existe, nó órfão, trigger presente, retry em
 * chamada externa, e segredo embutido no arquivo.
 *
 *   node n8n/ferramentas/validar-workflows.mjs
 *   node n8n/ferramentas/validar-workflows.mjs n8n/workflows/01-pagamento-provisionamento.json
 *
 * Sai com código 1 se houver ERRO. AVISO não derruba o build.
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, dirname, basename, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const RAIZ = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const DIR_WORKFLOWS = join(RAIZ, "n8n", "workflows");

/** Tipos permitidos e a typeVersion esperada. Fonte: ESPECIFICACAO.md §8. */
const TIPOS_PERMITIDOS = {
  "n8n-nodes-base.webhook": [2, 2.1],
  "n8n-nodes-base.respondToWebhook": [1, 1.1],
  "n8n-nodes-base.httpRequest": [4, 4.1, 4.2],
  "n8n-nodes-base.code": [1, 2],
  "n8n-nodes-base.if": [1, 2],
  "n8n-nodes-base.switch": [1, 2, 3],
  "n8n-nodes-base.set": [2, 3, 3.3, 3.4],
  "n8n-nodes-base.postgres": [2, 2.1, 2.2, 2.3, 2.4],
  "n8n-nodes-base.scheduleTrigger": [1, 1.1, 1.2],
  "n8n-nodes-base.splitInBatches": [2, 3],
  "n8n-nodes-base.noOp": [1],
  "n8n-nodes-base.errorTrigger": [1],
  "n8n-nodes-base.executeWorkflow": [1, 1.1, 1.2],
  "n8n-nodes-base.stopAndError": [1],
  "n8n-nodes-base.wait": [1, 1.1],
  "n8n-nodes-base.merge": [2, 3],
  "n8n-nodes-base.emailSend": [2, 2.1],
  "n8n-nodes-base.crypto": [1],
};

/** Nós que não precisam de entrada: são gatilho. */
const TIPOS_GATILHO = new Set([
  "n8n-nodes-base.webhook",
  "n8n-nodes-base.scheduleTrigger",
  "n8n-nodes-base.errorTrigger",
]);

/** Nós que falam com o mundo: exigem retry configurado. */
const TIPOS_CHAMADA_EXTERNA = new Set([
  "n8n-nodes-base.httpRequest",
  "n8n-nodes-base.emailSend",
]);

/**
 * Padrões de segredo que nunca podem estar no arquivo. O workflow referencia
 * credencial por nome; valor vem do n8n Credentials ou de variável.
 */
const PADROES_DE_SEGREDO = [
  [/\bghp_[A-Za-z0-9]{20,}/, "token do GitHub"],
  [/\bsk_live_[A-Za-z0-9]{10,}/, "chave viva do Stripe"],
  [/\bwhsec_[A-Za-z0-9]{10,}/, "segredo de webhook do Stripe"],
  [/\bAPP_USR-[A-Za-z0-9-]{10,}/, "access token do Mercado Pago"],
  [/\$aact_[A-Za-z0-9]{10,}/, "chave do Asaas"],
  [/\bEAA[A-Za-z0-9]{40,}/, "token da Meta/WhatsApp"],
  [/\beyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}\./, "JWT (service role do Supabase?)"],
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "chave privada"],
];

const erros = [];
const avisos = [];

const erro = (arq, msg) => erros.push(`${arq}: ${msg}`);
const aviso = (arq, msg) => avisos.push(`${arq}: ${msg}`);

function validar(caminho) {
  const arq = basename(caminho);
  const bruto = readFileSync(caminho, "utf8");

  for (const [padrao, oque] of PADROES_DE_SEGREDO) {
    if (padrao.test(bruto)) erro(arq, `segredo embutido no arquivo (${oque}) — use Credentials do n8n`);
  }

  let wf;
  try {
    wf = JSON.parse(bruto);
  } catch (e) {
    erro(arq, `JSON inválido: ${e.message}`);
    return;
  }

  if (typeof wf.name !== "string" || !wf.name.trim()) erro(arq, 'falta "name"');
  if (!Array.isArray(wf.nodes)) {
    erro(arq, '"nodes" tem de ser array');
    return;
  }
  if (wf.nodes.length === 0) erro(arq, "workflow sem nenhum nó");
  if (wf.connections === undefined || wf.connections === null || typeof wf.connections !== "object") {
    erro(arq, '"connections" tem de ser objeto (pode ser {} se houver um nó só)');
    return;
  }
  if (!wf.settings || wf.settings.executionOrder !== "v1") {
    aviso(arq, 'settings.executionOrder deveria ser "v1"');
  }

  // --- nós ---
  const nomes = new Set();
  const ids = new Set();
  const porNome = new Map();
  const reUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

  for (const [i, no] of wf.nodes.entries()) {
    const onde = `nó #${i}${no?.name ? ` ("${no.name}")` : ""}`;

    if (!no || typeof no !== "object") {
      erro(arq, `${onde} não é objeto`);
      continue;
    }
    if (typeof no.name !== "string" || !no.name.trim()) {
      erro(arq, `${onde} sem "name"`);
      continue;
    }
    if (nomes.has(no.name)) erro(arq, `nome de nó repetido: "${no.name}" — connections indexa por nome, repetido quebra o grafo`);
    nomes.add(no.name);
    porNome.set(no.name, no);

    if (typeof no.id !== "string" || !reUuid.test(no.id)) {
      erro(arq, `${onde}: "id" tem de ser UUID v4 literal`);
    } else if (ids.has(no.id)) {
      erro(arq, `${onde}: "id" repetido (${no.id})`);
    } else {
      ids.add(no.id);
    }

    if (!(no.type in TIPOS_PERMITIDOS)) {
      erro(arq, `${onde}: tipo não permitido "${no.type}" — ver ESPECIFICACAO.md §8`);
    } else if (!TIPOS_PERMITIDOS[no.type].includes(no.typeVersion)) {
      erro(
        arq,
        `${onde}: typeVersion ${no.typeVersion} inválida para ${no.type} (esperado ${TIPOS_PERMITIDOS[no.type].join(" ou ")})`,
      );
    }

    if (!Array.isArray(no.position) || no.position.length !== 2 || no.position.some((n) => typeof n !== "number")) {
      erro(arq, `${onde}: "position" tem de ser [x, y] numérico`);
    }
    if (no.parameters === undefined || typeof no.parameters !== "object" || no.parameters === null) {
      erro(arq, `${onde}: falta "parameters" (use {} se não houver)`);
    }

    if (no.type === "n8n-nodes-base.webhook" && (typeof no.webhookId !== "string" || !reUuid.test(no.webhookId))) {
      erro(arq, `${onde}: nó webhook precisa de "webhookId" UUID v4`);
    }

    if (TIPOS_CHAMADA_EXTERNA.has(no.type) && no.retryOnFail !== true) {
      aviso(arq, `${onde}: chamada externa sem retryOnFail — a entrega deixa de ser garantida`);
    }

    // Code node: pegar erro de sintaxe antes de o n8n pegar em produção.
    if (no.type === "n8n-nodes-base.code") {
      const cod = no.parameters?.jsCode;
      if (typeof cod !== "string" || !cod.trim()) {
        erro(arq, `${onde}: Code sem "jsCode"`);
      } else {
        try {
          new Function(cod);
        } catch (e) {
          erro(arq, `${onde}: erro de sintaxe no jsCode — ${e.message}`);
        }
      }
    }
  }

  // --- conexões ---
  const comEntrada = new Set();
  for (const [origem, saidas] of Object.entries(wf.connections)) {
    if (!nomes.has(origem)) {
      erro(arq, `connections referencia nó de origem inexistente: "${origem}"`);
      continue;
    }
    if (!saidas || typeof saidas !== "object") {
      erro(arq, `connections["${origem}"] tem de ser objeto`);
      continue;
    }
    for (const [tipoSaida, ramos] of Object.entries(saidas)) {
      if (!Array.isArray(ramos)) {
        erro(arq, `connections["${origem}"]["${tipoSaida}"] tem de ser array de ramos`);
        continue;
      }
      for (const [iRamo, ramo] of ramos.entries()) {
        if (ramo === null) continue; // ramo desligado, legítimo
        if (!Array.isArray(ramo)) {
          erro(arq, `connections["${origem}"]["${tipoSaida}"][${iRamo}] tem de ser array`);
          continue;
        }
        for (const lig of ramo) {
          if (!lig || typeof lig.node !== "string") {
            erro(arq, `connections["${origem}"] tem ligação sem "node"`);
            continue;
          }
          if (!nomes.has(lig.node)) {
            erro(arq, `"${origem}" liga para nó inexistente: "${lig.node}"`);
            continue;
          }
          if (lig.type !== tipoSaida) {
            aviso(arq, `"${origem}" -> "${lig.node}": type "${lig.type}" diferente da saída "${tipoSaida}"`);
          }
          if (typeof lig.index !== "number") {
            erro(arq, `"${origem}" -> "${lig.node}": falta "index" numérico`);
          }
          comEntrada.add(lig.node);
        }
      }
    }
  }

  // --- grafo ---
  const gatilhos = wf.nodes.filter((n) => TIPOS_GATILHO.has(n.type));
  if (gatilhos.length === 0) {
    erro(arq, "workflow sem nó de gatilho (webhook, scheduleTrigger ou errorTrigger) — nunca roda");
  }
  for (const no of wf.nodes) {
    if (!TIPOS_GATILHO.has(no.type) && !comEntrada.has(no.name)) {
      erro(arq, `nó órfão: "${no.name}" não recebe nenhuma conexão e não é gatilho`);
    }
  }

  // --- webhook tem de responder ---
  const temWebhook = wf.nodes.some((n) => n.type === "n8n-nodes-base.webhook");
  if (temWebhook) {
    const modos = wf.nodes
      .filter((n) => n.type === "n8n-nodes-base.webhook")
      .map((n) => n.parameters?.responseMode);
    const precisaNoDeResposta = modos.includes("responseNode");
    const temNoDeResposta = wf.nodes.some((n) => n.type === "n8n-nodes-base.respondToWebhook");
    if (precisaNoDeResposta && !temNoDeResposta) {
      erro(arq, 'webhook com responseMode "responseNode" mas sem nó "Respond to Webhook" — o gateway toma timeout');
    }
  }
}

// --- execução ---
const alvos = process.argv.slice(2);
let arquivos;
if (alvos.length > 0) {
  arquivos = alvos.map((a) => resolve(a));
} else {
  let entradas = [];
  try {
    entradas = readdirSync(DIR_WORKFLOWS);
  } catch {
    console.error(`sem a pasta ${DIR_WORKFLOWS}`);
    process.exit(1);
  }
  arquivos = entradas.filter((f) => f.endsWith(".json")).sort().map((f) => join(DIR_WORKFLOWS, f));
}

if (arquivos.length === 0) {
  console.error("nenhum workflow .json encontrado");
  process.exit(1);
}

for (const f of arquivos) {
  if (!statSync(f).isFile()) continue;
  validar(f);
}

console.log(`validados ${arquivos.length} workflow(s)\n`);

if (avisos.length) {
  console.log(`AVISOS (${avisos.length}):`);
  for (const a of avisos) console.log(`  ~ ${a}`);
  console.log("");
}

if (erros.length) {
  console.log(`ERROS (${erros.length}):`);
  for (const e of erros) console.log(`  x ${e}`);
  console.log("\nREPROVADO");
  process.exit(1);
}

console.log("APROVADO — nenhum erro");
