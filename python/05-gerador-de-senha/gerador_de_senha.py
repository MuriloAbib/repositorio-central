"""Gerador e conferidor de senha.

Duas coisas num programa so: sortear uma senha com o tamanho e os tipos
de caractere que a pessoa pedir, e dar uma nota para uma senha que ela
ja usa, explicando o que falta.

Uso o modulo secrets em vez de random porque secrets e o sorteio feito
para senha: o random e previsivel se alguem descobrir a semente.
"""

import secrets
import string

TAMANHO_MINIMO = 4
TAMANHO_PADRAO = 16

# Caracteres que confundem na hora de ler ou digitar a senha.
PARECIDOS = "il1LoO0"

SIMBOLOS = "!@#$%&*?-_+="

# As senhas que todo mundo tenta primeiro. Nao e uma lista completa,
# e so para pegar o caso obvio.
SENHAS_MANJADAS = [
    "123456",
    "123456789",
    "senha",
    "password",
    "qwerty",
    "abc123",
    "admin",
    "12345678",
    "brasil",
    "futebol",
]


def montar_alfabeto(com_maiuscula, com_numero, com_simbolo, sem_parecidos):
    """Junta os grupos de caractere escolhidos numa lista de sorteio.

    Devolve (alfabeto, grupos): o alfabeto e tudo que pode sair, e grupos
    e a lista de cada tipo escolhido, para garantir um caractere de cada.
    """
    grupos = [string.ascii_lowercase]

    if com_maiuscula:
        grupos.append(string.ascii_uppercase)
    if com_numero:
        grupos.append(string.digits)
    if com_simbolo:
        grupos.append(SIMBOLOS)

    if sem_parecidos:
        limpos = []
        for grupo in grupos:
            limpo = "".join(c for c in grupo if c not in PARECIDOS)
            limpos.append(limpo)
        grupos = limpos

    alfabeto = "".join(grupos)
    return alfabeto, grupos


def gerar_senha(tamanho, com_maiuscula=True, com_numero=True, com_simbolo=True, sem_parecidos=False):
    """Sorteia uma senha com pelo menos um caractere de cada tipo pedido."""
    alfabeto, grupos = montar_alfabeto(com_maiuscula, com_numero, com_simbolo, sem_parecidos)

    if tamanho < len(grupos):
        # Nao caberia um caractere de cada tipo na senha.
        raise ValueError(f"O tamanho precisa ser pelo menos {len(grupos)} para esses tipos.")

    # Um de cada grupo primeiro, para nao sair senha sem numero quando
    # o sorteio der azar. O resto vem do alfabeto todo.
    letras = [secrets.choice(grupo) for grupo in grupos]
    while len(letras) < tamanho:
        letras.append(secrets.choice(alfabeto))

    # Embaralha para os obrigatorios nao ficarem sempre no comeco.
    secrets.SystemRandom().shuffle(letras)
    return "".join(letras)


def avaliar_senha(senha):
    """Da uma nota de 0 a 5 para a senha e lista o que esta faltando.

    Devolve (nota, problemas).
    """
    problemas = []
    nota = 0

    if len(senha) >= 12:
        nota += 2
    elif len(senha) >= 8:
        nota += 1
        problemas.append("tem menos de 12 caracteres")
    else:
        problemas.append("tem menos de 8 caracteres, isso e curto demais")

    if any(c.islower() for c in senha) and any(c.isupper() for c in senha):
        nota += 1
    else:
        problemas.append("falta misturar maiuscula e minuscula")

    if any(c.isdigit() for c in senha):
        nota += 1
    else:
        problemas.append("nao tem numero")

    if any(not c.isalnum() for c in senha):
        nota += 1
    else:
        problemas.append("nao tem simbolo")

    # Senha manjada perde tudo, nao importa o resto.
    if senha.lower() in SENHAS_MANJADAS:
        problemas.append("essa senha esta em qualquer lista de senha comum")
        nota = 0

    return nota, problemas


def mostrar_avaliacao(senha):
    """Imprime a nota em estrelas e o que precisa melhorar."""
    nota, problemas = avaliar_senha(senha)

    estrelas = "*" * nota + "-" * (5 - nota)
    if nota <= 1:
        recado = "fraca"
    elif nota <= 3:
        recado = "mais ou menos"
    else:
        recado = "boa"

    print(f"\nNota: [{estrelas}] {nota}/5 - {recado}")

    if problemas:
        print("O que pesou contra:")
        for problema in problemas:
            print(f"  - {problema}")
    else:
        print("Nao achei o que reclamar nessa.")


def perguntar_sim_ou_nao(pergunta, padrao=True):
    """Pergunta s/n. Enter aceita o padrao."""
    sugestao = "S/n" if padrao else "s/N"
    while True:
        resposta = input(f"{pergunta} ({sugestao}) ").strip().lower()

        if not resposta:
            return padrao
        if resposta in ("s", "sim"):
            return True
        if resposta in ("n", "nao"):
            return False

        print("Responda s ou n.")


def pedir_tamanho():
    """Pede o tamanho da senha. Enter usa o padrao."""
    while True:
        resposta = input(f"Tamanho (Enter para {TAMANHO_PADRAO}): ").strip()

        if not resposta:
            return TAMANHO_PADRAO

        if not resposta.isdigit():
            print("Digite so o numero.")
            continue

        tamanho = int(resposta)
        if tamanho < TAMANHO_MINIMO:
            print(f"Muito curta. O minimo aqui e {TAMANHO_MINIMO}.")
            continue
        if tamanho > 64:
            print("Passou de 64 fica dificil de usar. Escolha menos.")
            continue

        return tamanho


def fluxo_gerar():
    """Pergunta as opcoes e mostra as senhas sorteadas."""
    print("\n--- Gerar senha ---")
    tamanho = pedir_tamanho()
    com_maiuscula = perguntar_sim_ou_nao("Usar MAIUSCULA?")
    com_numero = perguntar_sim_ou_nao("Usar numero?")
    com_simbolo = perguntar_sim_ou_nao("Usar simbolo?")
    sem_parecidos = perguntar_sim_ou_nao("Tirar caractere parecido (l, 1, O, 0)?", padrao=False)

    try:
        senhas = [
            gerar_senha(tamanho, com_maiuscula, com_numero, com_simbolo, sem_parecidos)
            for _ in range(3)
        ]
    except ValueError as erro:
        print(f"Nao deu para gerar: {erro}")
        return

    print("\nEscolha uma destas:")
    for senha in senhas:
        print(f"  {senha}")

    mostrar_avaliacao(senhas[0])


def fluxo_avaliar():
    """Confere a senha que a pessoa digitar."""
    print("\n--- Conferir senha ---")
    senha = input("Senha que voce quer testar: ").strip()

    if not senha:
        print("Nao digitou nada.")
        return

    mostrar_avaliacao(senha)


def mostrar_menu():
    print("\n=== SENHAS ===")
    print("1 - Gerar senha")
    print("2 - Conferir a forca de uma senha")
    print("3 - Sair")


def main():
    while True:
        mostrar_menu()
        opcao = input("Escolha uma opcao: ").strip()

        if opcao == "1":
            fluxo_gerar()
        elif opcao == "2":
            fluxo_avaliar()
        elif opcao == "3":
            print("Fechando.")
            break
        else:
            print("Opcao invalida, escolha de 1 a 3.")


if __name__ == "__main__":
    main()
