# Agenda de contatos

Agenda de terminal com menu: listar, adicionar, buscar e remover contato. Os dados ficam
num arquivo `contatos.json` ao lado do programa, então a agenda continua lá na próxima vez
que abrir.

## Rodar

```bash
python agenda_de_contatos.py
```

O arquivo `contatos.json` é criado na primeira vez que você salva um contato. Ele não está
no repositório de propósito — é dado, não código.

## Como é o uso

```
=== AGENDA DE CONTATOS ===
1 - Listar todos
2 - Adicionar contato
3 - Buscar contato
4 - Remover contato
5 - Sair
Escolha uma opcao: 2

--- Novo contato ---
Nome: Maria Souza
Telefone com DDD: 123
O telefone precisa ter DDD + numero (10 ou 11 digitos).
Telefone com DDD: 31988887777
Email: maria@email.com
Maria Souza entrou na agenda.
```

Listando:

```
--- 2 contato(s) ---
1. Joao Lima
   tel:   (31) 3333-4444
   email: joao@email.com
2. Maria Souza
   tel:   (31) 98888-7777
   email: maria@email.com
```

A busca aceita parte do nome **ou** parte do telefone — digitar `souza` ou `3333` acha.

## Como o dado é guardado

Um contato é um dicionário, e a agenda é uma lista de dicionários. É isso que vai para o
JSON, direto:

```json
[
  {
    "nome": "Maria Souza",
    "telefone": "31988887777",
    "email": "maria@email.com"
  }
]
```

O telefone é gravado **só com os dígitos** e formatado na hora de mostrar. Foi a decisão
mais útil do projeto: não importa se a pessoa digitou `(31) 98888-7777`, `31 98888 7777` ou
`31988887777`, no arquivo fica sempre `31988887777`. Por isso a busca por telefone funciona
com qualquer jeito de digitar, e por isso dá para comparar dois telefones sem me preocupar
com pontuação.

## O que eu aprendi fazendo

**Ler arquivo que pode não existir, e que pode estar quebrado.** `carregar_contatos` trata
os dois casos: se o arquivo não existe, devolve lista vazia (primeira execução, não é erro);
se existe mas o JSON está corrompido, avisa e começa agenda nova em vez de estourar
`JSONDecodeError` na cara do usuário. Aprendi a diferença entre "não tem" e "tem e está
errado".

**`ensure_ascii=False` no `json.dump`.** Sem isso, "José" é gravado como `"Jos\u00e9"`
dentro do arquivo. O Python lê de volta certo, mas fica ilegível quando abro o JSON para
conferir na mão.

**Onde o arquivo é criado importa.** Usei `Path(__file__).with_name("contatos.json")`:
`__file__` é o caminho do próprio script, então o JSON nasce na pasta do programa. Com o
nome solto (`"contatos.json"`) ele nasce na pasta de onde o comando foi chamado — e eu
achei que tinha perdido os contatos quando rodei de outro diretório.

**`sorted` com `key`.** Para listar em ordem alfabética sem ligar para maiúscula:
`sorted(contatos, key=lambda c: c["nome"].lower())`. Ordena a cópia na hora de mostrar e
deixa a lista de verdade na ordem em que foi digitada.

**Salvar na hora, não na saída.** Toda alteração grava o arquivo na mesma hora. Se a janela
fechar no meio, o que já foi digitado está salvo.

## Funções do arquivo

| Função | O que faz |
|---|---|
| `carregar_contatos()` | lê o JSON, tolerando arquivo ausente ou corrompido |
| `salvar_contatos(contatos)` | grava a lista no JSON |
| `so_numeros(texto)` | `"(31) 99999-8888"` → `"31999998888"` |
| `formatar_telefone(telefone)` | o contrário, para exibir |
| `pedir_texto(pergunta)` | insiste enquanto vier vazio |
| `pedir_telefone()` | insiste até ter 10 ou 11 dígitos |
| `listar` / `adicionar` / `buscar` / `remover` | as quatro opções do menu |

Tem duas travas pequenas que coloquei depois de errar usando: `adicionar` recusa nome
repetido (quase sempre é engano) e `remover` pede confirmação antes de apagar.

## Próximo passo

Opção de editar um contato — hoje para corrigir um telefone preciso apagar e cadastrar de
novo. E validar o email de verdade; hoje qualquer texto passa.
