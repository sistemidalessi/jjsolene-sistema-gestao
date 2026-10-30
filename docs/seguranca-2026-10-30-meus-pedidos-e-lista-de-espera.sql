-- =====================================================================
-- Segurança 30/10/2026 — achados jjs-05 ("Meus pedidos" por telefone) e
-- jjs-13 (lista de espera sem limite). Rodar no SQL Editor do painel.
--
-- STATUS: ver nota no fim do arquivo.
--
-- jjs-05: get_my_orders(p_phone) era executável pelo visitante e devolvia nome,
-- saldo de cashback e compras de QUEM TIVESSE aquele telefone — e buscava na
-- tabela de clientes, não só nos pedidos do site (expunha a base da loja física
-- também). O botão "Meus pedidos" saiu do catálogo; aqui a função deixa de ser
-- executável por qualquer papel (fica no banco, sem chamador, para o dia em que
-- voltar com código por WhatsApp).
--
-- jjs-13: o visitante gravava direto em waitlist (política "anon insert", sem
-- validação, sem limite). Agora entra por waitlist_join(), que:
--   * exige nome (1–80 chars) e telefone com 10–11 dígitos
--   * exige produto existente e visível no catálogo
--   * não duplica (mesmo telefone + produto ainda não avisado = não grava de novo)
--   * limita: 10 cadastros por telefone em 24 h e 150 por hora no total
-- A ETAPA 2 (tirar o INSERT direto do anon) só roda depois de o catálogo novo
-- estar no ar há 10 min (cache do GitHub Pages), senão o catálogo velho em cache
-- falha ao cadastrar.
-- =====================================================================

-- ---------- ETAPA 1 (aditiva + fecha a RPC antiga) ----------
begin;

-- jjs-05
revoke execute on function public.get_my_orders(text) from public, anon, authenticated;

-- jjs-13
create or replace function public.waitlist_join(p_product_id uuid, p_name text, p_phone text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome  text := left(btrim(coalesce(p_name, '')), 80);
  v_fone  text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if length(v_nome) < 1 then
    raise exception 'Informe seu nome.' using errcode = '22023';
  end if;
  if length(v_fone) not between 10 and 11 then
    raise exception 'Telefone com DDD, 10 ou 11 números.' using errcode = '22023';
  end if;
  if not exists (select 1 from products where id = p_product_id and show_in_catalog = true) then
    raise exception 'Produto não encontrado.' using errcode = '22023';
  end if;
  -- já está na lista deste produto e ainda não foi avisado: não grava de novo
  if exists (select 1 from waitlist where product_id = p_product_id and phone = v_fone and coalesce(notified, false) = false) then
    return;
  end if;
  -- limites contra script (jjs-13)
  if (select count(*) from waitlist where phone = v_fone and created_at > now() - interval '24 hours') >= 10 then
    raise exception 'Muitos cadastros com esse telefone hoje. Fala com a gente pelo WhatsApp.' using errcode = '22023';
  end if;
  if (select count(*) from waitlist where created_at > now() - interval '1 hour') >= 150 then
    raise exception 'Muita gente agora. Tenta de novo em instantes.' using errcode = '22023';
  end if;
  insert into waitlist (product_id, customer_name, phone) values (p_product_id, v_nome, v_fone);
end;
$$;
revoke execute on function public.waitlist_join(uuid, text, text) from public;
grant  execute on function public.waitlist_join(uuid, text, text) to anon, authenticated;

commit;

-- ---------- ETAPA 2 (depois do catálogo novo no ar + 10 min) ----------
-- begin;
-- drop policy if exists "anon insert waitlist" on public.waitlist;
-- revoke insert on public.waitlist from anon;
-- commit;

-- ---------- CONFERÊNCIA ----------
-- select has_function_privilege('anon','public.get_my_orders(text)','EXECUTE');        -- false
-- select has_function_privilege('anon','public.waitlist_join(uuid,text,text)','EXECUTE'); -- true
-- select has_table_privilege('anon','public.waitlist','INSERT');                         -- false depois da etapa 2
-- select policyname from pg_policies where tablename='waitlist';                        -- só "admin full waitlist" depois da etapa 2
