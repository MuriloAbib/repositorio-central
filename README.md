# Repositório Central

Repositório único que reúne e organiza por tema os materiais que estavam
espalhados em repositórios separados nesta conta.

## Desenvolvimento

- [Automação de Atendimento (Sorvebot)](automacao-de-atendimento/) — motor de atendimento e vendas no WhatsApp que responde a maior parte das mensagens **sem chamar LLM**: cascata de quatro camadas (guardas em código, memória destilada, busca local por palavras-chave e funil determinístico), com o modelo como último recurso. Arquitetura, decisões de engenharia, guardas de segurança da conversa e suíte de 683 testes. Python/FastAPI/PostgreSQL + React.
- [Automação de rodízio de número de WhatsApp](automacao-rodizio-whatsapp/) —
  distribuição automática e justa de leads entre vários consultores de vendas,
  com contador global atômico no PostgreSQL. Código **de produção** extraído e
  documentado: cinco arquivos comentados linha a linha, o caminho completo de um
  clique, dez decisões de engenharia com o bug que cada uma evita, e um guia de
  implementação do zero. **Stack:** PostgreSQL · TanStack Start · React 19 ·
  TypeScript · Supabase.
- [n8n-automacoes-basicas — três automações básicas no n8n](n8n-automacoes-basicas/) — laboratório de introdução ao n8n: webhook que recebe lead, monitor agendado com alerta no Telegram e API de frete com enriquecimento por CEP. Workflows exportados, passo a passo e glossário.
- [Python — cinco projetos de estudo](python/) — programas pequenos de terminal, só com a biblioteca padrão: jogo da velha, jogo da forca, agenda em JSON, controle de gastos em CSV e gerador de senha. Um README por projeto, com o que foi treinado nele e por que cada decisão foi tomada.

## Formação

- [Inovação, Sustentabilidade e Competitividade](inovacao-sustentabilidade-competitividade/) — atividades práticas, projeto final e referências da unidade curricular ISCE (RA 823219068).
- [N8N para agendamentos](n8n-para-agendamentos/) — automação de atendimento do FastChair/BarberBook: webhook de pagamento que provisiona o usuário, aviso no WhatsApp do barbeiro a cada agendamento e régua de lembrete do cliente, orquestrados em n8n self-hosted sobre o Supabase.
