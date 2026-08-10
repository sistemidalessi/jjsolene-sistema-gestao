-- Remove os dados de exemplo inseridos para tirar prints/montar o manual e a
-- apresentacao (produtos, cliente, vendedora, fornecedor, pedidos, vendas, compra,
-- bag delivery, financeiro e tarefa de exemplo). Deixa o sistema zerado de novo,
-- pronto para a importacao real.

begin;

-- Pedidos/vendas de exemplo
delete from sale_items where sale_id in (
  '880f4a67-45a5-46f4-8ec3-6b8eed4e0826',
  'fc1a66ad-e05c-496d-babf-db18d3c81352',
  '94003c07-39f7-4396-94ea-32e7dd77d418'
);
delete from order_items where order_id in (
  '3bc2ff50-f2e2-4130-970f-a52f0766d135',
  '0bb19d5c-254a-4212-a7a3-1f86815379fe'
);
delete from finance where ref_id in (
  '880f4a67-45a5-46f4-8ec3-6b8eed4e0826',
  'fc1a66ad-e05c-496d-babf-db18d3c81352',
  '94003c07-39f7-4396-94ea-32e7dd77d418'
);
delete from finance where description = 'Aluguel da loja' and category = 'Aluguel';
delete from tasks where title = 'Repor estoque de pijamas';
delete from sales where id in (
  '880f4a67-45a5-46f4-8ec3-6b8eed4e0826',
  'fc1a66ad-e05c-496d-babf-db18d3c81352',
  '94003c07-39f7-4396-94ea-32e7dd77d418'
);
delete from orders where id in (
  '3bc2ff50-f2e2-4130-970f-a52f0766d135',
  '0bb19d5c-254a-4212-a7a3-1f86815379fe'
);

-- Bag Delivery de exemplo
delete from bag_delivery_items where bag_id = '86b74425-78d0-4646-8201-2467b6585a0e';
delete from bag_deliveries where id = '86b74425-78d0-4646-8201-2467b6585a0e';

-- Compra de exemplo
delete from purchase_items where purchase_id = '9293003a-9279-4ee0-9f00-8e77511db519';
delete from purchases where id = '9293003a-9279-4ee0-9f00-8e77511db519';

-- Cliente, vendedora e fornecedor de exemplo
delete from cashback_ledger where customer_id in (
  '805bb7b0-4b43-4988-a728-a95e3c2a5075',
  'c07eb0ba-59b6-4c71-a6ee-b6171ea2a15b',
  'cc19b026-c41d-4456-8c34-fce88ec9697c'
);
delete from customers where id in (
  '805bb7b0-4b43-4988-a728-a95e3c2a5075',
  'c07eb0ba-59b6-4c71-a6ee-b6171ea2a15b',
  'cc19b026-c41d-4456-8c34-fce88ec9697c'
);
delete from sellers where id = '1f246f96-f41c-40a0-9853-61a817401933';
delete from fornecedores where id = 'ab0d87c3-4a7e-4505-b304-ff1023dd5b25';

-- Produtos de exemplo
delete from product_sizes where product_id in (
  '50e67f80-ce2f-4cfe-84c8-e3ecbe53e760',
  '3a65fec2-8caf-4d89-a61e-cd2f1a71680b',
  '3deb9631-6eca-4612-be1d-a852c161581d',
  'd8e93351-5c26-47c4-b33d-cfd5f1674ae2',
  'b89fbbb4-4b69-4d42-9c2f-d4ae627c5ef2',
  '5b69a3bd-90d5-4f39-9581-7ffaa1b080c9'
);
delete from product_media where product_id in (
  '50e67f80-ce2f-4cfe-84c8-e3ecbe53e760',
  '3a65fec2-8caf-4d89-a61e-cd2f1a71680b',
  '3deb9631-6eca-4612-be1d-a852c161581d',
  'd8e93351-5c26-47c4-b33d-cfd5f1674ae2',
  'b89fbbb4-4b69-4d42-9c2f-d4ae627c5ef2',
  '5b69a3bd-90d5-4f39-9581-7ffaa1b080c9'
);
delete from products where id in (
  '50e67f80-ce2f-4cfe-84c8-e3ecbe53e760',
  '3a65fec2-8caf-4d89-a61e-cd2f1a71680b',
  '3deb9631-6eca-4612-be1d-a852c161581d',
  'd8e93351-5c26-47c4-b33d-cfd5f1674ae2',
  'b89fbbb4-4b69-4d42-9c2f-d4ae627c5ef2',
  '5b69a3bd-90d5-4f39-9581-7ffaa1b080c9'
);

commit;
