#!/usr/bin/env bash
# Valid8 — os quatro casos do fluxo.
#
# Uso:
#   bash testar.sh                                       # URL de teste local
#   bash testar.sh http://localhost:5678/webhook/valid8  # URL de producao
#
# Na URL de teste o n8n pega UMA requisicao e para: clique em
# "Listen for test event" antes de cada chamada.

set -u
URL="${1:-http://localhost:5678/webhook-test/valid8}"

chamar() {
  echo "=== $1 ==="
  curl -s -w "\n-- status: %{http_code}\n" -X POST "$URL" \
    -H "Content-Type: application/json" -d "$2"
  echo
}

chamar "1. Pedido bom em SP, acima de R\$ 299 (espera frete 0 e prazo 4)" '{
  "cliente": "Ana Souza",
  "cep": "01310-930",
  "itens": [
    { "sku": "CAD-001", "nome": "Cadeira", "qtd": 2, "preco": 149.9 },
    { "sku": "MES-010", "nome": "Mesa",    "qtd": 1, "preco": 89.9 }
  ]
}'

chamar "2. Pedido bom fora do Sudeste/Sul (espera frete 54.9 e prazo 8)" '{
  "cliente": "Carlos Lima",
  "cep": "69900-062",
  "itens": [ { "sku": "CAD-001", "nome": "Cadeira", "qtd": 1, "preco": 149.9 } ]
}'

chamar "3. CEP curto (espera 400, SEM chamar a ViaCEP)" '{
  "cliente": "Teste",
  "cep": "123",
  "itens": [ { "sku": "CAD-001", "qtd": 1, "preco": 10 } ]
}'

chamar "4. CEP inexistente (espera 200 pelo fallback, endereco null)" '{
  "cliente": "Teste",
  "cep": "99999999",
  "itens": [ { "sku": "CAD-001", "qtd": 1, "preco": 10 } ]
}'

echo "Abra Executions e veja por qual saida do Switch cada item passou."
