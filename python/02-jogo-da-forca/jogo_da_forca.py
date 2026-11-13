"""Jogo da forca no terminal, com uma lista de palavras fixa.

O programa sorteia uma palavra, mostra os tracos e vai preenchendo as
letras acertadas. Sao seis erros permitidos, um por parte do boneco.
"""

import random
import unicodedata

PALAVRAS = [
    "python",
    "teclado",
    "programa",
    "funcao",
    "variavel",
    "biblioteca",
    "terminal",
    "sorvete",
    "cachorro",
    "abacaxi",
]

MAXIMO_DE_ERROS = 6

# Um desenho para cada quantidade de erro (0 a 6).
BONECOS = [
    r"""
     +---+
         |
         |
         |
    =====""",
    r"""
     +---+
     O   |
         |
         |
    =====""",
    r"""
     +---+
     O   |
     |   |
         |
    =====""",
    r"""
     +---+
     O   |
    /|   |
         |
    =====""",
    r"""
     +---+
     O   |
    /|\  |
         |
    =====""",
    r"""
     +---+
     O   |
    /|\  |
    /    |
    =====""",
    r"""
     +---+
     O   |
    /|\  |
    / \  |
    =====""",
]


def tirar_acento(texto):
    """Troca 'a' com acento por 'a' simples, para comparar as letras."""
    sem_acento = unicodedata.normalize("NFD", texto)
    return "".join(letra for letra in sem_acento if not unicodedata.combining(letra))


def sortear_palavra():
    """Escolhe uma palavra da lista, sem acento e em minusculo."""
    return tirar_acento(random.choice(PALAVRAS)).lower()


def montar_tracos(palavra, acertadas):
    """Mostra a palavra com as letras acertadas e tracos no resto."""
    mostrar = []
    for letra in palavra:
        if letra in acertadas:
            mostrar.append(letra)
        else:
            mostrar.append("_")
    return " ".join(mostrar)


def pedir_letra(ja_tentadas):
    """Pergunta uma letra ate vir uma letra nova e valida."""
    while True:
        chute = input("Chute uma letra: ").strip().lower()
        chute = tirar_acento(chute)

        if len(chute) != 1:
            print("Mande uma letra so.")
            continue

        if not chute.isalpha():
            print("Numero e simbolo nao valem, so letra.")
            continue

        if chute in ja_tentadas:
            print(f"Voce ja tentou '{chute}'. Escolha outra.")
            continue

        return chute


def jogar():
    """Roda uma partida da forca."""
    palavra = sortear_palavra()
    acertadas = set()
    erradas = set()

    print("=== JOGO DA FORCA ===")
    print(f"A palavra tem {len(palavra)} letras. Voce pode errar {MAXIMO_DE_ERROS} vezes.")

    while True:
        print(BONECOS[len(erradas)])
        print("\n" + montar_tracos(palavra, acertadas))

        if erradas:
            print("Letras erradas: " + ", ".join(sorted(erradas)))

        # Venceu quando toda letra da palavra ja esta no conjunto de acertos.
        if set(palavra) == acertadas:
            print(f"\nVoce ganhou! A palavra era '{palavra}'.")
            return

        if len(erradas) == MAXIMO_DE_ERROS:
            print(f"\nEnforcado. A palavra era '{palavra}'.")
            return

        letra = pedir_letra(acertadas | erradas)

        if letra in palavra:
            acertadas.add(letra)
            print(f"Boa, tem '{letra}'.")
        else:
            erradas.add(letra)
            restam = MAXIMO_DE_ERROS - len(erradas)
            print(f"Nao tem '{letra}'. Ainda da para errar {restam} vez(es).")


def main():
    while True:
        jogar()
        de_novo = input("\nJogar de novo? (s/n) ").strip().lower()
        if de_novo != "s":
            print("Ate a proxima!")
            break


if __name__ == "__main__":
    main()
