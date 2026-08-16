-- =====================================================================
-- Cashback (regras configuráveis + extrato) — schema reconstruído
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
--    where table_name in ('cashback_rules','cashback_ledger')
--    order by table_name, ordinal_position;
--
-- (cashback_ledger não é tabela nova, mas também nunca teve SQL no repo e
-- não faz sentido documentar uma sem a outra.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tabela: cashback_rules
-- Uma linha por TIPO de regra. O app nunca faz insert aqui — as 5 linhas
-- são fixas e a tela de Configurações só edita e liga/desliga cada uma.
-- Por isso o seed no final deste arquivo é parte do schema, não exemplo.
-- ---------------------------------------------------------------------
create table if not exists cashback_rules (
  id uuid primary key default gen_random_uuid(),
  type text not null unique,          -- 'padrao'|'valor_minimo'|'boas_vindas'|'validade'|'fidelidade'
  name text not null,                 -- nome de exibição, editável pela dona
  percent numeric not null default 0, -- percentual base
  active boolean not null default false,

  -- usados só por type='valor_minimo'
  min_purchase_value numeric,

  -- usado só por type='validade'
  expiration_days int,

  -- usados só por type='fidelidade' (níveis Prata e Ouro, por total gasto)
  tier2_min_spent numeric,
  tier2_percent numeric,
  tier3_min_spent numeric,
  tier3_percent numeric,

  created_at timestamptz not null default now()
);

-- COMO AS REGRAS SE COMBINAM (applyCashbackRules): mais de uma regra pode
-- ficar ativa ao mesmo tempo, mas elas NÃO se somam. O app avalia todas as
-- ativas, descarta as inelegíveis (valor_minimo abaixo do mínimo,
-- boas_vindas fora da primeira compra) e aplica só o MAIOR percentual.
-- Se um dia a regra virar "acumulativa", é essa função que muda — não o schema.

-- ---------------------------------------------------------------------
-- Tabela: cashback_ledger
-- Extrato de cashback da cliente. Hoje o app só grava type='credito', na
-- confirmação do pedido; o saldo consolidado fica em customers.cashback_balance
-- (atualizado na mesma operação, não calculado a partir daqui).
-- ---------------------------------------------------------------------
create table if not exists cashback_ledger (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(id),  -- SEM cascade de propósito: a exclusão
                                                       -- de cliente com cashback é bloqueada, e o
                                                       -- app trata esse erro de FK com mensagem
                                                       -- própria (deleteRow em renderClientes)
  amount numeric not null,
  type text not null default 'credito',   -- 'credito' | 'debito'
  ref_sale_id uuid,                       -- venda que gerou o crédito
  rule_name text,                         -- nome da regra no momento do crédito
  expires_at timestamptz,                 -- preenchido só quando a regra vencedora é 'validade'
  created_at timestamptz not null default now()
);

create index if not exists cashback_ledger_customer_id_idx on cashback_ledger(customer_id);

-- Coluna relacionada, em customers (deve existir; aqui só como lembrete):
-- alter table customers add column if not exists cashback_balance numeric not null default 0;

-- NOTA: nada no app expira crédito automaticamente. expires_at é gravado mas
-- nunca lido — não existe rotina que zere créditos vencidos nem que debite o
-- saldo quando a cliente usa o cashback. Se isso for virar requisito, vai
-- precisar de código novo, não só de configuração.

-- ---------------------------------------------------------------------
-- Seed das 5 regras (só insere se ainda não existirem)
-- Percentuais e valores são chute inicial — a dona ajusta pela tela.
-- ---------------------------------------------------------------------
insert into cashback_rules (type, name, percent, active, min_purchase_value, expiration_days,
                            tier2_min_spent, tier2_percent, tier3_min_spent, tier3_percent)
values
  ('padrao',       'Cashback padrão',      5,  false, null,  null, null, null, null, null),
  ('valor_minimo', 'Compra acima de',      7,  false, 300,   null, null, null, null, null),
  ('boas_vindas',  'Primeira compra',      10, false, null,  null, null, null, null, null),
  ('validade',     'Crédito com validade', 5,  false, null,  30,   null, null, null, null),
  ('fidelidade',   'Fidelidade por nível', 3,  false, null,  null, 1000, 5,   3000, 8)
on conflict (type) do nothing;

-- O `on conflict (type)` depende do unique em cashback_rules.type declarado
-- acima. Se no banco real não houver esse unique, o insert duplica as regras —
-- confira antes:
--   select type, count(*) from cashback_rules group by type having count(*) > 1;

-- =====================================================================
-- RLS — PROPOSTA, NÃO RODAR SEM CONFERIR
--
-- As policies reais já existem e eu não consigo lê-las daqui. Rodar um
-- `create policy` com nome diferente do que já está lá ADICIONA uma policy
-- permissiva em vez de substituir — afrouxa o acesso. Veja antes:
--   select policyname, cmd, qual, with_check
--     from pg_policies where tablename in ('cashback_rules','cashback_ledger');
--
-- O catálogo público mostra saldo de cashback em "Meus pedidos", mas lê isso
-- de customers.cashback_balance através da RPC get_my_orders (security
-- definer), não desta tabela — então cashback_ledger não precisa estar
-- exposta pra anon.
--
-- alter table cashback_rules enable row level security;
-- alter table cashback_ledger enable row level security;
--
-- -- regras são configuração da loja: só admin lê e edita
-- create policy cashback_rules_select on cashback_rules for select to authenticated
--   using (is_admin());
-- create policy cashback_rules_update on cashback_rules for update to authenticated
--   using (is_admin()) with check (is_admin());
--
-- create policy cashback_ledger_select on cashback_ledger for select to authenticated
--   using (is_admin());
-- =====================================================================
