-- =====================================================================
-- JJ Solene — correção de segurança, ETAPA 2 (21/09/2026): o visitante do
-- catálogo deixa de enxergar custo e margem dos produtos.
--
-- STATUS: JÁ APLICADO EM PRODUÇÃO em 21/09/2026 às 15:05 (migration
-- `seguranca_etapa2_colunas_anon`), com o "sim" do Anderson. O catálogo novo
-- (PRODUCT_COLS / SETTINGS_COLS) tinha entrado no ar às 14:51; esperou-se o
-- cache de 10 min do GitHub Pages expirar antes de rodar, senão quem estivesse
-- com o catálogo antigo (que pedia "*") veria a loja vazia. Ensaio 11/11 numa
-- transação desfeita; depois, de fora com a chave anon: custo, índices,
-- fornecedor, "*" e o celular interno recusados (42501), e a lista do
-- catálogo lendo os 172 produtos. Conferido no catálogo real num navegador.
--
-- O QUE ESTAVA ERRADO (achado jjs-01 da auditoria de 11/09, confirmado)
-- A política de `products` filtra LINHAS (show_in_catalog = true), mas RLS
-- não filtra COLUNAS, e o papel `anon` tinha SELECT na tabela inteira. Com a
-- chave pública do HTML do catálogo, qualquer visitante lia cost_price,
-- entry_value, cost_index e sale_index de cada peça — custo de compra e
-- margem — além de fornecedor_id. Em `settings`, o celular interno de alerta
-- do Atendimento e o client id do Google.
--
-- A CORREÇÃO: privilégio por COLUNA. O anon perde o SELECT da tabela e ganha
-- SELECT só nas colunas listadas abaixo (todas, menos as sensíveis). Lista
-- por exclusão de propósito: o catálogo continua podendo usar qualquer campo
-- de vitrine sem depender de alguém lembrar de liberar.
--
-- O QUE NÃO MUDA: a equipe (papel `authenticated`) continua lendo tudo; as
-- Edge Functions usam service_role; product_sizes, product_media,
-- categories, banners e gift_rules não são tocadas.
--
-- ARMADILHA PRA FRENTE: coluna NOVA em products ou settings nasce SEM grant
-- pro anon. Se o catálogo precisar dela: (1) GRANT SELECT (coluna) ... TO anon
-- e (2) acrescentar em PRODUCT_COLS / SETTINGS_COLS no CATALOG_JS, regenerar
-- catalogo/index.html. Pedir coluna sem grant, ou "*", devolve 42501 e o
-- catálogo abre vazio.
-- =====================================================================

begin;

revoke select on public.products from anon;
grant select (
  id, sku, name, category_id, sale_price, description, promo_text, show_in_catalog, image_url, created_at,
  ncm, color, discount_type, discount_value, discount_min_qty,
  installments_override, installments_max, installments_interest_free, installments_interest_rate, installments_free_max,
  color_hex, ref, composition, keep_visible_sold_out, weight_kg, length_cm, width_cm, height_cm, model_group
) on public.products to anon;
-- de fora: cost_price, entry_value, cost_index, sale_index, fornecedor_id

revoke select on public.settings from anon;
grant select (
  id, store_name, tagline, instagram, whatsapp, pix_key, pix_titular, delivery_text, payment_note, sinal_percent,
  last_catalog_generated, updated_at, logo_url, banner_url, infinitepay_handle, cashback_percent,
  attendant1_name, attendant1_phone, attendant2_name, attendant2_phone,
  installments_max, installments_interest_free, installments_interest_rate, installments_free_max,
  auto_cancel_pix_hours, auto_cancel_card_hours, website_url, exchange_policy_text, infinitepay_fee_table, origin_cep
) on public.settings to anon;
-- de fora: atendimento_alert_phone, google_client_id

commit;

-- =====================================================================
-- CONFERÊNCIA (de fora, com a chave anon)
--   GET /rest/v1/products?select=cost_price        -> 401/42501
--   GET /rest/v1/products?select=*                 -> 401/42501
--   GET /rest/v1/products?select=<PRODUCT_COLS>    -> 200
-- =====================================================================
