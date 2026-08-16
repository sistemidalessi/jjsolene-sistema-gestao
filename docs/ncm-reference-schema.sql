-- =====================================================================
-- Tabela de consulta de NCM — schema reconstruído
--
-- ATENÇÃO — LEIA ANTES DE RODAR:
-- Esta tabela JÁ EXISTE no projeto Supabase; este arquivo foi escrito de
-- fora, lendo como o index.html usa cada coluna, e NÃO é uma cópia do
-- schema real. Serve pra recriar num projeto novo e pra registrar no repo
-- quais colunas o app espera — não pra "consertar" produção. Confira com:
--   select column_name, data_type, is_nullable, column_default
--     from information_schema.columns
--    where table_name = 'ncm_reference'
--    order by ordinal_position;
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tabela: ncm_reference
-- Tabela de apoio, só leitura pelo app: alimenta o autocomplete de NCM no
-- cadastro de produto ("🔍 Consultar NCM"). O NCM é obrigatório no produto
-- porque é o que a nota fiscal exige.
-- ---------------------------------------------------------------------
create table if not exists ncm_reference (
  ncm text primary key,       -- código NCM, ex: '6109.10.00'
  descricao text not null     -- descrição oficial, usada na busca por texto
);

-- O app carrega a tabela INTEIRA de uma vez e filtra no navegador
-- (getNcmReference guarda em cache; filterNcmSuggestions faz indexOf sobre
-- ncm e descricao, e mostra no máximo 12 sugestões a partir de 2 caracteres
-- digitados). Ou seja: não existe índice de busca textual no banco e não
-- precisa — mas se um dia essa tabela crescer pra dezenas de milhares de
-- linhas, é esse carregamento inteiro que vai ficar pesado, não a consulta.

-- Conteúdo: a tabela é populada uma vez, com a lista oficial de NCM (ou só
-- com os capítulos de vestuário, 61 e 62, que é o que interessa aqui). Os
-- dados em si não estão versionados neste repo.
--   select count(*) from ncm_reference;

-- =====================================================================
-- RLS — PROPOSTA, NÃO RODAR SEM CONFERIR
--
-- A policy real já existe e eu não consigo lê-la daqui. Rodar um
-- `create policy` com nome diferente do que já está lá ADICIONA uma policy
-- permissiva em vez de substituir. Veja antes:
--   select policyname, cmd, qual from pg_policies where tablename = 'ncm_reference';
--
-- É tabela pública de referência, sem dado da loja — leitura pra qualquer
-- usuário logado, escrita só por admin (na prática, só pelo SQL Editor):
--
-- alter table ncm_reference enable row level security;
-- create policy ncm_reference_select on ncm_reference for select to authenticated
--   using (true);
-- =====================================================================
