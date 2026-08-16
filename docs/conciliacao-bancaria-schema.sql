-- =====================================================================
-- Conciliação bancária (importação de OFX) — schema reconstruído
--
-- ATENÇÃO — LEIA ANTES DE RODAR:
-- Esta tabela JÁ EXISTE no projeto Supabase; este arquivo foi escrito de
-- fora, lendo como o index.html usa cada coluna, e NÃO é uma cópia do
-- schema real. Tipos exatos, defaults, constraints e policies podem
-- divergir do que está no banco. Serve pra recriar num projeto novo e pra
-- registrar no repo quais colunas o app espera — não pra "consertar"
-- produção. Confira com:
--   select column_name, data_type, is_nullable, column_default
--     from information_schema.columns
--    where table_name = 'bank_import_transactions'
--    order by ordinal_position;
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tabela: bank_import_transactions
-- Uma linha por transação lida do extrato .OFX do banco. Fica lado a lado
-- com finance: o extrato é o que o banco diz que aconteceu, finance é o que
-- a loja registrou. A conciliação tenta casar os dois.
-- ---------------------------------------------------------------------
create table if not exists bank_import_transactions (
  id uuid primary key default gen_random_uuid(),
  fitid text not null unique,     -- id da transação no OFX; é o que impede reimportação duplicada
  date date not null,
  amount numeric not null,        -- positivo = entrada, negativo = saída (sinal do próprio OFX)
  memo text,                      -- <MEMO> do OFX, ou <NAME> quando não tem memo
  status text not null default 'unmatched',   -- 'unmatched' | 'matched'
  matched_finance_id uuid references finance(id),
  created_at timestamptz not null default now()
);

-- O UNIQUE em fitid é OBRIGATÓRIO, não é otimização: a importação usa
--   .upsert(rows, { onConflict: 'fitid', ignoreDuplicates: true })
-- e é isso que torna seguro reimportar o mesmo arquivo (ou arquivos com
-- período sobreposto) sem duplicar transação. Sem o unique, o upsert falha.

create index if not exists bank_import_transactions_status_idx
  on bank_import_transactions(status);

-- ---------------------------------------------------------------------
-- Como o casamento automático funciona (matchBankTransactions):
--   1. pega as transações ainda 'unmatched'
--   2. candidatas em finance = mesmo tipo (amount >= 0 → 'receita', senão
--      'despesa'), valor batendo com tolerância de 1 centavo, e que ainda
--      não foram usadas por outra transação
--   3. primeiro tenta data exata; se não achar, aceita diferença de até 3 dias
--   4. casando, grava status='matched' + matched_finance_id
-- O que sobra sem par aparece na tela e vira lançamento novo em finance com
-- um clique. Nada é apagado nem alterado em finance automaticamente.
-- ---------------------------------------------------------------------

-- =====================================================================
-- RLS — PROPOSTA, NÃO RODAR SEM CONFERIR
--
-- A policy real já existe e eu não consigo lê-la daqui. Rodar um
-- `create policy` com nome diferente do que já está lá ADICIONA uma policy
-- permissiva em vez de substituir — afrouxa o acesso. Veja antes:
--   select policyname, cmd, qual, with_check
--     from pg_policies where tablename = 'bank_import_transactions';
--
-- Financeiro não está em COMERCIAL_ALLOWED_TABS, ou seja, é aba só de admin:
--
-- alter table bank_import_transactions enable row level security;
-- create policy bank_import_transactions_all on bank_import_transactions
--   for all to authenticated using (is_admin()) with check (is_admin());
-- =====================================================================
