-- Endereco completo do pedido (hoje o checkout so guardava o CEP em orders.shipping_cep)
-- e observacoes do cliente, usados na etiqueta de envio.
alter table orders add column if not exists address_street text;
alter table orders add column if not exists address_number text;
alter table orders add column if not exists address_complement text;
alter table orders add column if not exists address_neighborhood text;
alter table orders add column if not exists address_city text;
alter table orders add column if not exists address_state text;
alter table orders add column if not exists customer_notes text;

-- RPC nova (nao mexe em reserve_stock/set_order_shipping existentes) para o catalogo publico
-- gravar o endereco completo logo apos criar o pedido, mesmo padrao de set_order_referral_source.
create or replace function set_order_address(
  p_order_id uuid,
  p_street text,
  p_number text,
  p_complement text,
  p_neighborhood text,
  p_city text,
  p_state text,
  p_notes text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update orders set
    address_street = p_street,
    address_number = p_number,
    address_complement = p_complement,
    address_neighborhood = p_neighborhood,
    address_city = p_city,
    address_state = p_state,
    customer_notes = p_notes
  where id = p_order_id;
end;
$$;

grant execute on function set_order_address(uuid,text,text,text,text,text,text,text) to anon, authenticated;
