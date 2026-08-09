-- Marca conversas como "resolvidas" no Atendimento (arquivar sem apagar histórico).
-- Coluna nula = conversa ativa (comportamento atual, sem mudança nenhuma).
alter table conversations add column if not exists resolved_at timestamptz;

-- Numero de WhatsApp interno que recebe aviso automatico quando chega mensagem nova
-- no Atendimento (sem ninguem acompanhando). Vazio/nulo = recurso desligado.
alter table settings add column if not exists atendimento_alert_phone text;

-- Permite Admin excluir conversas/mensagens do Atendimento (o RLS provavelmente so tinha
-- policy de select/update/insert ate agora — por isso o botao de excluir nao apagava nada).
create policy "Admin exclui conversas" on conversations for delete using (is_admin());
create policy "Admin exclui mensagens" on messages for delete using (is_admin());
