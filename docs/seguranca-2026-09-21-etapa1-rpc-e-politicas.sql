-- =====================================================================
-- JJ Solene — correção de segurança, ETAPA 1 (21/09/2026)
--
-- STATUS: APLICADO EM PRODUÇÃO em 21/09/2026 (migration
-- `seguranca_etapa1_rpc_e_politicas`, projeto pcvcpylcpuvprpkydbxf), com o
-- "sim" do Anderson. Antes de aplicar, o script inteiro + 28 testes rodaram
-- numa transação desfeita de propósito (28/28 ok, nada persistiu); depois de
-- aplicar, 7 ataques feitos de fora com a chave anon foram todos recusados e
-- o catálogo seguiu lendo os produtos. Este arquivo é o registro do que está
-- no banco — não precisa rodar de novo.
-- Origem: auditoria de 11/09/2026 + leitura das funções e políticas REAIS do
-- projeto em 21/09/2026 (os corpos abaixo partem do pg_get_functiondef de
-- produção, não de reconstrução a partir do código do cliente).
--
-- O QUE ESTAVA ERRADO (tudo confirmado no banco, nada é suposição):
--  A. adjust_stock, confirm_order, cancel_order, reserve_bag_stock e
--     get_user_id_by_email são SECURITY DEFINER, executáveis pelo papel `anon`
--     e NÃO conferem quem chama. Com a chave pública que está no HTML do
--     catálogo, qualquer visitante podia: zerar/inflar o estoque de qualquer
--     peça, confirmar o próprio pedido sem pagar (gera venda, lança receita
--     "pago" no financeiro, baixa estoque e credita cashback), cancelar
--     pedido alheio, reservar o estoque inteiro, e descobrir o id de um
--     usuário pelo e-mail.
--  B. reserve_stock usa o PREÇO que o navegador manda, aceita quantidade
--     negativa e não valida o brinde.
--  C. attach_payment_receipt grava qualquer URL (inclusive `javascript:`),
--     que depois vira link clicável na tela de Pedidos do admin.
--  D. Quatro tabelas liberam acesso a "qualquer usuário autenticado"
--     (auth.role() = 'authenticated'), e o cadastro público de usuários do
--     Supabase Auth está LIGADO. Quem criasse uma conta com o próprio e-mail
--     lia todos os clientes (nome, telefone, CPF, e-mail) e todos os pedidos.
--     Em 21/09/2026 as 4 contas existentes eram todas da equipe — ninguém de
--     fora tinha se cadastrado.
--  E. A família set_order_* altera pedido em qualquer status.
--  F. upsert_customer deixa um visitante sobrescrever o nome de um cliente
--     existente sabendo só o telefone.
--
-- O QUE NÃO MUDA PRA QUEM USA: o catálogo nunca chamou as funções do item A
-- (conferido: 0 chamadas em catalogo/index.html); a equipe continua chamando
-- todas normalmente, admin e comercial. Preço, desconto por quantidade,
-- cupom e brinde dão o mesmo resultado de antes para um carrinho honesto.
--
-- O QUE MUDA DE PROPÓSITO:
--  - Preço diferente do cadastrado (adulterado, ou página aberta desde antes
--    de uma troca de preço) => o pedido é recusado com mensagem pedindo pra
--    atualizar a página, em vez de ser gravado com o preço do navegador.
--  - Cliente que já existe: o checkout só PREENCHE o que está vazio (e-mail,
--    CPF, aniversário); não troca mais o nome já cadastrado.
--
-- FORA DESTE ARQUIVO (precisa de clique no painel, SQL não alcança):
--    Authentication > Sign In / Providers > desligar "Allow new users to sign
--    up". A equipe continua sendo criada por Authentication > Add user.
--    O item D abaixo já fecha o buraco mesmo com o cadastro ligado; desligar
--    é a segunda tranca.
--
-- ETAPA 2 (arquivo separado, só DEPOIS de publicar o catálogo com lista de
-- colunas explícita): tirar custo/margem de `products` e campos internos de
-- `settings` do alcance do `anon`.
--
-- Rodar inteiro, de uma vez (é uma transação: ou entra tudo, ou nada).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. is_staff(): "quem chama é da equipe?" = tem linha em profiles.
--    (is_admin() já existia; esta é a versão admin OU comercial.)
-- ---------------------------------------------------------------------
create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.profiles where id = auth.uid());
$$;

-- is_admin / current_seller_id: mesmo corpo, só ganham search_path fixo
-- (função SECURITY DEFINER sem search_path é o aviso clássico do Supabase).
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.current_seller_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select seller_id from public.profiles where id = auth.uid();
$$;

-- ---------------------------------------------------------------------
-- A. Funções administrativas: exigem equipe por dentro E perdem o EXECUTE
--    do anon por fora (duas trancas: se um dia alguém recriar a função sem
--    a checagem, o grant ainda segura; e vice-versa).
-- ---------------------------------------------------------------------
create or replace function public.adjust_stock(p_product_id uuid, p_size text, p_delta integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then
    raise exception 'Acesso negado' using errcode = '42501';
  end if;
  insert into product_sizes (product_id, size, stock)
    values (p_product_id, p_size, greatest(0, p_delta))
  on conflict (product_id, size)
    do update set stock = greatest(0, product_sizes.stock + p_delta);
end;
$$;

create or replace function public.reserve_bag_stock(p_product_id uuid, p_size text, p_delta integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then
    raise exception 'Acesso negado' using errcode = '42501';
  end if;
  update public.product_sizes
     set reserved = greatest(0, reserved + p_delta)
   where product_id = p_product_id and size = p_size;
end;
$$;

create or replace function public.cancel_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  item order_items%rowtype;
begin
  if not public.is_staff() then
    raise exception 'Acesso negado' using errcode = '42501';
  end if;
  -- (correção de carona) só devolve a reserva se o pedido ainda está pendente:
  -- antes, chamar duas vezes devolvia a reserva duas vezes.
  if not exists (select 1 from orders where id = p_order_id and status = 'pendente') then
    return;
  end if;
  for item in select * from order_items where order_id = p_order_id loop
    update product_sizes set reserved = greatest(0, reserved - item.qty)
      where product_id = item.product_id and size = item.size;
  end loop;
  update orders set status = 'cancelado' where id = p_order_id and status = 'pendente';
end;
$$;

create or replace function public.confirm_order(p_order_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order orders%rowtype;
  item order_items%rowtype;
  v_sale_id uuid := gen_random_uuid();
  v_customer_id uuid;
  v_cashback_percent numeric;
  v_cashback_amount numeric;
begin
  if not public.is_staff() then
    raise exception 'Acesso negado' using errcode = '42501';
  end if;

  -- daqui pra baixo: corpo idêntico ao de produção em 21/09/2026
  select * into v_order from orders where id = p_order_id and status = 'pendente';
  if not found then
    raise exception 'Pedido não encontrado ou já processado';
  end if;

  insert into sales (id, customer, phone, total, order_id, payment)
    values (v_sale_id, v_order.customer, v_order.phone, v_order.total, v_order.id, 'Pix');

  for item in select * from order_items where order_id = p_order_id loop
    update product_sizes
      set stock = stock - item.qty, reserved = greatest(0, reserved - item.qty)
      where product_id = item.product_id and size = item.size;

    insert into sale_items (sale_id, product_id, size, qty, price)
      values (v_sale_id, item.product_id, item.size, item.qty, item.price);
  end loop;

  update orders set status = 'confirmado' where id = p_order_id;

  insert into finance (date, type, category, description, amount, status, origin, ref_id)
    values (current_date, 'receita', 'Venda (catálogo)', 'Pedido confirmado — ' || coalesce(v_order.customer,'Cliente'), v_order.total, 'pago', 'venda', v_sale_id);

  if v_order.coupon_code is not null then
    insert into coupon_uses (coupon_id, order_id, sale_id, amount_discounted)
      select id, v_order.id, v_sale_id, v_order.discount_amount from coupons where lower(code) = lower(v_order.coupon_code);
  end if;

  if v_order.phone is not null then
    select id into v_customer_id from customers where phone = v_order.phone;
    if v_customer_id is not null then
      select cashback_percent into v_cashback_percent from settings where id = 1;
      if v_cashback_percent > 0 then
        v_cashback_amount := round(v_order.total * (v_cashback_percent/100.0), 2);
        insert into cashback_ledger (customer_id, amount, type, ref_sale_id) values (v_customer_id, v_cashback_amount, 'credito', v_sale_id);
        update customers set cashback_balance = cashback_balance + v_cashback_amount where id = v_customer_id;
      end if;
    end if;
  end if;

  return v_sale_id;
end;
$$;

-- Só admin usa (Configurações > Equipe).
create or replace function public.get_user_id_by_email(p_email text)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Acesso negado' using errcode = '42501';
  end if;
  return (select id from auth.users where email = p_email limit 1);
end;
$$;

revoke execute on function public.adjust_stock(uuid, text, integer)        from public, anon;
revoke execute on function public.reserve_bag_stock(uuid, text, integer)   from public, anon;
revoke execute on function public.cancel_order(uuid)                       from public, anon;
revoke execute on function public.confirm_order(uuid)                      from public, anon;
revoke execute on function public.get_user_id_by_email(text)               from public, anon;
grant  execute on function public.adjust_stock(uuid, text, integer)        to authenticated, service_role;
grant  execute on function public.reserve_bag_stock(uuid, text, integer)   to authenticated, service_role;
grant  execute on function public.cancel_order(uuid)                       to authenticated, service_role;
grant  execute on function public.confirm_order(uuid)                      to authenticated, service_role;
grant  execute on function public.get_user_id_by_email(text)               to authenticated, service_role;

-- ---------------------------------------------------------------------
-- B. reserve_stock: o preço é o do CADASTRO, não o do navegador.
--    Regra de preço = a de lineUnitPrice() no catálogo:
--      percent: sale_price * (1 - discount_value/100)  se qty >= discount_min_qty
--      fixed:   max(0, sale_price - discount_value)     se qty >= discount_min_qty
--    Brinde = a linha de preço 0 cujo produto é p_gift_product_id: no máximo
--    uma, quantidade 1, e tem de existir regra ativa em gift_rules com
--    min_total <= subtotal dos itens pagos (antes do cupom, igual ao catálogo).
-- ---------------------------------------------------------------------
create or replace function public.reserve_stock(
  p_order_id uuid, p_customer text, p_phone text, p_items jsonb,
  p_coupon_code text default null, p_gift_product_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  item jsonb;
  v_pid uuid;
  v_size text;
  v_qty int;
  v_enviado numeric;
  v_unit numeric;
  v_prod products%rowtype;
  v_is_gift boolean;
  v_gift_lines int := 0;
  v_subtotal numeric := 0;      -- itens pagos, antes do cupom
  v_total numeric := 0;
  v_stock int;
  v_reserved int;
  v_coupon_result jsonb;
  v_discount numeric := 0;
  v_linhas jsonb := '[]'::jsonb; -- linhas já com o preço conferido
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Pedido sem itens.';
  end if;
  if jsonb_array_length(p_items) > 60 then
    raise exception 'Pedido com itens demais.';
  end if;
  if coalesce(trim(p_customer), '') = '' or coalesce(trim(p_phone), '') = '' then
    raise exception 'Nome e telefone são obrigatórios.';
  end if;

  for item in select * from jsonb_array_elements(p_items) loop
    v_pid     := (item->>'product_id')::uuid;
    v_size    := item->>'size';
    v_qty     := (item->>'qty')::int;
    v_enviado := coalesce((item->>'price')::numeric, 0);

    if v_qty is null or v_qty < 1 or v_qty > 50 then
      raise exception 'Quantidade inválida.';
    end if;

    select * into v_prod from products where id = v_pid and show_in_catalog = true;
    if not found then
      raise exception 'Produto indisponível. Atualize a página e tente de novo.';
    end if;

    v_is_gift := p_gift_product_id is not null and v_pid = p_gift_product_id and v_enviado = 0;

    if v_is_gift then
      v_gift_lines := v_gift_lines + 1;
      if v_gift_lines > 1 or v_qty <> 1 then
        raise exception 'Brinde inválido.';
      end if;
      v_unit := 0;
    else
      v_unit := v_prod.sale_price;
      if v_prod.discount_type = 'percent' and v_qty >= coalesce(v_prod.discount_min_qty, 1) then
        v_unit := v_prod.sale_price * (1 - coalesce(v_prod.discount_value, 0) / 100.0);
      elsif v_prod.discount_type = 'fixed' and v_qty >= coalesce(v_prod.discount_min_qty, 1) then
        v_unit := greatest(0, v_prod.sale_price - coalesce(v_prod.discount_value, 0));
      end if;
      if v_unit is null or v_unit <= 0 then
        raise exception 'Produto sem preço. Atualize a página e tente de novo.';
      end if;
      -- 1 centavo de folga pro arredondamento de ponto flutuante do navegador
      if abs(v_enviado - v_unit) > 0.01 then
        raise exception 'O preço de um item mudou. Atualize a página e tente de novo.';
      end if;
      v_subtotal := v_subtotal + v_qty * v_unit;
    end if;

    select stock, coalesce(reserved, 0) into v_stock, v_reserved
      from product_sizes
      where product_id = v_pid and size = v_size
      for update;
    if v_stock is null then
      raise exception 'Variante de produto não encontrada';
    end if;
    if (v_stock - v_reserved) < v_qty then
      raise exception 'Estoque insuficiente para o item %', v_size;
    end if;
    update product_sizes set reserved = coalesce(reserved, 0) + v_qty
      where product_id = v_pid and size = v_size;

    v_linhas := v_linhas || jsonb_build_object('product_id', v_pid, 'size', v_size, 'qty', v_qty, 'price', v_unit);
  end loop;

  if v_subtotal <= 0 then
    raise exception 'Pedido sem itens pagos.';
  end if;

  if v_gift_lines > 0 and not exists (
      select 1 from gift_rules
       where active is not false and gift_product_id = p_gift_product_id and min_total <= v_subtotal) then
    raise exception 'Brinde indisponível para este pedido. Atualize a página e tente de novo.';
  end if;
  if v_gift_lines = 0 then
    p_gift_product_id := null;  -- brinde só fica no pedido se veio a linha dele
  end if;

  v_total := round(v_subtotal, 2);

  if p_coupon_code is not null and length(trim(p_coupon_code)) > 0 then
    v_coupon_result := validate_coupon(p_coupon_code, v_total);
    if (v_coupon_result->>'valid')::boolean then
      v_discount := (v_coupon_result->>'discount_amount')::numeric;
      v_total := greatest(0, v_total - v_discount);
    else
      p_coupon_code := null;
      v_discount := 0;
    end if;
  else
    p_coupon_code := null;
  end if;

  insert into orders (id, customer, phone, total, status, coupon_code, discount_amount, gift_product_id)
    values (p_order_id, left(trim(p_customer), 200), left(trim(p_phone), 30), v_total, 'pendente', p_coupon_code, v_discount, p_gift_product_id);

  for item in select * from jsonb_array_elements(v_linhas) loop
    insert into order_items (order_id, product_id, size, qty, price)
      values (p_order_id, (item->>'product_id')::uuid, item->>'size', (item->>'qty')::int, (item->>'price')::numeric);
  end loop;

  return jsonb_build_object('order_id', p_order_id, 'total', v_total, 'discount_amount', v_discount, 'coupon_applied', p_coupon_code is not null);
end;
$$;

-- ---------------------------------------------------------------------
-- C. attach_payment_receipt: só https, só o método do cartão, tamanhos
--    limitados. (A conferência do pagamento continua sendo do navegador do
--    cliente - o admin PRECISA conferir na InfinitePay antes de confirmar;
--    a tela de Pedidos passa a dizer isso. Mover a conferência pra uma Edge
--    Function fica como melhoria.)
-- ---------------------------------------------------------------------
create or replace function public.attach_payment_receipt(
  p_order_id uuid, p_transaction_nsu text, p_receipt_url text, p_payment_method text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_payment_method is distinct from 'cartao_infinitepay' then
    raise exception 'Método de pagamento inválido.';
  end if;
  if coalesce(p_receipt_url, '') <> '' and (p_receipt_url !~* '^https://[a-z0-9.-]+/' or length(p_receipt_url) > 500) then
    p_receipt_url := null;   -- link estranho: guarda o NSU, descarta o link
  end if;
  update orders
     set transaction_nsu = left(p_transaction_nsu, 100),
         receipt_url     = nullif(p_receipt_url, ''),
         payment_method  = p_payment_method
   where id = p_order_id and status = 'pendente';
end;
$$;

-- ---------------------------------------------------------------------
-- D. "qualquer autenticado" vira "equipe". Mesmos nomes de política, então
--    é drop + create do mesmo nome (create sozinho SOMARIA uma política
--    permissiva em vez de trocar).
-- ---------------------------------------------------------------------
drop policy if exists "staff select customers" on public.customers;
drop policy if exists "staff insert customers" on public.customers;
drop policy if exists "staff update customers" on public.customers;
create policy "staff select customers" on public.customers for select using (public.is_staff());
create policy "staff insert customers" on public.customers for insert with check (public.is_staff());
create policy "staff update customers" on public.customers for update using (public.is_staff()) with check (public.is_staff());

drop policy if exists "staff select orders" on public.orders;
create policy "staff select orders" on public.orders for select using (public.is_staff());

drop policy if exists "staff select order_items" on public.order_items;
create policy "staff select order_items" on public.order_items for select using (public.is_staff());

drop policy if exists "staff insert finance" on public.finance;
create policy "staff insert finance" on public.finance for insert with check (public.is_staff());

-- ---------------------------------------------------------------------
-- E. set_order_*: só mexem em pedido PENDENTE (o id é gerado no navegador
--    do cliente; sem isto, quem soubesse o id reescrevia endereço de pedido
--    já confirmado). Textos com tamanho limitado.
-- ---------------------------------------------------------------------
create or replace function public.set_order_address(
  p_order_id uuid, p_street text, p_number text, p_complement text,
  p_neighborhood text, p_city text, p_state text, p_notes text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update orders set
    address_street = left(p_street, 200), address_number = left(p_number, 30), address_complement = left(p_complement, 120),
    address_neighborhood = left(p_neighborhood, 120), address_city = left(p_city, 120), address_state = left(p_state, 40),
    customer_notes = left(p_notes, 1000)
  where id = p_order_id and status = 'pendente';
end; $$;

create or replace function public.set_order_installments(p_order_id uuid, p_installments integer)
returns void language sql security definer set search_path = public as $$
  update orders set installments = p_installments
   where id = p_order_id and status = 'pendente' and p_installments between 1 and 24;
$$;

create or replace function public.set_order_manual_gift(p_order_id uuid, p_note text)
returns void language sql security definer set search_path = public as $$
  update orders set manual_gift_note = left(p_note, 200) where id = p_order_id and status = 'pendente';
$$;

create or replace function public.set_order_payment_method(p_order_id uuid, p_method text)
returns void language sql security definer set search_path = public as $$
  update public.orders
     set payment_method = left(p_method, 40)
   where id = p_order_id and status = 'pendente'
     and (payment_method is null or payment_method is distinct from 'cartao_infinitepay');
$$;

create or replace function public.set_order_referral_source(p_order_id uuid, p_source text)
returns void language sql security definer set search_path = public as $$
  update public.orders set referral_source = left(p_source, 120) where id = p_order_id and status = 'pendente';
$$;

create or replace function public.set_order_shipping(p_order_id uuid, p_cost numeric, p_carrier text, p_cep text)
returns void language sql security definer set search_path = public as $$
  update public.orders
     set shipping_cost = p_cost, shipping_carrier = left(p_carrier, 80), shipping_cep = left(p_cep, 12)
   where id = p_order_id and status = 'pendente' and p_cost >= 0 and p_cost < 10000;
$$;

-- ---------------------------------------------------------------------
-- F. upsert_customer: cliente que já existe só tem campo VAZIO preenchido.
-- ---------------------------------------------------------------------
create or replace function public.upsert_customer(
  p_name text, p_phone text, p_email text, p_birth_day integer, p_birth_month integer, p_cpf text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if coalesce(trim(p_phone), '') = '' then
    raise exception 'Telefone é obrigatório.';
  end if;
  insert into customers (name, phone, email, birth_day, birth_month, cpf)
    values (left(trim(p_name), 200), left(trim(p_phone), 30), left(p_email, 200), p_birth_day, p_birth_month, left(p_cpf, 20))
  on conflict (phone) do update set
    name        = coalesce(nullif(customers.name, ''),  excluded.name),
    email       = coalesce(nullif(customers.email, ''), nullif(excluded.email, '')),
    birth_day   = coalesce(customers.birth_day,   excluded.birth_day),
    birth_month = coalesce(customers.birth_month, excluded.birth_month),
    cpf         = coalesce(nullif(customers.cpf, ''),   nullif(excluded.cpf, ''))
  returning id into v_id;
  return v_id;
end;
$$;

-- validate_coupon e get_my_orders: corpo igual, só search_path fixo.
alter function public.validate_coupon(text, numeric) set search_path = public;
alter function public.get_my_orders(text)            set search_path = public;

commit;

-- =====================================================================
-- CONFERÊNCIA (rodar depois; tudo tem de dar o esperado entre parênteses)
-- =====================================================================
-- select proname, has_function_privilege('anon', oid, 'EXECUTE') as anon_exec
--   from pg_proc where pronamespace = 'public'::regnamespace
--    and proname in ('adjust_stock','confirm_order','cancel_order','reserve_bag_stock','get_user_id_by_email');
--   (anon_exec = false nas cinco)
-- select tablename, policyname, qual, with_check from pg_policies
--   where schemaname='public' and (qual like '%auth.role()%' or with_check like '%auth.role()%');
--   (nenhuma linha)
