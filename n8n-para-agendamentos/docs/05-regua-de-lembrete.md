# A régua de lembrete, e por que ela é uma decisão de preço

## A regra

Decidida na reunião de **27/08/2026**. Está implementada em um único lugar:
`agendar_lembrete`, em `../sql/0011-gatilhos-e-regua.sql`.

```
agendamento com início a MAIS de 2h    ->  lembrete em (início - 2h)
agendamento com início em 2h ou menos  ->  lembrete AGORA
```

A segunda perna não é caso de borda, é a metade do produto: barbearia recebe
muito agendamento em cima da hora, e "avisa 2h antes" aplicado a um corte que
é em 40 minutos significa não avisar nunca.

```sql
if v_inicio - now() > interval '2 hours' then
  v_disparar := v_inicio - interval '2 hours';
else
  v_disparar := now();
end if;
```

## Por que ela vive em uma função só

Se a régua existisse em duas cópias — uma na criação, outra na remarcação —
remarcar passaria a usar regra diferente de marcar. O número de mensagens por
agendamento deixaria de ser conhecido, e é exatamente esse número que a
precificação do produto depende.

A mesma preocupação está na constraint:

```sql
constraint lembretes_um_por_tipo unique (appointment_id, tipo)
```

`agendar_lembrete` faz `ON CONFLICT ... DO UPDATE`: remarcar **reaproveita** a
linha em vez de criar outra. Cliente que remarca três vezes continua gerando
**uma** mensagem de lembrete, no horário certo da última marcação.

O `DO UPDATE` também ressuscita lembrete já enviado ou cancelado (`status` volta
a `pendente`, `tentativas` zera). É deliberado: quem remarcou precisa ser
avisado do horário **novo**, mesmo tendo confirmado o antigo. Zerar `tentativas`
evita herdar o retry da linha anterior.

## O vínculo com preço

Régua e precificação são **o mesmo problema visto de dois lados**. A régua fixa
o número de mensagens por agendamento; esse número multiplica o custo por
mensagem; esse produto é o custo variável do SaaS.

Com a régua atual:

```
mensagens por agendamento = 1 (lembrete ao cliente)
                          + 1 (aviso ao barbeiro, fluxo B)
                          + 0 ou 1 (resposta à confirmação sim/não)
```

Chamando de **C** o custo por mensagem de WhatsApp e **E** o custo por e-mail:

```
custo variável por agendamento ≈ 2·C      (cliente e barbeiro no WhatsApp)
                               ≈ C + E    (cliente por e-mail, barbeiro no WhatsApp)
                               ≈ 2·E      (os dois por e-mail)
```

**C não está preenchido aqui de propósito.** O vault registra que o custo por
mensagem ainda não foi negociado com fornecedor (tarefa T10 do backlog de
27/08/2026) e que é esse número que **trava** as frentes de preço de mercado,
viabilidade e fórmula de precificação. Inventar um valor neste documento
produziria uma conta que parece fechada e não está.

O que o vault registra sobre a ordem de grandeza: **e-mail é cerca de cem vezes
mais barato que mensagem.** Ou seja `E ≈ C/100`. A consequência é estrutural, não
marginal: se o cliente final escolhe o canal, o custo variável deixa de ser
constante por agendamento e passa a ter **duas curvas**, e a mistura entre elas
vira uma variável de negócio — não um detalhe técnico.

## O canal hoje, e o que falta

O schema real do BarberBook **não tem** coluna de preferência de canal. A regra
implementada em `contexto_do_agendamento` é a aproximação possível:

```sql
'canal', case when pc.phone is not null then 'whatsapp' else 'email' end
```

WhatsApp se houver telefone, senão e-mail. Isso **não** é escolha do cliente — é
consequência de ele ter preenchido o telefone ou não, o que não é a mesma coisa.

Para virar escolha de verdade falta uma coluna (`profiles.canal_preferido`, ou
equivalente) e um controle na área do cliente. Quando existir, é **só nessa
linha** que muda — é por isso que a regra está centralizada ali e não espalhada
pelos workflows.

## O relógio durável: tabela e poller, não o nó Wait

O n8n tem nó `Wait`, e seria tentador pôr `Wait` de 2h no fluxo.

Não serve. Um `Wait` vive **dentro de uma execução**. Execução perdida — restart
do container, redeploy, limpeza de histórico, queda do worker — é lembrete que
nunca dispara, e ninguém fica sabendo. O vault já registra isso como requisito
de infraestrutura: *"a régua outbound exige um relógio durável — algo que lembre
de disparar mesmo depois de o servidor reiniciar. Isso é infraestrutura, não
código de aplicação."*

A linha em `lembretes` sobrevive a tudo isso, e tem uma segunda propriedade que
o `Wait` não tem: é **auditável**. Dá para perguntar ao banco o que deveria ter
saído e não saiu:

```sql
select * from lembretes
 where status = 'pendente' and disparar_em < now() - interval '15 minutes';
```

É a coluna `lembretes_atrasados` da view `automacao_saude`.

## Por que o poller roda a cada 5 minutos, e não a cada 1

A régua é "avisa 2h antes". Cinco minutos de imprecisão em cima de duas horas é
irrelevante para o cliente, e corta ~80% das execuções em relação a rodar a cada
minuto.

Isso importa porque **foi o custo por execução que decidiu n8n self-hosted em vez
de Make ou Zapier**: a régua é alto volume de tarefa barata, e plataforma que
cobra por operação tem modelo econômico ruim para esse perfil. Mesmo
self-hosted, execução custa CPU — e um poller de 1 minuto rodando para sempre
numa fila quase sempre vazia é desperdício permanente.

O fluxo B (aviso ao barbeiro) roda a cada **1 minuto**, não 5, porque ali a
latência é o produto: o barbeiro quer saber que entrou horário agora, não em
cinco minutos.

## O que muda se a régua ganhar um segundo lembrete

Hipótese provável: T-24h além de T-2h.

| | Hoje | Com T-24h |
|---|---|---|
| mensagens de lembrete por agendamento | 1 | 1 ou 2 |
| custo variável | ~2·C | ~3·C |
| agendamento marcado com <24h | — | só recebe o de 2h |

O "1 ou 2" é o problema: agendamento marcado para amanhã recebe dois; marcado
para hoje recebe um. O custo por agendamento deixa de ser um número e passa a
ser uma média que depende da distribuição de antecedência — que ninguém mediu
ainda.

Implementação, se for decidido: `tipo` em `lembretes` já aceita `'lembrete'`
além de `'confirmacao'`, e a constraint é por `(appointment_id, tipo)` — então a
segunda linha cabe sem mudança de schema. O que muda é `agendar_lembrete`, e
**só ela**.

**Antes de mexer:** o portão registrado no vault é um agendamento de ponta a
ponta em barbearia real com o **no-show medido**. Sem o no-show medido não há
como saber se o segundo lembrete reduz falta ou só aumenta custo — e é essa a
promessa que a landing faz.
