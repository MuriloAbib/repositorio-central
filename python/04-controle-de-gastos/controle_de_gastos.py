"""Controle de gastos do mes, guardado num arquivo CSV.

Cada gasto e uma linha do arquivo gastos.csv com data, categoria,
descricao e valor. O programa lanca gastos, lista o mes e fecha um
relatorio somando por categoria.
"""

import csv
from datetime import date, datetime
from pathlib import Path

ARQUIVO = Path(__file__).with_name("gastos.csv")
COLUNAS = ["data", "categoria", "descricao", "valor"]

CATEGORIAS = ["mercado", "transporte", "moradia", "lazer", "saude", "outros"]


def carregar_gastos():
    """Le o CSV e devolve uma lista de dicionarios, com valor em float."""
    if not ARQUIVO.exists():
        return []

    gastos = []
    with open(ARQUIVO, "r", encoding="utf-8", newline="") as arquivo:
        for linha in csv.DictReader(arquivo):
            try:
                linha["valor"] = float(linha["valor"])
            except (TypeError, ValueError):
                # Linha estragada no arquivo: aviso e sigo com as outras.
                print(f"Pulei uma linha com valor invalido: {linha}")
                continue
            gastos.append(linha)
    return gastos


def salvar_gastos(gastos):
    """Reescreve o CSV inteiro com a lista de gastos."""
    with open(ARQUIVO, "w", encoding="utf-8", newline="") as arquivo:
        escritor = csv.DictWriter(arquivo, fieldnames=COLUNAS)
        escritor.writeheader()
        for gasto in gastos:
            escritor.writerow(gasto)


def em_reais(valor):
    """Formata 1234.5 como 'R$ 1.234,50'."""
    texto = f"{valor:,.2f}"
    # O Python escreve 1,234.50 (padrao americano). Troco os separadores.
    texto = texto.replace(",", "#").replace(".", ",").replace("#", ".")
    return f"R$ {texto}"


def pedir_data():
    """Pede a data no formato dia/mes/ano. Enter vale como hoje."""
    while True:
        resposta = input("Data (dd/mm/aaaa, Enter para hoje): ").strip()

        if not resposta:
            return date.today().isoformat()

        try:
            dia = datetime.strptime(resposta, "%d/%m/%Y").date()
            return dia.isoformat()
        except ValueError:
            print("Data invalida. Escreva assim: 09/11/2026.")


def pedir_categoria():
    """Mostra as categorias e aceita o numero de uma delas."""
    print("Categorias:")
    for numero, categoria in enumerate(CATEGORIAS, start=1):
        print(f"  {numero} - {categoria}")

    while True:
        resposta = input("Numero da categoria: ").strip()
        if resposta.isdigit() and 1 <= int(resposta) <= len(CATEGORIAS):
            return CATEGORIAS[int(resposta) - 1]
        print(f"Escolha um numero de 1 a {len(CATEGORIAS)}.")


def pedir_valor():
    """Pede o valor aceitando virgula ou ponto, e recusa zero ou negativo."""
    while True:
        resposta = input("Valor (ex: 42,90): ").strip().replace(",", ".")
        try:
            valor = float(resposta)
        except ValueError:
            print("Digite so o numero, como 42,90.")
            continue

        if valor <= 0:
            print("O valor tem que ser maior que zero.")
            continue

        return round(valor, 2)


def lancar(gastos):
    """Pergunta os dados de um gasto novo e grava no CSV."""
    print("\n--- Novo gasto ---")
    novo = {
        "data": pedir_data(),
        "categoria": pedir_categoria(),
        "descricao": input("Descricao: ").strip() or "sem descricao",
        "valor": pedir_valor(),
    }

    gastos.append(novo)
    salvar_gastos(gastos)
    print(f"Lancado: {novo['descricao']} - {em_reais(novo['valor'])}")


def listar(gastos):
    """Lista todos os gastos, do mais antigo para o mais novo."""
    if not gastos:
        print("\nNenhum gasto lancado ainda.")
        return

    print(f"\n--- {len(gastos)} lancamento(s) ---")
    for gasto in sorted(gastos, key=lambda g: g["data"]):
        dia = datetime.strptime(gasto["data"], "%Y-%m-%d").strftime("%d/%m/%Y")
        print(f"{dia}  {gasto['categoria']:<12} {gasto['descricao']:<22} {em_reais(gasto['valor']):>14}")

    total = sum(gasto["valor"] for gasto in gastos)
    print(f"{'TOTAL':>47} {em_reais(total):>14}")


def relatorio(gastos):
    """Soma por categoria e mostra quanto por cento cada uma pesa."""
    if not gastos:
        print("\nNenhum gasto lancado ainda.")
        return

    # Dicionario categoria -> soma dos valores.
    por_categoria = {}
    for gasto in gastos:
        categoria = gasto["categoria"]
        por_categoria[categoria] = por_categoria.get(categoria, 0) + gasto["valor"]

    total = sum(por_categoria.values())

    print("\n--- Gasto por categoria ---")
    # Da categoria mais cara para a mais barata.
    for categoria, soma in sorted(por_categoria.items(), key=lambda item: item[1], reverse=True):
        fatia = soma / total * 100
        barra = "#" * round(fatia / 5)
        print(f"{categoria:<12} {em_reais(soma):>13}  {fatia:5.1f}%  {barra}")

    print(f"{'TOTAL':<12} {em_reais(total):>13}")
    print(f"Media por lancamento: {em_reais(total / len(gastos))}")


def mostrar_menu():
    print("\n=== CONTROLE DE GASTOS ===")
    print("1 - Lancar gasto")
    print("2 - Ver todos os lancamentos")
    print("3 - Relatorio por categoria")
    print("4 - Sair")


def main():
    gastos = carregar_gastos()

    while True:
        mostrar_menu()
        opcao = input("Escolha uma opcao: ").strip()

        if opcao == "1":
            lancar(gastos)
        elif opcao == "2":
            listar(gastos)
        elif opcao == "3":
            relatorio(gastos)
        elif opcao == "4":
            print("Ate a proxima!")
            break
        else:
            print("Opcao invalida, escolha de 1 a 4.")


if __name__ == "__main__":
    main()
