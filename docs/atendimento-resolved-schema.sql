-- Marca conversas como "resolvidas" no Atendimento (arquivar sem apagar histórico).
-- Coluna nula = conversa ativa (comportamento atual, sem mudança nenhuma).
alter table conversations add column if not exists resolved_at timestamptz;
