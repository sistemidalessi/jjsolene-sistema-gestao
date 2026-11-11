-- =====================================================================
-- Filtros do catálogo público — RPC "mais vendidos" (somente leitura)
-- Rode este arquivo inteiro no SQL Editor do Supabase (projeto JJ Solene).
-- Não altera nenhuma tabela existente; cria só uma função nova.
-- =====================================================================
--
-- 11/11/2026: a versão antiga (soma de peças vendidas por produto) nunca chegou
-- ao banco — o catálogo chamava, levava 404 e a ordem "Mais vendidos" não
-- funcionava. Reescrita para não abrir números de venda ao público: devolve só
-- a POSIÇÃO de cada produto que está no catálogo (1 = o mais vendido), sem
-- quantidade, e nada de produto escondido (show_in_catalog = false). Nenhum
-- dado de cliente.

create or replace function get_bestseller_counts()
returns table(product_id uuid, posicao integer)
language sql
security definer
set search_path = public
stable
as $$
  select si.product_id, (row_number() over (order by sum(si.qty) desc, si.product_id))::integer
  from sale_items si
  join products p on p.id = si.product_id and p.show_in_catalog = true
  group by si.product_id;
$$;

-- O catálogo público acessa via chave anon (sem login).
revoke all on function get_bestseller_counts() from public;
grant execute on function get_bestseller_counts() to anon, authenticated;
