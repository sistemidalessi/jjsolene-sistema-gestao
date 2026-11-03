-- =====================================================================
-- Segurança 03/11/2026 — o visitante (anon) fica só com o que o catálogo lê.
--
-- STATUS: PREPARADO E ENSAIADO em 03/11/2026 no banco de produção, pelo SQL Editor
-- (bloco DO que termina em erro proposital: o Postgres desfez tudo; conferido
-- depois que nenhuma permissão mudou). NÃO APLICADO: espera o "sim" do Anderson.
-- Resultado do ensaio:
--   anon com SELECT de tabela: banners, categories, gift_rules, product_media, product_sizes
--   escrita/TRUNCATE que sobrou para anon (e TRUNCATE para authenticated): nenhuma
--   catálogo como visitante, antes = depois: 183 produtos, 1 settings, 28 categorias,
--     8 fotos, 1 banner, 0 regras de brinde, 241 tamanhos
--   visitante lendo customers e orders: 42501 (antes: lia, com 0 linhas pelo RLS)
--   visitante gravando em categories: 42501 · RPC validate_coupon: segue funcionando
--
-- POR QUÊ (conferência do banco real em 03/11/2026, com a auditoria.sql do
-- repositório-modelo): nenhuma política que o visitante consiga satisfazer
-- serve para gravar — as únicas são as 7 leituras do catálogo. Mas o visitante
-- ainda tem privilégio de TABELA (SELECT, INSERT, UPDATE, DELETE, TRUNCATE) em
-- quase tudo, herança do padrão antigo do Supabase. Hoje quem barra é só a
-- condição das políticas ("ser da equipe"). Se um dia alguém criar uma política
-- frouxa ou tirar o RLS de uma tabela, o visitante leria ou gravaria nela na
-- hora. TRUNCATE ainda passa por cima do RLS (a API não emite, mas é a pior
-- permissão para sobrar). Defesa em profundidade: o visitante perde tudo o que
-- não usa.
--
-- O QUE FICA para o visitante (o catálogo lê exatamente isto — catalogo/index.html):
--   * SELECT inteiro em banners, categories, gift_rules, product_media,
--     product_sizes (o catálogo pede "*" nelas; todas têm política "public read")
--   * SELECT por coluna em products e settings (desde 21/09) — NÃO É TOCADO:
--     revogar SELECT da tabela apagaria também os grants por coluna
--   * as RPCs do checkout (reserve_stock, set_order_*, attach_payment_receipt,
--     upsert_customer, validate_coupon, waitlist_join): são SECURITY DEFINER e
--     não dependem de privilégio de tabela do visitante
-- O QUE SAI: todo INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES e TRIGGER de
-- tabela, e o SELECT de todas as outras tabelas e views. TRUNCATE sai também de
-- authenticated (a equipe não usa; a API não emite). A equipe logada não muda
-- em mais nada. Edge Functions usam service_role: não mudam.
--
-- DEPOIS DE APLICAR: tabela nova que o catálogo precise ler leva o grant
-- explícito (`grant select on public.x to anon;` ou por coluna), no mesmo
-- commit da mudança do catálogo. Anotar no CLAUDE.md.
-- =====================================================================

-- ---------- APLICAR (depois do "sim") ----------
begin;
do $aplica$
declare
  t record;
  catalogo_inteiro text[] := array['banners', 'categories', 'gift_rules', 'product_media', 'product_sizes'];
  por_coluna       text[] := array['products', 'settings'];
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm') loop
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from anon', t.relname);
    if not (t.relname = any (catalogo_inteiro) or t.relname = any (por_coluna)) then
      execute format('revoke select on public.%I from anon', t.relname);
    end if;
  end loop;
end $aplica$;
revoke truncate on all tables in schema public from authenticated;
-- tabelas criadas daqui pra frente: sem TRUNCATE para ninguém da API
alter default privileges for role postgres in schema public revoke truncate on tables from anon, authenticated;
commit;

-- ---------- CONFERÊNCIA (depois de aplicar) ----------
-- Só as 5 tabelas do catálogo, com SELECT e nada mais:
-- select c.relname, has_table_privilege('anon', c.oid, 'SELECT') sel,
--        has_table_privilege('anon', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE') escrita
--   from pg_class c join pg_namespace n on n.oid = c.relnamespace
--  where n.nspname = 'public' and c.relkind in ('r','p','v','m')
--    and has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE');
-- De fora: curl no /rest/v1/customers?select=id com a chave pública → 401/42501
-- (antes: 200 com lista vazia); o catálogo abre com os produtos.

-- ---------- ENSAIO (rodar sozinho; termina em erro de propósito e desfaz tudo) ----------
-- do $ensaio$
-- declare
--   r text := '';
--   antes text; depois text; e text; sobra text;
--   t record;
--   catalogo_inteiro text[] := array['banners', 'categories', 'gift_rules', 'product_media', 'product_sizes'];
--   por_coluna       text[] := array['products', 'settings'];
-- begin
--   perform set_config('request.jwt.claims', '', true);
--   -- o que o catálogo lê, como visitante, ANTES
--   execute 'set local role anon';
--   select format('prod=%s set=%s cat=%s mid=%s ban=%s gif=%s tam=%s',
--     (select count(*) from (select id,sku,name,category_id,sale_price,description,promo_text,show_in_catalog,image_url,created_at,ncm,color,discount_type,discount_value,discount_min_qty,installments_override,installments_max,installments_interest_free,installments_interest_rate,installments_free_max,color_hex,ref,composition,keep_visible_sold_out,weight_kg,length_cm,width_cm,height_cm,model_group from products where show_in_catalog = true) x),
--     (select count(*) from (select id,store_name,tagline,instagram,whatsapp,pix_key,pix_titular,delivery_text,payment_note,sinal_percent,last_catalog_generated,updated_at,logo_url,banner_url,infinitepay_handle,cashback_percent,attendant1_name,attendant1_phone,attendant2_name,attendant2_phone,installments_max,installments_interest_free,installments_interest_rate,installments_free_max,auto_cancel_pix_hours,auto_cancel_card_hours,website_url,exchange_policy_text,infinitepay_fee_table,origin_cep from settings where id = 1) x),
--     (select count(*) from categories), (select count(*) from product_media), (select count(*) from banners),
--     (select count(*) from gift_rules), (select count(*) from product_sizes)) into antes;
--   execute 'reset role';
--
--   -- a mudança (idêntica à seção APLICAR)
--   for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
--             where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm') loop
--     execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from anon', t.relname);
--     if not (t.relname = any (catalogo_inteiro) or t.relname = any (por_coluna)) then
--       execute format('revoke select on public.%I from anon', t.relname);
--     end if;
--   end loop;
--   revoke truncate on all tables in schema public from authenticated;
--   alter default privileges for role postgres in schema public revoke truncate on tables from anon, authenticated;
--
--   select string_agg(c.relname, ',' order by c.relname) into sobra from pg_class c join pg_namespace n on n.oid = c.relnamespace
--    where n.nspname = 'public' and c.relkind in ('r','p','v','m') and has_table_privilege('anon', c.oid, 'SELECT');
--   r := r || 'anon com SELECT de tabela: ' || coalesce(sobra, '-');
--   select string_agg(c.relname, ',') into sobra from pg_class c join pg_namespace n on n.oid = c.relnamespace
--    where n.nspname = 'public' and c.relkind in ('r','p','v','m')
--      and (has_table_privilege('anon', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE') or has_table_privilege('authenticated', c.oid, 'TRUNCATE'));
--   r := r || ' | escrita/TRUNCATE que sobrou: ' || coalesce(sobra, '-');
--
--   -- DEPOIS, como visitante: o catálogo tem de ler igual, e o resto tem de ser recusado
--   execute 'set local role anon';
--   select format('prod=%s set=%s cat=%s mid=%s ban=%s gif=%s tam=%s',
--     (select count(*) from (select id,sku,name,category_id,sale_price,description,promo_text,show_in_catalog,image_url,created_at,ncm,color,discount_type,discount_value,discount_min_qty,installments_override,installments_max,installments_interest_free,installments_interest_rate,installments_free_max,color_hex,ref,composition,keep_visible_sold_out,weight_kg,length_cm,width_cm,height_cm,model_group from products where show_in_catalog = true) x),
--     (select count(*) from (select id,store_name,tagline,instagram,whatsapp,pix_key,pix_titular,delivery_text,payment_note,sinal_percent,last_catalog_generated,updated_at,logo_url,banner_url,infinitepay_handle,cashback_percent,attendant1_name,attendant1_phone,attendant2_name,attendant2_phone,installments_max,installments_interest_free,installments_interest_rate,installments_free_max,auto_cancel_pix_hours,auto_cancel_card_hours,website_url,exchange_policy_text,infinitepay_fee_table,origin_cep from settings where id = 1) x),
--     (select count(*) from categories), (select count(*) from product_media), (select count(*) from banners),
--     (select count(*) from gift_rules), (select count(*) from product_sizes)) into depois;
--   r := r || ' | catálogo antes: ' || antes || ' | depois: ' || depois;
--   begin perform 1 from customers limit 1; e := 'LEU'; exception when others then e := sqlstate; end;
--   r := r || ' | select customers: ' || e;
--   begin perform 1 from orders limit 1; e := 'LEU'; exception when others then e := sqlstate; end;
--   r := r || ' | select orders: ' || e;
--   begin insert into categories (name) values ('ensaio'); e := 'GRAVOU'; exception when others then e := sqlstate; end;
--   r := r || ' | insert categories: ' || e;
--   begin perform validate_coupon('ENSAIO_INEXISTENTE', 100); e := 'ok'; exception when others then e := sqlstate || ' ' || sqlerrm; end;
--   r := r || ' | rpc validate_coupon: ' || e;
--   execute 'reset role';
--   raise exception 'ENSAIO >> %', r;
-- end $ensaio$;
