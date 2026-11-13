"""Agenda de contatos que salva tudo num arquivo JSON.

Menu de terminal para listar, adicionar, buscar e apagar contato. Cada
contato e um dicionario com nome, telefone e email, e a agenda inteira e
uma lista desses dicionarios, gravada em contatos.json.
"""

import json
from pathlib import Path

# O arquivo fica na mesma pasta do programa, nao na pasta de onde ele foi
# chamado. Assim a agenda nao "desaparece" se eu rodar de outro lugar.
ARQUIVO = Path(__file__).with_name("contatos.json")


def carregar_contatos():
    """Le o JSON do disco. Se nao existe ainda, devolve lista vazia."""
    if not ARQUIVO.exists():
        return []

    try:
        with open(ARQUIVO, "r", encoding="utf-8") as arquivo:
            return json.load(arquivo)
    except json.JSONDecodeError:
        print("O arquivo contatos.json esta corrompido. Comecando agenda nova.")
        return []


def salvar_contatos(contatos):
    """Grava a lista de contatos no JSON, com acento legivel."""
    with open(ARQUIVO, "w", encoding="utf-8") as arquivo:
        json.dump(contatos, arquivo, indent=2, ensure_ascii=False)


def so_numeros(texto):
    """Devolve apenas os digitos do texto: '(31) 99999-8888' -> '31999998888'."""
    return "".join(letra for letra in texto if letra.isdigit())


def formatar_telefone(telefone):
    """Mostra o telefone bonitinho, com DDD entre parenteses."""
    digitos = so_numeros(telefone)

    if len(digitos) == 11:
        return f"({digitos[:2]}) {digitos[2:7]}-{digitos[7:]}"
    if len(digitos) == 10:
        return f"({digitos[:2]}) {digitos[2:6]}-{digitos[6:]}"

    # Se nao tem o tamanho esperado, mostra como esta.
    return telefone


def pedir_texto(pergunta):
    """Pergunta e insiste enquanto a resposta vier vazia."""
    while True:
        resposta = input(pergunta).strip()
        if resposta:
            return resposta
        print("Nao pode ficar em branco.")


def pedir_telefone():
    """Pede o telefone ate vir com 10 ou 11 digitos (com DDD)."""
    while True:
        resposta = input("Telefone com DDD: ").strip()
        digitos = so_numeros(resposta)

        if len(digitos) in (10, 11):
            return digitos

        print("O telefone precisa ter DDD + numero (10 ou 11 digitos).")


def listar(contatos):
    """Mostra a agenda em ordem alfabetica."""
    if not contatos:
        print("\nA agenda esta vazia.")
        return

    print(f"\n--- {len(contatos)} contato(s) ---")
    for numero, contato in enumerate(sorted(contatos, key=lambda c: c["nome"].lower()), start=1):
        print(f"{numero}. {contato['nome']}")
        print(f"   tel:   {formatar_telefone(contato['telefone'])}")
        print(f"   email: {contato['email']}")


def adicionar(contatos):
    """Monta um contato novo e salva."""
    print("\n--- Novo contato ---")
    nome = pedir_texto("Nome: ")

    # Nome repetido quase sempre e engano, entao aviso antes de duplicar.
    for contato in contatos:
        if contato["nome"].lower() == nome.lower():
            print(f"Ja existe um contato chamado {contato['nome']}. Nao salvei.")
            return

    telefone = pedir_telefone()
    email = pedir_texto("Email: ")

    contatos.append({"nome": nome, "telefone": telefone, "email": email})
    salvar_contatos(contatos)
    print(f"{nome} entrou na agenda.")


def buscar(contatos):
    """Procura por parte do nome ou por parte do telefone."""
    procurado = pedir_texto("\nBuscar por nome ou telefone: ").lower()
    digitos = so_numeros(procurado)

    achados = []
    for contato in contatos:
        bate_nome = procurado in contato["nome"].lower()
        bate_telefone = bool(digitos) and digitos in contato["telefone"]
        if bate_nome or bate_telefone:
            achados.append(contato)

    if not achados:
        print("Ninguem com esse nome ou telefone.")
        return

    print(f"\n{len(achados)} resultado(s):")
    for contato in achados:
        print(f"- {contato['nome']} | {formatar_telefone(contato['telefone'])} | {contato['email']}")


def remover(contatos):
    """Apaga um contato pelo nome exato, confirmando antes."""
    nome = pedir_texto("\nNome do contato que vai sair: ").lower()

    for posicao, contato in enumerate(contatos):
        if contato["nome"].lower() == nome:
            confirma = input(f"Apagar {contato['nome']}? (s/n) ").strip().lower()
            if confirma == "s":
                contatos.pop(posicao)
                salvar_contatos(contatos)
                print("Apagado.")
            else:
                print("Deixei como estava.")
            return

    print("Nao achei esse nome na agenda.")


def mostrar_menu():
    print("\n=== AGENDA DE CONTATOS ===")
    print("1 - Listar todos")
    print("2 - Adicionar contato")
    print("3 - Buscar contato")
    print("4 - Remover contato")
    print("5 - Sair")


def main():
    contatos = carregar_contatos()

    while True:
        mostrar_menu()
        opcao = input("Escolha uma opcao: ").strip()

        if opcao == "1":
            listar(contatos)
        elif opcao == "2":
            adicionar(contatos)
        elif opcao == "3":
            buscar(contatos)
        elif opcao == "4":
            remover(contatos)
        elif opcao == "5":
            print("Agenda salva. Tchau!")
            break
        else:
            print("Opcao invalida, escolha de 1 a 5.")


if __name__ == "__main__":
    main()
