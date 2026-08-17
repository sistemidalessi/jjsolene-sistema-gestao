-- =====================================================================
-- ANONIMIZAÇÃO DO PROJETO DE DEMONSTRAÇÃO
-- =====================================================================
--
-- Roda UMA VEZ no projeto Supabase de DEMONSTRAÇÃO, logo depois de
-- restaurar a cópia do banco de produção e ANTES de publicar o link.
--
-- ⚠️  ESTE SCRIPT DESTRÓI DADOS. Se rodar por engano no projeto de
--     produção, apaga as conversas do Atendimento e troca o nome, o
--     telefone, o CPF e o endereço de todas as clientes por dados
--     falsos — sem volta.
--
-- Por isso ele se recusa a rodar enquanto o banco não estiver marcado
-- como demonstração. No projeto de demonstração, rode antes:
--
--     create table if not exists este_banco_e_demo ();
--
-- Essa tabela não existe (e não deve ser criada) em produção — é a
-- trava que separa os dois bancos.
--
-- Passo a passo completo em docs/demo-setup.md
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Trava de segurança
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.este_banco_e_demo') is null then
    raise exception
      'ABORTADO: este banco não está marcado como demonstração. Se ele É o banco de demonstração, rode "create table este_banco_e_demo ();" e tente de novo. Se você está no banco de PRODUÇÃO, não rode este script.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Geradores de dado falso
--
-- São determinísticos: o mesmo valor de origem sempre vira o mesmo
-- valor falso. Assim "Maria Souza" continua sendo a mesma pessoa em
-- customers, orders e sales — a demonstração continua fazendo sentido,
-- só que com outra identidade.
-- ---------------------------------------------------------------------
create or replace function demo_nome(origem text) returns text as $$
  select (array['Ana','Beatriz','Camila','Daniela','Eduarda','Fernanda',
                'Gabriela','Helena','Isabela','Juliana','Larissa','Mariana',
                'Natália','Patrícia','Rafaela','Sofia','Tatiane','Vanessa',
                'Bruno','Carlos','Diego','Felipe','Gustavo','Rodrigo']
         )[1 + (abs(hashtext(coalesce(origem,'x'))) % 24)]
      || ' ' ||
         (array['Almeida','Barbosa','Cardoso','Duarte','Esteves','Ferreira',
                'Gomes','Henriques','Iglesias','Jardim','Klein','Lima',
                'Machado','Nogueira','Oliveira','Pereira','Queiroz','Ramos',
                'Santos','Teixeira']
         )[1 + (abs(hashtext(coalesce(origem,'x') || '.sobrenome')) % 20)]
$$ language sql immutable;

-- Celular de São Paulo, faixa 9xxxx-xxxx, sempre inventado.
create or replace function demo_telefone(origem text) returns text as $$
  select '(11) 9' ||
         lpad((abs(hashtext(coalesce(origem,'x') || '.fone')) % 10000)::text, 4, '0') ||
         '-' ||
         lpad((abs(hashtext(coalesce(origem,'x') || '.fone2')) % 10000)::text, 4, '0')
$$ language sql immutable;

-- CPF com dígito verificador propositalmente inválido: parece um CPF na
-- tela, mas não bate com o de ninguém de verdade.
create or replace function demo_cpf(origem text) returns text as $$
  select lpad((abs(hashtext(coalesce(origem,'x') || '.cpf')) % 1000)::text, 3, '0') || '.' ||
         lpad((abs(hashtext(coalesce(origem,'x') || '.cpf2')) % 1000)::text, 3, '0') || '.' ||
         lpad((abs(hashtext(coalesce(origem,'x') || '.cpf3')) % 1000)::text, 3, '0') || '-00'
$$ language sql immutable;

create or replace function demo_email(origem text) returns text as $$
  select lower(replace(demo_nome(origem), ' ', '.')) || '@exemplo.com.br'
$$ language sql immutable;

create or replace function demo_rua(origem text) returns text as $$
  select (array['Rua das Acácias','Rua Projetada','Avenida das Palmeiras',
                'Rua dos Ipês','Travessa São João','Alameda dos Cedros',
                'Rua Quinze de Novembro','Avenida Central']
         )[1 + (abs(hashtext(coalesce(origem,'x') || '.rua')) % 8)]
$$ language sql immutable;

-- Razão social falsa, pra fornecedor (que é empresa, não pessoa).
create or replace function demo_empresa(origem text) returns text as $$
  select (array['Malharia','Confecções','Têxtil','Distribuidora','Atacado',
                'Indústria','Comércio','Fábrica']
         )[1 + (abs(hashtext(coalesce(origem,'x') || '.emp')) % 8)]
      || ' ' ||
         (array['Aurora','Bandeirante','Céu Azul','Diamante','Estrela',
                'Firenze','Girassol','Horizonte','Ipiranga','Jade']
         )[1 + (abs(hashtext(coalesce(origem,'x') || '.emp2')) % 10)]
      || ' Ltda'
$$ language sql immutable;

-- ---------------------------------------------------------------------
-- 2. O que não dá pra mascarar: apaga
--
-- Conversa de WhatsApp é texto livre — a cliente manda o endereço, o
-- comprovante, o nome da filha. Não existe UPDATE que limpe isso com
-- segurança, então o Atendimento começa vazio na demonstração.
-- ---------------------------------------------------------------------
delete from messages;
delete from conversations;

-- Lista de espera e usos de cupom guardam contato de quem não chegou a
-- virar cliente. Não fazem falta na demonstração.
delete from waitlist;
delete from coupon_uses;

-- Tokens OAuth da transportadora (Melhor Envio). São credenciais reais
-- da conta da JJ Solene — nunca podem existir no projeto público.
delete from shipping_tokens;

-- ---------------------------------------------------------------------
-- 3. Anonimização dinâmica
--
-- O schema deste sistema não é versionado, então o script não assume
-- lista fixa de tabelas: procura no catálogo do Postgres toda coluna
-- com nome conhecido de dado pessoal e trata onde encontrar. Coluna
-- nova criada amanhã com um desses nomes já entra sozinha.
-- ---------------------------------------------------------------------
do $$
declare
  r record;
  -- (coluna, gerador). "name" fica de fora daqui de propósito: products.name e
  -- categories.name são o catálogo e precisam continuar reais. As tabelas em que
  -- "name" É dado pessoal (customers, fornecedores, sellers, profiles) são
  -- tratadas uma a uma na seção 6 — NÃO basta esta lista.
  regras constant text[][] := array[
    ['customer_name',  'demo_nome'],
    ['customer',       'demo_nome'],
    ['pix_titular',    'demo_nome'],
    ['contact',        'demo_nome'],   -- fornecedores.contact = pessoa de contato
    ['address',        'demo_rua'],    -- fornecedores.address
    ['phone',          'demo_telefone'],
    ['customer_phone', 'demo_telefone'],
    ['whatsapp',       'demo_telefone'],
    ['attendant1_phone','demo_telefone'],
    ['attendant2_phone','demo_telefone'],
    ['cpf',            'demo_cpf'],
    ['customer_doc',   'demo_cpf'],
    ['email',          'demo_email'],
    ['street',         'demo_rua'],
    ['address_street', 'demo_rua']
  ];
  i int;
begin
  for i in 1 .. array_length(regras, 1) loop
    for r in
      select c.table_name, c.column_name
        from information_schema.columns c
        join information_schema.tables t
          on t.table_schema = c.table_schema and t.table_name = c.table_name
       where c.table_schema = 'public'
         and t.table_type = 'BASE TABLE'
         and c.column_name = regras[i][1]
         and c.data_type in ('text','character varying')
    loop
      execute format(
        'update public.%I set %I = public.%I(%I) where %I is not null and %I <> %L',
        r.table_name, r.column_name, regras[i][2],
        r.column_name, r.column_name, r.column_name, ''
      );
      raise notice 'anonimizado: %.% (%)', r.table_name, r.column_name, regras[i][2];
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. Campos de texto livre e o resto do endereço
--
-- Cidade e estado ficam como estão: sozinhos não identificam ninguém e
-- dão realismo ao frete e à etiqueta. Número e complemento viram um
-- valor fixo, e as observações do pedido são apagadas — é onde a
-- cliente escreve "deixar com a vizinha do 42, ela se chama...".
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select c.table_name, c.column_name
      from information_schema.columns c
      join information_schema.tables t
        on t.table_schema = c.table_schema and t.table_name = c.table_name
     where c.table_schema = 'public'
       and t.table_type = 'BASE TABLE'
       and c.column_name in ('number','address_number','complement',
                             'address_complement','cep','customer_notes',
                             'last_message_preview','notes','observacao')
       and c.data_type in ('text','character varying')
  loop
    execute format(
      'update public.%I set %I = %L where %I is not null',
      r.table_name, r.column_name,
      case r.column_name
        when 'cep' then '01310-100'
        when 'number' then '100'
        when 'address_number' then '100'
        else ''
      end,
      r.column_name
    );
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 5. Chave Pix
--
-- A chave Pix da loja costuma ser o CNPJ, o celular ou o e-mail do
-- titular — e no catálogo público ela aparece na tela de pagamento.
-- Numa demonstração aberta, isso é conta bancária real exposta e,
-- pior, alguém pode pagar de verdade achando que está testando.
-- ---------------------------------------------------------------------
update settings set pix_key = 'demonstracao@exemplo.com.br';

-- ---------------------------------------------------------------------
-- 6. Colunas "name" que são dado pessoal
--
-- A seção 3 não toca em nenhuma coluna chamada "name", pra não estragar
-- products.name e categories.name. Então cada tabela em que "name" é
-- gente (ou empresa) precisa aparecer aqui explicitamente. Se um dia
-- surgir tabela nova com nome de pessoa em "name", acrescente na lista.
--
--   customers    — a cliente. É o dado mais sensível do banco inteiro.
--   fornecedores — razão social do fornecedor; junto com purchases,
--                  entrega de quem a loja compra e por quanto.
--   sellers      — quem vende.
--   profiles     — quem tem login; o vínculo continua pelo id.
-- ---------------------------------------------------------------------
update customers    set name = demo_nome(coalesce(name, id::text));
update fornecedores set name = demo_empresa(coalesce(name, id::text));
update sellers      set name = demo_nome(coalesce(name, id::text));
update profiles     set name = demo_nome(coalesce(name, id::text));

-- ---------------------------------------------------------------------
-- 7. Limpeza dos geradores
-- ---------------------------------------------------------------------
drop function if exists demo_nome(text);
drop function if exists demo_telefone(text);
drop function if exists demo_cpf(text);
drop function if exists demo_email(text);
drop function if exists demo_rua(text);
drop function if exists demo_empresa(text);

commit;

-- =====================================================================
-- CONFERÊNCIA — rode depois e leia o resultado antes de publicar o link
-- =====================================================================
-- Todas devem voltar VAZIAS. Qualquer linha aqui é dado real que sobrou.

-- Conversas e tokens de transportadora
select 'conversations' as onde, count(*) from conversations
union all select 'messages', count(*) from messages
union all select 'shipping_tokens', count(*) from shipping_tokens
union all select 'waitlist', count(*) from waitlist;

-- Telefone que não está no formato falso "(11) 9xxxx-xxxx"
select 'customers.phone' as onde, phone from customers
 where phone is not null and phone <> '' and phone !~ '^\(11\) 9\d{4}-\d{4}$'
union all
select 'orders.customer_phone', customer_phone from orders
 where customer_phone is not null and customer_phone <> ''
   and customer_phone !~ '^\(11\) 9\d{4}-\d{4}$';

-- E-mail que não é @exemplo.com.br
select 'customers.email' as onde, email from customers
 where email is not null and email <> '' and email not like '%@exemplo.com.br';

-- Olhada final, com olho humano. NENHUM nome aqui pode ser conhecido seu —
-- nem de cliente, nem de fornecedor, nem da equipe.
select name, phone, email, cpf, street, city from customers limit 20;
select customer_name, customer_phone, address_street, address_city from orders limit 20;
select name, contact, phone, address from fornecedores limit 20;
select name from sellers;
select name from profiles;

-- Por que estas três últimas existem: a seção 3 ignora toda coluna chamada
-- "name" (pra preservar produtos e categorias), então customers, fornecedores,
-- sellers e profiles dependem da seção 6 tratar cada uma nominalmente. Se
-- alguém acrescentar tabela com nome de pessoa em "name" e esquecer da seção 6,
-- é aqui que isso aparece. Numa versão anterior deste script era exatamente o
-- que acontecia com customers.name: todo o resto do cadastro virava falso e o
-- nome real de cada cliente continuava no banco.
