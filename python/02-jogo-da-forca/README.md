# Jogo da forca

Forca de terminal. O programa sorteia uma palavra de uma lista de dez, mostra os traços e
vai desenhando o boneco a cada erro. São seis erros até enforcar.

## Rodar

```bash
python jogo_da_forca.py
```

## Como é a partida

```
=== JOGO DA FORCA ===
A palavra tem 7 letras. Voce pode errar 6 vezes.

     +---+
     O   |
     |   |
         |
    =====

_ _ _ _ e _ e
Letras erradas: a, b
Chute uma letra: s
Boa, tem 's'.
```

Perdendo:

```
     +---+
     O   |
    /|\  |
    / \  |
    =====

_ _ _ _ e _ e
Letras erradas: a, b, c, d, f, g

Enforcado. A palavra era 'sorvete'.
```

## O que eu aprendi fazendo

**`set` é a estrutura certa para "letras que eu já tentei".** Guardo dois conjuntos,
`acertadas` e `erradas`. Com isso três coisas saem quase de graça:

- descobrir se a pessoa repetiu uma letra: `letra in ja_tentadas`;
- saber se ganhou: `set(palavra) == acertadas` — compara os conjuntos, e nem preciso contar
  quantas letras faltam nem me preocupar com letra repetida na palavra ("cachorro" tem três
  `o`, e o conjunto trata como uma);
- contar os erros para escolher o desenho: `len(erradas)`.

Minha primeira versão usava lista e um contador de erros separado. O contador saía de
sincronia com a lista em algum caminho do código. Com `set` não existe contador para
desincronizar: o número de erros **é** o tamanho do conjunto.

**Os sete desenhos são uma lista indexada pelo número de erros.** `BONECOS[len(erradas)]`
escolhe o boneco certo, sem nenhum `if`. O índice 0 é a forca vazia e o 6 é o boneco
completo — por isso a lista tem sete itens para seis erros.

**Texto com `\` precisa de raw string.** Os braços do boneco (`/|\`) fizeram o Python
soltar `SyntaxWarning: invalid escape sequence`, porque `\ ` não é escape que ele conheça.
A correção foi marcar os desenhos como `r"""..."""`: em raw string a barra invertida é só
uma barra invertida.

**Acento no meio do caminho.** Se a palavra sorteada é "função" e a pessoa digita `c`, o
`ç` não bate. Resolvi normalizando com `unicodedata`: `tirar_acento` quebra a letra
acentuada em letra + acento (`NFD`) e joga o acento fora. Passo a palavra e o chute pela
mesma função, então os dois são comparados na mesma régua.

## Funções do arquivo

| Função | O que faz |
|---|---|
| `tirar_acento(texto)` | `"funcao"` a partir de `"função"` |
| `sortear_palavra()` | escolhe da lista, sem acento e em minúsculo |
| `montar_tracos(palavra, acertadas)` | `"_ _ r _ e"` com o que já foi acertado |
| `pedir_letra(ja_tentadas)` | insiste até vir uma letra nova e válida |
| `jogar()` | roda uma partida |
| `main()` | pergunta se quer jogar de novo |

## Próximo passo

Tirar as palavras de dentro do código e ler de um `palavras.txt`, uma por linha — é o que
permite aumentar a lista sem mexer no programa. Depois, dificuldade por tamanho de palavra.
