-- =============================================================================
-- 1/5 — O CONTADOR GLOBAL DO RODÍZIO (PostgreSQL / Supabase)
-- =============================================================================
-- Arquivo original no projeto:
--   supabase/migrations/20261002161745_b436fa91-1f39-441a-bf91-661bcd3d31ea.sql
--
-- Esta é a peça central de todo o mecanismo. São 21 linhas, e cada decisão
-- aqui existe por um motivo — veja docs/DECISOES-DE-ENGENHARIA.md.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- A tabela: uma linha por fila de rodízio.
-- -----------------------------------------------------------------------------
-- `id` é texto, não serial: a fila tem NOME ('consultores'). Assim o mesmo
-- mecanismo atende outras filas no futuro (suporte, parceiros, instaladores)
-- sem criar tabela nova nem função nova.
--
-- `contador` é bigint e nunca reseta — é monotônico crescente. O consultor sai
-- de `contador % total_de_consultores`, então o valor absoluto não importa.
CREATE TABLE public.rodizio_estado (
  id         text        PRIMARY KEY,
  contador   bigint      NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Só o servidor mexe nisso. O navegador não lê nem escreve.
GRANT ALL ON public.rodizio_estado TO service_role;

-- RLS ligada SEM nenhuma policy criada = ninguém que use chave pública
-- (anon/authenticated) consegue ler ou escrever. É o "deny all" por omissão.
-- O `service_role` ignora RLS por definição, então o servidor continua passando.
ALTER TABLE public.rodizio_estado ENABLE ROW LEVEL SECURITY;

-- Semeia a fila dos consultores em zero.
INSERT INTO public.rodizio_estado (id, contador) VALUES ('consultores', 0);


-- -----------------------------------------------------------------------------
-- A função: devolve a posição da vez e já avança a fila. Atômica.
-- -----------------------------------------------------------------------------
-- O erro clássico aqui seria SELECT o contador, somar 1 na aplicação e depois
-- UPDATE. Dois cliques no mesmo instante leriam o MESMO valor, receberiam o
-- MESMO consultor, e um consultor seria pulado. Em um site com pico de tráfego
-- depois de um anúncio, isso acontece de verdade.
--
-- A solução é não ter dois passos. `INSERT ... ON CONFLICT DO UPDATE ...
-- RETURNING` é UMA instrução: o PostgreSQL trava a linha, incrementa e devolve
-- o valor no mesmo comando. Sem transação explícita, sem `SELECT FOR UPDATE`,
-- sem race condition possível.
CREATE OR REPLACE FUNCTION public.proximo_rodizio(_id text)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER          -- roda com o privilégio do dono da função, não de quem chama
SET search_path = public  -- impede sequestro de resolução de nome por search_path hostil
AS $$
  INSERT INTO public.rodizio_estado (id, contador) VALUES (_id, 1)
  ON CONFLICT (id) DO UPDATE SET contador = rodizio_estado.contador + 1, updated_at = now()
  RETURNING contador - 1;
  --          ^^^^^^^^^^^^
  -- Devolve a posição ANTES do incremento. O primeiro chamador da vida recebe 0,
  -- que já é o índice certo do primeiro consultor do array. Se devolvesse o
  -- contador novo, o cliente teria de fazer `-1` — uma conta a mais para
  -- alguém errar depois. A fila começa em 1 no INSERT exatamente para que o
  -- `-1` dê 0 também na primeira vez, quando a linha ainda não existe.
$$;

-- -----------------------------------------------------------------------------
-- O trinco de segurança.
-- -----------------------------------------------------------------------------
-- `SECURITY DEFINER` sem REVOKE seria um buraco: qualquer visitante com a chave
-- pública (que está no bundle do site, por definição) poderia chamar
-- `proximo_rodizio` mil vezes em um laço e envenenar a fila — deixando o
-- contador parado no índice de um consultor só, e todos os leads REAIS indo
-- para ele. É o ataque óbvio, e custa um `curl`.
--
-- Por isso: ninguém pode executar, exceto o `service_role`, que só existe
-- dentro do servidor e nunca chega ao navegador.
REVOKE ALL ON FUNCTION public.proximo_rodizio(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.proximo_rodizio(text) TO service_role;


-- -----------------------------------------------------------------------------
-- Tabela de auditoria: sem ela, o rodízio é fé.
-- -----------------------------------------------------------------------------
-- (Origem: supabase/migrations/20260721151235_*.sql, com as permissões no estado
--  final depois do endurecimento feito em 20260723011705 e 20260729124542.)
--
-- Dizer "distribuo 1:1:1" sem medir é promessa. Cada posição entregue é gravada
-- aqui, e o painel soma por consultor. Se a conta não fechar, o bug aparece em
-- número, não em reclamação de consultor no fim do mês.
CREATE TABLE public.consultor_cliques (
  id         uuid        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  consultor  text        NOT NULL,
  origem     text,  -- de qual CTA/página veio: 'pesquisa-lsd-d510', 'showroom'...
  canal      text,  -- 'formulario' | 'whatsapp'
  created_at timestamp with time zone NOT NULL DEFAULT now()
);

ALTER TABLE public.consultor_cliques ENABLE ROW LEVEL SECURITY;

-- Esta tabela é ESCRITA PELO NAVEGADOR — é o único jeito de registrar um clique
-- que leva o visitante embora do site. Então ela é append-only para o visitante:
-- pode inserir, não pode ler, não pode alterar, não pode apagar.
GRANT INSERT ON public.consultor_cliques TO anon, authenticated;
GRANT SELECT ON public.consultor_cliques TO authenticated;
GRANT ALL    ON public.consultor_cliques TO service_role;
REVOKE UPDATE, DELETE ON public.consultor_cliques FROM authenticated;

CREATE POLICY "public submit consultor_cliques"
  ON public.consultor_cliques FOR INSERT TO anon, authenticated
  WITH CHECK (true);

-- Ler a auditoria é privilégio de admin, não de qualquer usuário logado.
-- O GRANT acima abre a porta para `authenticated`; a policy é quem decide
-- quem passa. Precisa dos dois — grant sem policy não lê, policy sem grant
-- também não.
CREATE POLICY "admins read consultor_cliques"
  ON public.consultor_cliques FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));


-- -----------------------------------------------------------------------------
-- Contraste que vale notar entre as duas tabelas deste arquivo:
-- -----------------------------------------------------------------------------
--   rodizio_estado    → RLS ligada, ZERO policy. Ninguém de fora do servidor
--                       toca. É estado de decisão: se o visitante pudesse
--                       escrever, ele escolheria o próprio consultor.
--   consultor_cliques → RLS ligada, policy de INSERT para todos. É registro de
--                       fato consumado: inserir não muda decisão nenhuma, e
--                       precisa vir do navegador porque é lá que o clique mora.
--
-- A mesma pergunta nos dois casos: "o que o pior visitante possível consegue
-- fazer com esse privilégio?" As respostas diferentes geraram grants diferentes.
