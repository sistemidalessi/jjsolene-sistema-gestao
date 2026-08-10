-- Limpeza das categorias duplicadas criadas pela importação Phibo (2026-08-10)
--
-- Contexto: a importação casava o nome da categoria do Phibo (ex: "Pijama") por
-- string exata contra as categorias já existentes. Como o catálogo usa nomes no
-- plural ("Pijamas"), não houve match e a importação criou categorias novas no
-- singular com ícone genérico 🏷️, ao invés de usar as categorias curadas que o
-- catálogo já usa para navegação/filtros.
--
-- Os 204 produtos já foram remapeados (via updates diretos) das categorias
-- duplicadas para as categorias corretas:
--   Pijama -> Pijamas, Vestido -> Vestidos, Saia -> Saias, Calça -> Calças,
--   Conjunto -> Conjuntos, Camisa -> Camisas, Moletom -> Moletons,
--   Blusa -> Blusas/Camisetas, semGrupo -> Saias
-- E as categorias sem par no catálogo (específicas do Phibo, sem duplicata) só
-- tiveram nome/ícone corrigidos, sem remapear produtos: Blazer -> Blazers,
-- Body, Cacharrel, Camiseta -> Camisetas, Casaco -> Casacos, Jaqueta -> Jaquetas,
-- Lenço -> Lenços, Regata -> Regatas, Sobretudo -> Sobretudos,
-- Conjunto fitness -> Conjuntos Fitness.
--
-- As 10 categorias abaixo já estão com 0 produtos (confirmado antes deste
-- script) e podem ser apagadas com segurança.

delete from categories where id in (
  '648ce115-ea9b-433b-8c3c-d157534b8fcb', -- Pijama (duplicata de Pijamas)
  '9d09c9fe-013a-40f6-91fc-27b2ed28f28a', -- Vestido (duplicata de Vestidos)
  '3e7bcaeb-3762-4f55-ad42-69516036f1c6', -- Saia (duplicata de Saias)
  '19a77cda-4be0-4578-a839-3c19fad9da81', -- Calça (duplicata de Calças)
  '053c4af2-11fe-43ea-a068-4ebdfad8da71', -- Conjunto (duplicata de Conjuntos)
  '242f293a-eff5-488f-b93b-4b302acbab68', -- Camisa (duplicata de Camisas)
  'ffab3485-7d8c-484b-bf38-8ba18634aec3', -- Moletom (duplicata de Moletons)
  '6db0facc-2f65-48db-b9c3-56dce3758e38', -- Blusa (duplicata de Blusas/Camisetas)
  'fda9cce2-de1f-468e-bb96-9aedd1c5daf3', -- semGrupo (placeholder do Phibo, sem produtos)
  'c821e276-f0f7-49f0-adec-678ca69c58bb'  -- Categoria (lixo de importação anterior, sem produtos)
);
