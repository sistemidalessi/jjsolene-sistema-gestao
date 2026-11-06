-- =====================================================================
-- Storage das fotos de produto (06/11/2026) — APLICADO em 06/11/2026 com o
-- "sim" do Anderson, depois do ensaio (visitante listava 215 arquivos e passou
-- a 0; a equipe segue com 215). Provado de fora com a chave pública: a
-- listagem do bucket volta vazia e a foto do catálogo abre (HTTP 200).
--
-- Achado pela consulta docs/auditoria-storage.sql do sistemi-dalessi, rodada
-- no painel em 06/11/2026. A auditoria de 21/09 olhou só o schema public;
-- estas duas políticas do Storage ficaram de fora:
--
-- 1. "staff manage product images" (ALL para public) usava
--    auth.role() = 'authenticated': qualquer conta logada, mesmo sem perfil
--    de equipe, sobe, troca e apaga as fotos e vídeos do catálogo. É a forma
--    que a regra 3 do CLAUDE.md proíbe. Hoje as 4 contas são da equipe e o
--    cadastro público está desligado, então ninguém usa: o furo fica
--    dormindo até alguém religar o cadastro ou criar uma conta sem perfil.
-- 2. "public read product images" (SELECT para public): deixava qualquer
--    visitante LISTAR o bucket. A foto no catálogo abre pela URL pública, que
--    não passa por política; nada no site lista o bucket.
-- 3. Bucket sem limite de tamanho: limite de 50 MB (o maior arquivo hoje,
--    um vídeo, tem 12 MB). O tipo de arquivo fica livre de propósito: o
--    bucket já tem JPEG, PNG, SVG e MP4, e o celular pode mandar outros.
--
-- O admin sobe com upload(..., { upsert: true }), que exige também SELECT de
-- quem sobe: a política nova é ALL, então a equipe continua lendo.
--
-- Como aplicar: 1) rodar o ENSAIO (bloco DO no fim, sozinho) e conferir a
-- mensagem; 2) com o "sim" do Anderson, rodar o bloco begin/commit;
-- 3) provar de fora com a chave pública: a URL pública de uma foto abre (200)
-- e a listagem do bucket volta vazia.
-- =====================================================================

begin;

drop policy if exists "public read product images" on storage.objects;
drop policy if exists "staff manage product images" on storage.objects;

create policy product_images_staff on storage.objects for all to authenticated
  using (bucket_id = 'product-images' and public.is_staff())
  with check (bucket_id = 'product-images' and public.is_staff());

update storage.buckets set file_size_limit = 52428800 where id = 'product-images';

commit;

-- =====================================================================
-- ENSAIO: aplica, mede como visitante e como equipe, e desfaz tudo no fim
-- (o raise exception derruba a transação). Rodar SOZINHO, antes do bloco acima.
-- =====================================================================
/*
do $$
declare
  equipe uuid;
  anon_antes int; anon_depois int; equipe_depois int;
  politicas text; limite bigint;
begin
  select id into equipe from public.profiles limit 1;

  execute 'set local role anon';
  select count(*) into anon_antes from storage.objects where bucket_id = 'product-images';
  execute 'reset role';

  drop policy if exists "public read product images" on storage.objects;
  drop policy if exists "staff manage product images" on storage.objects;
  create policy product_images_staff on storage.objects for all to authenticated
    using (bucket_id = 'product-images' and public.is_staff())
    with check (bucket_id = 'product-images' and public.is_staff());
  update storage.buckets set file_size_limit = 52428800 where id = 'product-images';

  execute 'set local role anon';
  select count(*) into anon_depois from storage.objects where bucket_id = 'product-images';
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', equipe, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into equipe_depois from storage.objects where bucket_id = 'product-images';
  execute 'reset role';

  select string_agg(policyname || ' (' || cmd || ' ' || array_to_string(roles, ',') || ')', '; ')
    into politicas from pg_policies where schemaname = 'storage' and qual like '%product-images%';
  select file_size_limit into limite from storage.buckets where id = 'product-images';

  raise exception 'ENSAIO >> visitante listava % e passa a listar %; equipe lista %; políticas: %; limite: % bytes',
    anon_antes, anon_depois, equipe_depois, politicas, limite;
end $$;
*/
