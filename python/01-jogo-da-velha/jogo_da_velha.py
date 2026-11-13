"""Jogo da velha para dois jogadores no mesmo teclado.

Cada jogador escolhe uma casa de 1 a 9 e o programa avisa quem ganhou
ou se deu empate. O tabuleiro e uma lista de 9 posicoes:

    1 | 2 | 3
   ---+---+---
    4 | 5 | 6
   ---+---+---
    7 | 8 | 9
"""

# As oito maneiras de fechar uma linha (tres horizontais, tres verticais,
# duas diagonais), escritas como posicoes da lista.
LINHAS_QUE_VENCEM = [
    (0, 1, 2),
    (3, 4, 5),
    (6, 7, 8),
    (0, 3, 6),
    (1, 4, 7),
    (2, 5, 8),
    (0, 4, 8),
    (2, 4, 6),
]

VAZIO = " "


def criar_tabuleiro():
    """Devolve um tabuleiro novo, com as nove casas vazias."""
    return [VAZIO] * 9


def mostrar_tabuleiro(tabuleiro):
    """Desenha o tabuleiro. Casa vazia mostra o numero dela, para ajudar."""
    print()
    for linha in range(3):
        casas = []
        for coluna in range(3):
            posicao = linha * 3 + coluna
            if tabuleiro[posicao] == VAZIO:
                casas.append(str(posicao + 1))
            else:
                casas.append(tabuleiro[posicao])
        print(" " + " | ".join(casas))
        if linha < 2:
            print("---+---+---")
    print()


def procurar_vencedor(tabuleiro):
    """Devolve 'X', 'O' ou None, se ainda nao tem vencedor."""
    for a, b, c in LINHAS_QUE_VENCEM:
        if tabuleiro[a] != VAZIO and tabuleiro[a] == tabuleiro[b] == tabuleiro[c]:
            return tabuleiro[a]
    return None


def tabuleiro_cheio(tabuleiro):
    """True quando nao sobrou casa vazia."""
    return VAZIO not in tabuleiro


def pedir_jogada(tabuleiro, jogador):
    """Pergunta a casa ate o jogador digitar um numero valido e livre."""
    while True:
        resposta = input(f"Jogador {jogador}, escolha uma casa (1-9): ").strip()

        if not resposta.isdigit():
            print("Digite so o numero da casa, de 1 a 9.")
            continue

        casa = int(resposta)
        if casa < 1 or casa > 9:
            print("A casa precisa estar entre 1 e 9.")
            continue

        posicao = casa - 1
        if tabuleiro[posicao] != VAZIO:
            print("Essa casa ja foi usada. Escolha outra.")
            continue

        return posicao


def jogar():
    """Roda uma partida inteira, do tabuleiro vazio ate o resultado."""
    tabuleiro = criar_tabuleiro()
    jogador = "X"

    print("=== JOGO DA VELHA ===")
    print("O X comeca. Boa partida!")

    while True:
        mostrar_tabuleiro(tabuleiro)

        posicao = pedir_jogada(tabuleiro, jogador)
        tabuleiro[posicao] = jogador

        vencedor = procurar_vencedor(tabuleiro)
        if vencedor is not None:
            mostrar_tabuleiro(tabuleiro)
            print(f"O jogador {vencedor} venceu!")
            break

        if tabuleiro_cheio(tabuleiro):
            mostrar_tabuleiro(tabuleiro)
            print("Deu velha: empate.")
            break

        # Troca a vez.
        jogador = "O" if jogador == "X" else "X"


def main():
    while True:
        jogar()
        de_novo = input("\nJogar outra partida? (s/n) ").strip().lower()
        if de_novo != "s":
            print("Valeu pela partida!")
            break


if __name__ == "__main__":
    main()
