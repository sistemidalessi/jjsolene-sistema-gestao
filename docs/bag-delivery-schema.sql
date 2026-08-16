-- =====================================================================
-- Bag Delivery ("sacolinha") — schema reconstruído
--
-- ATENÇÃO — LEIA ANTES DE RODAR:
-- Estas tabelas JÁ EXISTEM no projeto Supabase; este arquivo foi escrito
-- de fora, lendo como o index.html usa cada coluna, e NÃO é uma cópia do
-- schema real. Tipos exatos, defaults, constraints e policies podem
-- divergir do que está no banco.
--
-- Serve para: (a) recriar a estrutura num projeto novo/de teste, e
-- (b) ter no repositório um registro de quais colunas o app espera.
-- NÃO serve para "consertar" o projeto de produção.
--
-- Para conferir contra o schema de verdade, rode no SQL Editor:
--   select column_name, data_type, is_nullable, column_default
--     from information_schema.columns
--    where table_name in ('bag_deliveries','bag_delivery_items')
--    order by table_name, ordinal_position;
-- e ajuste este arquivo com o que voltar.
--
-- Os create table são "if not exists", então rodar no projeto atual é
-- inofensivo (não altera as tabelas existentes). Já a seção de RLS no
-- final está COMENTADA de propósito — veja a nota lá embaixo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tabela: bag_deliveries
-- Uma linha por sacola enviada pra cliente experimentar em casa.
-- ---------------------------------------------------------------------
create table if not exists bag_deliveries (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references customers(id),
  customer_name text not null,        -- desnormalizado: a nota promissória imprime o nome do momento do envio
  customer_phone text,
  seller_id uuid references sellers(id),
  deadline timestamptz,               -- prazo combinado pra devolver; a lista marca "vencida" quando passa
  status text not null default 'aberta',
  sent_at timestamptz not null default now(),
  closed_at timestamptz,
  created_by uuid,                    -- auth.users.id de quem registrou o envio
  created_at timestamptz not null default now()
);

-- SOBRE O DEFAULT DE status: o valor exato não importa mais, desde que NÃO seja
-- 'fechada'. O app trata como "em andamento" tudo que for diferente de 'fechada'
-- (renderBagDelivery: `b.status !== 'fechada'`), e 'fechada' é o único valor que
-- ele próprio grava.
--
-- Nem sempre foi assim: até 2026-08-16 o botão "Fechar sacola" e o aviso de prazo
-- vencido testavam por `=== 'aberta'`, enquanto a coluna Status testava por
-- `=== 'fechada'`. Com um default diferente de 'aberta' (p.ex. 'em_andamento',
-- como em inventory_sessions), o botão de fechar sacola nunca aparecia — e como a
-- coluna Status continuava mostrando "Em andamento" corretamente, nada denunciava
-- o problema na tela. Não deu pra confirmar qual era o default no banco (não havia
-- nenhuma sacola registrada pra testar), então o código foi ajustado pra não
-- depender disso. Se um dia alguém for reintroduzir um teste por valor específico,
-- confira antes qual é o default de verdade:
--   select column_default from information_schema.columns
--    where table_name='bag_deliveries' and column_name='status';

-- ---------------------------------------------------------------------
-- Tabela: bag_delivery_items
-- Peças que foram na sacola. decision começa 'pendente' e vira
-- 'ficou' (vira venda) ou 'devolvido' (só libera a reserva) no fechamento.
-- ---------------------------------------------------------------------
create table if not exists bag_delivery_items (
  id uuid primary key default gen_random_uuid(),
  bag_id uuid not null references bag_deliveries(id) on delete cascade,
  product_id uuid not null references products(id),
  size text not null,
  qty int not null default 1,
  unit_price numeric not null default 0,
  decision text not null default 'pendente',
  created_at timestamptz not null default now()
);

create index if not exists bag_delivery_items_bag_id_idx on bag_delivery_items(bag_id);
create index if not exists bag_deliveries_seller_id_idx on bag_deliveries(seller_id);

-- ---------------------------------------------------------------------
-- RPC: reserve_bag_stock(p_product_id, p_size, p_delta)
--
-- NÃO está reconstruída aqui de propósito. O corpo real não está no repo e
-- é a função que mexe em estoque — o CLAUDE.md pede pra não adivinhar esse
-- tipo de coisa. Pra pegar a definição de verdade:
--   select pg_get_functiondef('reserve_bag_stock'::regproc);
--
-- O que o app espera dela (pelos pontos onde é chamada):
--   * enviar sacola   → p_delta positivo, uma chamada por item
--   * excluir sacola  → p_delta negativo pros itens ainda 'pendente'
--   * fechar sacola   → p_delta negativo pra TODOS os itens; depois, só
--                       pros que ficaram, chama adjust_stock com delta
--                       negativo pra dar baixa de verdade no estoque
-- Ou seja: ela mexe em product_sizes.reserved, não em product_sizes.stock —
-- é isso que faz a peça "sumir da vitrine sem sumir do estoque" enquanto
-- está na casa da cliente.
-- ---------------------------------------------------------------------

-- =====================================================================
-- RLS — PROPOSTA, NÃO RODAR SEM CONFERIR
--
-- As policies reais destas tabelas já existem e eu não consigo lê-las
-- daqui. Se você rodar um `create policy` com nome diferente do que já
-- está lá, o Postgres ADICIONA uma policy permissiva em vez de substituir
-- — o efeito é AFROUXAR o acesso, não corrigir. Por isso está comentado.
--
-- Primeiro veja o que já existe:
--   select policyname, cmd, qual, with_check
--     from pg_policies
--    where tablename in ('bag_deliveries','bag_delivery_items');
--
-- O modelo que o app pressupõe (renderBagDelivery filtra por seller_id
-- quando o perfil é comercial) é este:
--
-- alter table bag_deliveries enable row level security;
-- alter table bag_delivery_items enable row level security;
--
-- create policy bag_deliveries_select on bag_deliveries for select to authenticated
--   using (is_admin() or seller_id = current_seller_id());
-- create policy bag_deliveries_insert on bag_deliveries for insert to authenticated
--   with check (is_admin() or seller_id = current_seller_id());
-- create policy bag_deliveries_update on bag_deliveries for update to authenticated
--   using (is_admin() or seller_id = current_seller_id())
--   with check (is_admin() or seller_id = current_seller_id());
-- create policy bag_deliveries_delete on bag_deliveries for delete to authenticated
--   using (is_admin() or seller_id = current_seller_id());
--
-- create policy bag_delivery_items_all on bag_delivery_items for all to authenticated
--   using (exists (select 1 from bag_deliveries b where b.id = bag_id
--            and (is_admin() or b.seller_id = current_seller_id())))
--   with check (exists (select 1 from bag_deliveries b where b.id = bag_id
--            and (is_admin() or b.seller_id = current_seller_id())));
-- =====================================================================
