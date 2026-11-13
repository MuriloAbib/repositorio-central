# Jogo da velha

Jogo da velha de terminal para dois jogadores no mesmo teclado. O X começa, os jogadores
escolhem a casa pelo número, e o programa avisa quem fechou linha ou se deu empate.

## Rodar

```bash
python jogo_da_velha.py
```

## Como é a partida

As casas vazias mostram o próprio número, então não precisa decorar a numeração:

```
=== JOGO DA VELHA ===
O X comeca. Boa partida!

 1 | 2 | 3
---+---+---
 4 | 5 | 6
---+---+---
 7 | 8 | 9

Jogador X, escolha uma casa (1-9): 5

 1 | 2 | 3
---+---+---
 4 | X | 6
---+---+---
 7 | 8 | 9

Jogador O, escolha uma casa (1-9): 5
Essa casa ja foi usada. Escolha outra.
Jogador O, escolha uma casa (1-9): 1
```

No fim:

```
 X | X | X
---+---+---
 O | O | 6
---+---+---
 7 | 8 | 9

O jogador X venceu!

Jogar outra partida? (s/n)
```

## O que eu aprendi fazendo

**O tabuleiro é uma lista de 9 posições, não uma matriz 3x3.** Comecei com lista de listas
e vi que complicava tudo: a jogada do usuário é um número de 1 a 9, e com lista simples a
conversão é só `posicao = casa - 1`. Quem precisa das linhas e colunas é só o desenho, e
lá eu calculo com `linha * 3 + coluna`.

**As condições de vitória são dado, não código.** A primeira versão tinha um `if` gigante
comparando casa por casa. Troquei por uma lista de tuplas no topo do arquivo:

```python
LINHAS_QUE_VENCEM = [
    (0, 1, 2), (3, 4, 5), (6, 7, 8),   # horizontais
    (0, 3, 6), (1, 4, 7), (2, 5, 8),   # verticais
    (0, 4, 8), (2, 4, 6),              # diagonais
]
```

E a checagem virou um `for` de três linhas. Oito regras numa estrutura que eu leio de
relance, em vez de oito `if` que eu tenho que conferir um por um.

**Validar a entrada em função separada.** `pedir_jogada` só devolve quando a resposta é
número, está entre 1 e 9 e a casa está livre. Com isso o laço principal do jogo não tem
nenhum `if` de erro de digitação — ele confia no que recebe.

**A troca de turno em uma linha:** `jogador = "O" if jogador == "X" else "X"`.

## Funções do arquivo

| Função | O que faz |
|---|---|
| `criar_tabuleiro()` | devolve a lista de 9 casas vazias |
| `mostrar_tabuleiro(tabuleiro)` | desenha o tabuleiro com as casas vazias numeradas |
| `procurar_vencedor(tabuleiro)` | devolve `"X"`, `"O"` ou `None` |
| `tabuleiro_cheio(tabuleiro)` | `True` quando acabaram as casas |
| `pedir_jogada(tabuleiro, jogador)` | insiste até receber uma casa válida e livre |
| `jogar()` | roda uma partida inteira |
| `main()` | pergunta se quer jogar de novo |

## Próximo passo

Fazer o computador jogar. A ideia é começar pelo nível bobo (sortear uma casa livre com
`random.choice`) e depois tentar o nível que bloqueia: antes de sortear, olhar
`LINHAS_QUE_VENCEM` e ver se tem alguma com duas casas do adversário e uma vazia.
