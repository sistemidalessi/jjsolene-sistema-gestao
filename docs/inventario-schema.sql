-- =====================================================================
-- Inventário (contagem com código de barras) — schema reconstruído
--
-- ATENÇÃO — LEIA ANTES DE RODAR:
-- Estas tabelas JÁ EXISTEM no projeto Supabase; este arquivo foi escrito
-- de fora, lendo como o index.html usa cada coluna, e NÃO é uma cópia do
-- schema real. Tipos exatos, defaults, constraints e policies podem
-- divergir do que está no banco. Serve pra recriar num projeto novo e pra
-- registrar no repo quais colunas o app espera — não pra "consertar"
-- produção. Confira com:
--   select column_name, data_type, is_nullable, column_default
--     from information_schema.columns
--    where table_name in ('inventory_sessions','inventory_session_items')
--    order by table_name, ordinal_position;
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tabela: inventory_sessions
-- Uma linha por contagem. 'total' inclui todos os produtos; 'parcial'
-- guarda em category_ids quais categorias entraram.
-- ---------------------------------------------------------------------
create table if not exists inventory_sessions (
  id uuid primary key default gen_random_uuid(),
  type text not null default 'total',        -- 'total' | 'parcial'
  category_ids uuid[],                       -- null quando type='total'
  status text not null default 'em_andamento',
  created_by uuid,                           -- auth.users.id de quem iniciou
  created_at timestamptz not null default now(),
  finished_at timestamptz
);

-- Sobre category_ids: o app manda um array de ids ["uuid","uuid"] via
-- supabase-js. Funciona tanto com uuid[] quanto com jsonb — se no banco
-- estiver jsonb, deixe jsonb e ignore o tipo acima, porque o app só grava e
-- nunca consulta essa coluna por dentro (o filtro por categoria acontece na
-- montagem dos itens, não depois).

-- Só pode existir uma contagem 'em_andamento' por vez na prática (a tela
-- oferece "Continuar contagem" pra primeira que achar), mas isso não é
-- garantido por constraint — é convenção da UI.

-- ---------------------------------------------------------------------
-- Tabela: inventory_session_items
-- Uma linha por produto+tamanho incluído na contagem, criada toda de uma vez
-- quando a sessão começa. system_stock é uma FOTO do estoque no momento em
-- que a contagem foi aberta — é isso que permite comparar depois mesmo que o
-- estoque mude no meio.
-- ---------------------------------------------------------------------
create table if not exists inventory_session_items (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references inventory_sessions(id) on delete cascade,
  product_id uuid not null references products(id),
  size text not null,
  system_stock int not null default 0,
  counted_qty int not null default 0,        -- cada bipada soma 1
  corrected boolean not null default false,  -- impede aplicar o mesmo ajuste duas vezes
  created_at timestamptz not null default now()
);

create index if not exists inventory_session_items_session_id_idx
  on inventory_session_items(session_id);

-- A correção de estoque no relatório final NÃO escreve direto em
-- product_sizes: ela chama a RPC adjust_stock (já existente no projeto) com
-- p_delta = counted_qty - system_stock, e só então marca corrected=true.

-- =====================================================================
-- RLS — PROPOSTA, NÃO RODAR SEM CONFERIR
--
-- As policies reais já existem e eu não consigo lê-las daqui. Rodar um
-- `create policy` com nome diferente do que já está lá ADICIONA uma policy
-- permissiva em vez de substituir — afrouxa o acesso. Por isso está
-- comentado. Veja antes o que existe:
--   select policyname, cmd, qual, with_check
--     from pg_policies
--    where tablename in ('inventory_sessions','inventory_session_items');
--
-- Inventário não está em COMERCIAL_ALLOWED_TABS, ou seja, é aba só de admin:
--
-- alter table inventory_sessions enable row level security;
-- alter table inventory_session_items enable row level security;
--
-- create policy inventory_sessions_all on inventory_sessions for all to authenticated
--   using (is_admin()) with check (is_admin());
-- create policy inventory_session_items_all on inventory_session_items for all to authenticated
--   using (is_admin()) with check (is_admin());
-- =====================================================================
