# Gerador e conferidor de senha

Duas coisas num programa de terminal: sortear senha com o tamanho e os tipos de caractere
que a pessoa pedir, e dar uma nota de 0 a 5 para uma senha que ela já usa, dizendo o que
pesou contra.

## Rodar

```bash
python gerador_de_senha.py
```

## Como é o uso

```
=== SENHAS ===
1 - Gerar senha
2 - Conferir a forca de uma senha
3 - Sair
Escolha uma opcao: 1

--- Gerar senha ---
Tamanho (Enter para 16):
Usar MAIUSCULA? (S/n)
Usar numero? (S/n)
Usar simbolo? (S/n)
Tirar caractere parecido (l, 1, O, 0)? (s/N)

Escolha uma destas:
  u7Ie%d-GqAx3hV2m
  T4w$yNk8rFm-2cQb
  9pHs=R3vLx6nDa%w

Nota: [*****] 5/5 - boa
Nao achei o que reclamar nessa.
```

Gera três opções porque senha é coisa que a gente olha e rejeita — escolher entre três é
mais rápido que apertar "gerar" de novo.

Conferindo uma senha:

```
Senha que voce quer testar: 123456

Nota: [-----] 0/5 - fraca
O que pesou contra:
  - tem menos de 8 caracteres, isso e curto demais
  - falta misturar maiuscula e minuscula
  - nao tem simbolo
  - essa senha esta em qualquer lista de senha comum
```

## O que eu aprendi fazendo

**`secrets` em vez de `random`.** Foi a coisa mais importante que aprendi neste projeto. O
`random` serve para jogo e sorteio: ele é um gerador pseudoaleatório, e quem descobre o
estado interno dele consegue prever o que vem depois. Para senha existe o módulo `secrets`,
que puxa aleatoriedade do sistema operacional. A troca é só `random.choice` →
`secrets.choice`, e é a diferença entre uma senha e uma senha que parece aleatória.

Para embaralhar eu precisei de `secrets.SystemRandom().shuffle(...)`, porque `secrets` não
tem `shuffle` próprio — `SystemRandom` é a classe com a mesma interface do `random`, mas
usando a fonte segura.

**Sorteio sozinho não garante o que foi pedido.** Minha primeira versão montava o alfabeto
com tudo e sorteava N caracteres dele. Testei umas vezes e saiu senha de 8 sem nenhum
número — não é bug de código, é o sorteio sendo sorteio. A correção foi garantir **um
caractere de cada grupo escolhido primeiro**, preencher o resto com o alfabeto inteiro e só
então embaralhar. O embaralhamento no fim é obrigatório: sem ele os obrigatórios ficariam
sempre nas primeiras posições, e aí a senha teria um padrão.

**Função que devolve duas coisas.** `avaliar_senha` devolve `(nota, problemas)` — o número
e a lista de reclamações. Quem imprime é outra função (`mostrar_avaliacao`). Separei porque
`avaliar_senha` não imprime nada, só calcula, e isso é o que a deixaria fácil de testar com
`pytest` depois.

**`any()` com generator.** Verificar se tem número é `any(c.isdigit() for c in senha)`. Era
um `for` com `break` e uma variável `tem_numero = False` na versão anterior; virou uma
linha que se lê como a frase "algum caractere é dígito?".

**`string.ascii_lowercase` já existe.** Eu tinha digitado o alfabeto na mão. O módulo
`string` tem `ascii_lowercase`, `ascii_uppercase`, `digits` e `punctuation` prontos. Usei
uma lista própria de símbolos em vez de `punctuation` porque muito site recusa alguns
sinais, então deixei só os aceitos em quase todo lugar.

**Caractere parecido é problema real.** `l`, `1`, `I`, `O` e `0` viram erro de digitação
quando a senha é lida de um papel ou ditada no telefone. Daí a opção de tirar — ela encurta
o alfabeto, o que enfraquece um pouco a senha, e a compensação é usar um tamanho maior.

**Senha comum zera a nota.** `"Qwerty123!"` marcaria ponto em quase todo critério, mas está
em qualquer lista de ataque. Então a checagem de senha manjada roda no fim e sobrescreve a
nota com 0 — regra que anula as outras tem que vir depois delas.

## Funções do arquivo

| Função | O que faz |
|---|---|
| `montar_alfabeto(...)` | junta os grupos escolhidos; devolve o alfabeto e os grupos |
| `gerar_senha(tamanho, ...)` | sorteia garantindo um caractere de cada tipo pedido |
| `avaliar_senha(senha)` | devolve `(nota, problemas)` |
| `mostrar_avaliacao(senha)` | imprime a nota em estrelas e as reclamações |
| `perguntar_sim_ou_nao(...)` | pergunta s/n com valor padrão no Enter |
| `pedir_tamanho()` | valida o tamanho entre 4 e 64 |

As funções `gerar_senha` e `avaliar_senha` não leem teclado nem imprimem nada, então dá
para importar as duas de outro arquivo e usar:

```python
from gerador_de_senha import gerar_senha, avaliar_senha

print(gerar_senha(20))
print(avaliar_senha("minha-senha-123"))
```

## O que este programa não é

A nota de 0 a 5 é uma regrinha de bolso, não medida de segurança de verdade. A medida certa
é entropia (quantos bits de incerteza a senha tem) e consulta a vazamento conhecido. Uma
senha pode tirar 5/5 aqui e ainda ser ruim se for uma frase previsível com símbolo no fim.
Deixo claro porque conferidor de senha que promete mais do que mede é pior que nenhum.

## Próximo passo

Senha em palavras (`cavalo-bateria-grampo-azul`): mais fácil de lembrar e digitar, e mais
forte que senha curta cheia de símbolo, porque o que manda é o tamanho. Precisa de uma
lista de palavras, que é o que o projeto da forca já me ensinou a carregar.
