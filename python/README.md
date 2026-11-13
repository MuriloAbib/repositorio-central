# Projetos de estudo em Python

Cinco programas pequenos de terminal que escrevi enquanto aprendia Python. Cada um foi
feito para treinar um conjunto diferente de coisa básica da linguagem — lista, dicionário,
conjunto, arquivo, módulo da biblioteca padrão — e não para resolver um problema grande.

Nenhum deles instala nada: só a biblioteca padrão do Python 3.10 ou mais novo.

## O que tem aqui

| Pasta | Programa | O que eu treinei nele |
|---|---|---|
| [01-jogo-da-velha/](01-jogo-da-velha/) | Jogo da velha para dois jogadores | lista como tabuleiro, `while`, função que decide o vencedor |
| [02-jogo-da-forca/](02-jogo-da-forca/) | Jogo da forca | `set`, `random`, texto multilinha, comparar letra com acento |
| [03-agenda-de-contatos/](03-agenda-de-contatos/) | Agenda que salva em JSON | dicionário, `json`, ler e gravar arquivo, `sorted` com `key` |
| [04-controle-de-gastos/](04-controle-de-gastos/) | Controle de gastos do mês | `csv`, `datetime`, somar por categoria, formatar número em reais |
| [05-gerador-de-senha/](05-gerador-de-senha/) | Gerador e conferidor de senha | `secrets`, `string`, `any()`, função que devolve duas coisas |

## Como rodar

Cada pasta tem um arquivo `.py` só, que já roda direto:

```bash
cd 01-jogo-da-velha
python jogo_da_velha.py
```

No Windows, se `python` não funcionar, tente `py jogo_da_velha.py`.

Para conferir a versão do Python:

```bash
python --version
```

## Como eu organizei

Mesma receita nos cinco, porque foi assim que entendi que programa de terminal fica fácil
de ler:

- **Uma função por tarefa**, com nome que diz o que ela faz (`procurar_vencedor`,
  `formatar_telefone`, `avaliar_senha`).
- **Entrada do usuário sempre validada num laço**, numa função separada (`pedir_letra`,
  `pedir_valor`). Enquanto a pessoa digitar errado, o programa pergunta de novo em vez de
  quebrar.
- **O que manda no comportamento fica em constante no topo do arquivo** (`MAXIMO_DE_ERROS`,
  `CATEGORIAS`, `LINHAS_QUE_VENCEM`), para mudar a regra sem caçar no meio do código.
- **`if __name__ == "__main__":` no fim**, chamando `main()`. Assim dá para importar as
  funções de outro arquivo sem o menu abrir.
- **Comentário só onde o código não se explica** — o porquê, não o quê.

Os dois programas que guardam dado (agenda e gastos) escrevem o arquivo na própria pasta
do script, usando `Path(__file__).with_name(...)`, e não na pasta de onde o comando foi
chamado. Foi um erro que cometi antes: rodava de outro lugar e parecia que os dados tinham
sumido.

## O que eu sei que falta

Deixo registrado o que reconheço como limite destes programas, porque o próximo passo de
cada um foi escolha consciente de escopo, não descuido:

- **Não tem teste automatizado.** Testei na mão, rodando. O passo natural é `pytest` nas
  funções que não dependem de `input()` — `procurar_vencedor`, `avaliar_senha`,
  `formatar_telefone` já estão separadas justamente para isso.
- **Não tem interface gráfica nem banco de dados.** É terminal e arquivo de texto.
- **O jogo da velha não tem computador para jogar contra** — são dois humanos no mesmo
  teclado.
- **A agenda e os gastos não têm edição**, só incluir, listar, buscar e apagar.
