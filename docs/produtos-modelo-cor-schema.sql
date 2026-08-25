-- =====================================================================
-- Agrupamento de produtos por modelo (variações de cor)
--
-- Rode este arquivo inteiro no SQL Editor do Supabase, no projeto de
-- PRODUÇÃO. É seguro rodar de uma vez, e seguro rodar de novo: tudo aqui
-- é "if not exists" ou condicionado a linha ainda não preenchida.
--
-- Contexto: neste sistema cada COR é um produto separado (products.color
-- + products.color_hex), e é assim que precisa continuar — o código de
-- barras identifica peça+tamanho na hora de bipar, e duas cores com o
-- mesmo código fariam a venda de uma baixar o estoque da outra. Este
-- script não muda nada disso: só acrescenta uma ligação entre as cores do
-- mesmo modelo, pra que a tela possa mostrar "modelo → cores disponíveis"
-- em vez de uma linha solta por cor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. A coluna
--
-- Chave opaca: só a igualdade importa, o conteúdo em si nunca é exibido.
-- Dois produtos com o mesmo model_group são a mesma peça em cores
-- diferentes. Fica text (e não uuid) porque nos produtos já importados
-- ela recebe o código do modelo no Phibo, que é o agrupamento que já
-- existe de fato — e nos cadastros novos recebe um uuid gerado pelo app.
-- ---------------------------------------------------------------------
alter table products add column if not exists model_group text;

create index if not exists products_model_group_idx on products(model_group);

-- ---------------------------------------------------------------------
-- 2. Preencher o que já existe
--
-- O importador do Phibo salva em "ref" o código original do produto,
-- igual para todas as cores daquele modelo (ele separa as cores em
-- produtos distintos, mas mantém o código de origem). Então "ref" já é o
-- agrupamento correto de tudo que veio de lá.
-- ---------------------------------------------------------------------
update products
   set model_group = nullif(trim(ref), '')
 where model_group is null
   and nullif(trim(ref), '') is not null;

-- Quem não tem ref vira um grupo de um só (o próprio id). Assim nenhuma
-- linha fica com model_group nulo e a tela não precisa tratar exceção.
update products
   set model_group = id::text
 where model_group is null;

-- ---------------------------------------------------------------------
-- 3. Conferência — rode e leia antes de considerar pronto
-- ---------------------------------------------------------------------

-- 3.1 Quantos modelos passaram a ter mais de uma cor. É o que vai
--     aparecer agrupado na tela do Estoque.
select model_group,
       count(*)                          as cores,
       string_agg(coalesce(color,'(sem cor)'), ', ' order by color) as quais
  from products
 group by model_group
having count(*) > 1
 order by count(*) desc;

-- 3.2 ALERTA: mesmo model_group com nomes de produto diferentes.
--     Deve voltar VAZIO. Se voltar algo, dois produtos que não são o
--     mesmo modelo acabaram no mesmo grupo (dois "ref" iguais digitados
--     à mão, por exemplo) — me mande o resultado antes de seguir.
select model_group,
       string_agg(distinct name, ' | ') as nomes
  from products
 group by model_group
having count(distinct name) > 1;

-- ---------------------------------------------------------------------
-- 4. Diagnóstico separado: códigos de barras repetidos
--
-- Não faz parte do agrupamento — é a verificação que motivou a pergunta
-- da equipe. Hoje nada impede cadastrar dois produtos com o mesmo código
-- de barras, e quando isso acontece o leitor sempre resolve pro mesmo,
-- fazendo a baixa de estoque cair na peça errada, sem erro na tela.
--
-- Deve voltar VAZIO. Se voltar alguma linha, são peças que já estão
-- colidindo hoje e precisam de código novo antes de qualquer contagem.
-- ---------------------------------------------------------------------
select ps.barcode,
       count(*) as quantas_pecas,
       string_agg(p.name || ' / ' || coalesce(p.color,'sem cor') || ' / ' || ps.size, ' | ') as onde
  from product_sizes ps
  join products p on p.id = ps.product_id
 where ps.barcode is not null and ps.barcode <> ''
 group by ps.barcode
having count(*) > 1
 order by count(*) desc;

-- Se a consulta acima voltar vazia, vale travar isso no banco pra não
-- acontecer nunca mais. Rode SÓ se ela voltou vazia — com duplicata
-- existente o comando falha (e é bom que falhe):
--
--   create unique index products_sizes_barcode_unico
--     on product_sizes (barcode)
--    where barcode is not null and barcode <> '';
