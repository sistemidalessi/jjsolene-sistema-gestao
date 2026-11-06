-- =====================================================================
-- Tabela, sequência e função NOVAS não nascem abertas ao visitante (06/11/2026)
--
-- O endurecimento de 03/11 (seguranca-2026-11-03-visitante-so-o-catalogo.sql)
-- tirou o anon das tabelas que existiam, mas o PADRÃO do postgres continua
-- dando tudo ao anon em tabela, sequência e função nova: a próxima tabela
-- criada pelo SQL Editor nasce com SELECT/INSERT/UPDATE/DELETE/TRUNCATE do
-- visitante, e só o RLS segura. Achado ao conferir, no mesmo dia, o que o CRM
-- da OneClean tinha (37 tabelas abertas por esse motivo).
--
-- O que muda:
-- 1. O padrão do postgres no schema public deixa de dar qualquer coisa ao
--    anon em tabela, sequência e função nova. (Função nova continua
--    executável por PUBLIC, regra global do Postgres: cada função segue com o
--    próprio revoke, como manda o CLAUDE.md.)
-- 2. O anon sai da sequência invoices_number_seq (numeração das notas): o
--    catálogo não usa, quem cria nota é o admin logado ou função SECURITY
--    DEFINER, que roda como dono.
--
-- O que NÃO muda: o SELECT do anon nas 5 tabelas que o catálogo lê inteiras
-- (product_sizes, categories, banners, gift_rules, product_media) e os grants
-- por coluna de products e settings. Nada do catálogo depende do padrão.
--
-- Como aplicar: 1) rodar o ENSAIO (bloco DO no fim, sozinho) e conferir a
-- mensagem; 2) com o "sim" do Anderson, rodar o bloco begin/commit;
-- 3) conferir de fora que o catálogo abre e lista os produtos.
-- =====================================================================

begin;

alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public revoke all on functions from anon;
revoke all on sequence public.invoices_number_seq from anon;

commit;

-- =====================================================================
-- ENSAIO: aplica, cria uma tabela de teste para ver o padrão novo, mede, e
-- desfaz tudo no fim (o raise exception derruba a transação).
-- =====================================================================
/*
do $$
declare
  tabelas_anon_antes text; tabelas_anon_depois text; seq_depois boolean;
  nova_antes boolean; nova_depois boolean;
begin
  select string_agg(c.relname, ' ' order by c.relname) into tabelas_anon_antes
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'v', 'm') and has_table_privilege('anon', c.oid, 'SELECT');

  create table public.ensaio_padrao_antes (id int);
  nova_antes := has_table_privilege('anon', 'public.ensaio_padrao_antes', 'SELECT');

  alter default privileges for role postgres in schema public revoke all on tables from anon;
  alter default privileges for role postgres in schema public revoke all on sequences from anon;
  alter default privileges for role postgres in schema public revoke all on functions from anon;
  revoke all on sequence public.invoices_number_seq from anon;

  create table public.ensaio_padrao_depois (id int);
  nova_depois := has_table_privilege('anon', 'public.ensaio_padrao_depois', 'SELECT');
  seq_depois := has_sequence_privilege('anon', 'public.invoices_number_seq', 'USAGE');

  select string_agg(c.relname, ' ' order by c.relname) into tabelas_anon_depois
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'v', 'm') and has_table_privilege('anon', c.oid, 'SELECT')
     and c.relname not like 'ensaio_padrao_%';

  raise exception 'ENSAIO >> tabela nova abre ao visitante: antes %, depois %; anon na sequência das notas depois: %; tabelas que o visitante lê, antes [%] depois [%]',
    nova_antes, nova_depois, seq_depois, tabelas_anon_antes, tabelas_anon_depois;
end $$;
*/
