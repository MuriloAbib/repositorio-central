# Controle de gastos

Controle de gastos de terminal. Lança o gasto com data, categoria, descrição e valor, lista
tudo e fecha um relatório somando por categoria com a porcentagem de cada uma. Os
lançamentos ficam num `gastos.csv` ao lado do programa.

Escolhi CSV em vez de JSON de propósito: é o formato que abre direto no Excel ou no Google
Planilhas, então o mesmo arquivo serve para o programa e para quem quiser olhar na
planilha.

## Rodar

```bash
python controle_de_gastos.py
```

## Como é o uso

```
=== CONTROLE DE GASTOS ===
1 - Lancar gasto
2 - Ver todos os lancamentos
3 - Relatorio por categoria
4 - Sair
Escolha uma opcao: 1

--- Novo gasto ---
Data (dd/mm/aaaa, Enter para hoje):
Categorias:
  1 - mercado
  2 - transporte
  3 - moradia
  4 - lazer
  5 - saude
  6 - outros
Numero da categoria: 1
Descricao: Feira da semana
Valor (ex: 42,90): 187,40
Lancado: Feira da semana - R$ 187,40
```

Os lançamentos:

```
--- 3 lancamento(s) ---
05/11/2026  mercado      Feira da semana             R$ 187,40
09/11/2026  transporte   Gasolina                    R$ 250,00
10/11/2026  lazer        Cinema                       R$ 68,90
                                          TOTAL      R$ 506,30
```

O relatório:

```
--- Gasto por categoria ---
transporte       R$ 250,00   49.4%  ##########
mercado          R$ 187,40   37.0%  #######
lazer             R$ 68,90   13.6%  ###
TOTAL            R$ 506,30
Media por lancamento: R$ 168,77
```

A barrinha de `#` é só `"#" * round(fatia / 5)` — cada bloco vale 5%. Gráfico com o que o
terminal tem.

## Como o dado é guardado

```csv
data,categoria,descricao,valor
2026-11-05,mercado,Feira da semana,187.4
2026-11-09,transporte,Gasolina,250.0
2026-11-10,lazer,Cinema,68.9
```

Duas decisões que valem explicação:

**A data é gravada como `2026-11-05` e mostrada como `05/11/2026`.** Guardo no formato
ano-mês-dia porque assim a ordem alfabética **é** a ordem cronológica — ordenar os
lançamentos vira `sorted(gastos, key=lambda g: g["data"])`, sem converter nada para data.
Se eu gravasse `05/11/2026`, a ordenação por texto misturaria os meses, porque ela
compararia o dia primeiro.

**O valor é gravado com ponto e mostrado com vírgula.** No arquivo é `187.4`, que é como o
Python entende número; na tela é `R$ 187,40`, que é como se lê em português.

## O que eu aprendi fazendo

**`csv.DictReader` e `csv.DictWriter`.** Lendo com `DictReader`, cada linha já vem como
dicionário com as colunas do cabeçalho como chave — não preciso lembrar que a coluna 3 é o
valor. A pegadinha: **tudo vem como texto**, então o valor precisa de `float(...)` na
entrada. Foi o meu primeiro bug aqui — a soma do relatório estava grudando os números
("187.4250.0") em vez de somar, porque eu estava somando strings.

**`newline=""` ao abrir o arquivo.** Está na documentação do módulo `csv` e eu ignorei; no
Windows o arquivo saiu com uma linha vazia entre cada lançamento. O módulo `csv` já cuida
do fim de linha, e sem `newline=""` ele é cuidado duas vezes.

**Formatar real na mão.** `f"{valor:,.2f}"` dá `1,234.50` — separador americano. Para virar
`1.234,50` eu troco os dois separadores de uma vez usando um símbolo que não aparece no
meio (`#`) como passagem; trocar direto um pelo outro faria a segunda troca desfazer a
primeira.

**Alinhar coluna com f-string.** `{categoria:<12}` empurra para a esquerda num espaço de
12, `{valor:>14}` alinha à direita. É o que faz as colunas ficarem retas sem eu contar
espaço na mão.

**Aceitar vírgula no valor digitado.** `resposta.replace(",", ".")` antes do `float`. A
pessoa digita `42,90` porque é assim que se escreve aqui, e quem tem que se adaptar é o
programa.

**Linha estragada não derruba o resto.** Se alguém editar o CSV na planilha e salvar um
valor inválido, `carregar_gastos` avisa qual linha pulou e segue com as outras.

## Funções do arquivo

| Função | O que faz |
|---|---|
| `carregar_gastos()` | lê o CSV e converte o valor para `float` |
| `salvar_gastos(gastos)` | reescreve o CSV com cabeçalho |
| `em_reais(valor)` | `1234.5` → `R$ 1.234,50` |
| `pedir_data()` | valida com `strptime`; Enter vale como hoje |
| `pedir_categoria()` | menu numerado das categorias |
| `pedir_valor()` | aceita vírgula, recusa zero e negativo |
| `lancar` / `listar` / `relatorio` | as três opções do menu |

## Próximo passo

Filtrar por mês. Hoje o relatório soma tudo que existe no arquivo; o certo é perguntar o
mês e somar só ele — a data já está gravada em formato que facilita isso, porque
`data.startswith("2026-11")` resolve. Depois, orçamento por categoria, para o relatório
dizer se estourei.
