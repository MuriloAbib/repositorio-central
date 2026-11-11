#!/usr/bin/env bash
# Captur8 — testa o caminho bom e o caminho ruim.
#
# Uso:
#   bash testar.sh                                  # URL de teste local
#   bash testar.sh http://localhost:5678/webhook/captur8   # URL de producao
#
# Lembrete: na URL de teste (/webhook-test/) o n8n pega UMA requisicao e para.
# Clique em "Listen for test event" antes de cada chamada.

set -u
URL="${1:-http://localhost:5678/webhook-test/captur8}"

echo "=== 1. Lead bom (espera 200 + linha na planilha) ==="
curl -s -w "\n-- status: %{http_code}\n" -X POST "$URL" \
  -H "Content-Type: application/json" \
  -d '{
    "nome": "Ana Souza",
    "email": "ANA@Exemplo.com.br",
    "telefone": "(11) 98765-4321",
    "origem": "instagram",
    "mensagem": "Quero saber o preco"
  }'

echo
echo "=== 2. Celular em formato antigo (8 digitos: espera o 9 inserido) ==="
curl -s -w "\n-- status: %{http_code}\n" -X POST "$URL" \
  -H "Content-Type: application/json" \
  -d '{
    "nome": "Jose Antigo",
    "email": "jose@exemplo.com.br",
    "telefone": "11 98765432",
    "origem": "indicacao"
  }'

echo
echo "=== 3. Telefone fixo (espera tipo_telefone = fixo, NAO descartado) ==="
curl -s -w "\n-- status: %{http_code}\n" -X POST "$URL" \
  -H "Content-Type: application/json" \
  -d '{
    "nome": "Otica Centro",
    "email": "contato@oticacentro.com.br",
    "telefone": "(11) 3256-7890",
    "origem": "google"
  }'

echo
echo "=== 4. Lead ruim (espera 400 e NADA na planilha) ==="
curl -s -w "\n-- status: %{http_code}\n" -X POST "$URL" \
  -H "Content-Type: application/json" \
  -d '{"nome": "", "email": "nao-e-email", "telefone": "123"}'

echo
echo "Confira a planilha: devem ter entrado 3 linhas, nao 4."
