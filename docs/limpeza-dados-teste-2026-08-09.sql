-- Limpeza dos dados de teste usados durante a configuracao do sistema (Atendimento,
-- pedido/venda de teste, produtos de teste no estoque). Rode tudo de uma vez no
-- Supabase SQL Editor. Ordem respeita as chaves estrangeiras (filhos antes dos pais).
-- Nao apaga nada alem do listado abaixo -- todos os IDs sao do cliente de teste
-- "Anderson F. Dalessi" (telefone 11987190101) e dos 3 produtos de teste.

begin;

-- Pedido/venda de teste
delete from order_items where order_id = '32371f1f-c909-48e9-b490-2281292140ee';
delete from sale_items where sale_id = 'f1038d39-b2e9-44b5-a02c-0559b7cd7e5c';
update sales set invoice_id = null where id = 'f1038d39-b2e9-44b5-a02c-0559b7cd7e5c';
delete from invoices where id = 'cc933848-4271-444f-80f4-84563f926a06';
delete from sales where id = 'f1038d39-b2e9-44b5-a02c-0559b7cd7e5c';
delete from orders where id = '32371f1f-c909-48e9-b490-2281292140ee';

-- Conversa/mensagens de teste no Atendimento
delete from messages where conversation_id = '88eb8539-ba21-4e04-bf89-8a7e733f6fc5';
delete from conversations where id = '88eb8539-ba21-4e04-bf89-8a7e733f6fc5';

-- Cliente de teste
delete from cashback_ledger where customer_id = 'c58f087b-1d9f-4320-a5ce-9cace279bee4';
delete from customers where id = 'c58f087b-1d9f-4320-a5ce-9cace279bee4';

-- 3 produtos de teste no estoque (Conjunto Erika, sdfsafdsfdf, pijama)
delete from product_sizes where product_id in (
  '48c53ce5-fb56-48e5-b2e2-21516d913666',
  'dfa9917c-1710-4ec5-ab3d-07e8d7dd4076',
  '591d487b-6158-43c4-a629-9e44ca91ab2b'
);
delete from product_media where product_id in (
  '48c53ce5-fb56-48e5-b2e2-21516d913666',
  'dfa9917c-1710-4ec5-ab3d-07e8d7dd4076',
  '591d487b-6158-43c4-a629-9e44ca91ab2b'
);
delete from products where id in (
  '48c53ce5-fb56-48e5-b2e2-21516d913666',
  'dfa9917c-1710-4ec5-ab3d-07e8d7dd4076',
  '591d487b-6158-43c4-a629-9e44ca91ab2b'
);

commit;
