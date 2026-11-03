-- =====================================================================
-- Segurança 03/11/2026 — limite por IP na cotação de frete do catálogo
-- (achado jjs-11 da auditoria de 11/09/2026). Rodar no SQL Editor.
--
-- STATUS: PREPARADO E ENSAIADO em 03/11/2026 (transação desfeita; conferido depois
-- que a tabela e a função não ficaram). Ensaio: como service_role, 2 tentativas
-- cabem e a 3ª estoura (t,t,f); anon não lê a tabela; anon e authenticated não
-- executam a função. APLICADO EM PRODUÇÃO no mesmo dia, com o "sim" do Anderson,
-- junto com a melhor-envio-callback nova. De fora: cotação 200 (JeT R$ 18,47), CEP
-- inválido 400, corpo quebrado 500 com mensagem genérica; com o contador do IP do
-- teste posto no teto, 429 com Retry-After 600 (contador apagado depois). Catálogo
-- publicado cotando normalmente.
--
-- A Edge Function melhor-envio-callback é pública (o catálogo chama sem login) e
-- cada cotação gasta a cota da conta do Melhor Envio. Ela passa a perguntar ao
-- banco se aquele IP ainda cabe no limite (60 cotações a cada 10 min). É a mesma
-- tabela e a mesma função do repositório-modelo (modelo-sistema-supabase) e do
-- patch 58 do Rafa 3D: só a service_role alcança; anon e authenticated nem veem.
-- FALHA ABERTA: se esta função não existir ou der erro, a Edge Function deixa
-- passar e loga — limite nunca derruba uma venda.
-- =====================================================================

begin;

create table if not exists public.rate_limits (
  key          text        primary key,   -- ex.: 'frete:ip:203.0.113.7'
  window_start timestamptz not null,
  window_s     integer     not null,
  attempts     integer     not null default 0
);
alter table public.rate_limits enable row level security;   -- sem política: só service_role (ignora RLS)
revoke all on public.rate_limits from anon, authenticated;

create or replace function public.rate_limit_try(p_key text, p_limit integer, p_window_s integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agora timestamptz := now();
  v_row   public.rate_limits%rowtype;
begin
  delete from public.rate_limits where window_start + make_interval(secs => window_s) < v_agora - interval '1 day';
  select * into v_row from public.rate_limits where key = p_key for update;
  if not found or v_row.window_start + make_interval(secs => v_row.window_s) <= v_agora then
    insert into public.rate_limits (key, window_start, window_s, attempts) values (p_key, v_agora, p_window_s, 1)
    on conflict (key) do update set window_start = v_agora, window_s = p_window_s, attempts = 1;
    return true;
  end if;
  if v_row.attempts >= p_limit then
    return false;
  end if;
  update public.rate_limits set attempts = attempts + 1 where key = p_key;
  return true;
end;
$$;
revoke execute on function public.rate_limit_try(text, integer, integer) from public, anon, authenticated;
grant  execute on function public.rate_limit_try(text, integer, integer) to service_role;

commit;

-- CONFERÊNCIA
-- select has_table_privilege('anon','public.rate_limits','SELECT');                          -- false
-- select has_function_privilege('anon','public.rate_limit_try(text,integer,integer)','EXECUTE'); -- false
