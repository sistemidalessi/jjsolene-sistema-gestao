# Ambiente de demonstração

Como montar uma versão pública do sistema, com dados falsos, para mostrar a
clientes em potencial sem expor nada da JJ Solene.

## Por que num projeto Supabase separado

O sistema tem dois papéis, `admin` e `comercial`, e mesmo o `comercial` enxerga
Pedidos, Clientes, Sacolinha e Atendimento — ou seja, nome, telefone, endereço e
as conversas de WhatsApp de quem compra de verdade. Um login de demonstração no
projeto de produção entregaria isso a qualquer visitante, e o Estoque ainda
mostraria preço de custo, fornecedor e margem.

Não dá pra resolver com papel novo e RLS: a proteção passaria a depender de as
políticas estarem perfeitas para sempre, num banco onde um erro custa dado de
cliente. Um segundo projeto Supabase, com os mesmos objetos e dados falsos,
tira o risco da equação — o pior caso vira "vazou um dado inventado".

A arquitetura já favorece isso: `DEFAULT_SB_URL` e `DEFAULT_SB_ANON` são só duas
constantes no `index.html`, e a tela "Conectar" já aceita qualquer projeto.

## 1. Criar o projeto

No painel do Supabase, **New project**, nome `jjsolene-demo`, mesma região do
projeto de produção (`pcvcpylcpuvprpkydbxf`). Guarde a senha do banco.

## 2. Copiar os objetos e os dados

Copiar em vez de recriar do zero: o schema não é versionado neste repositório
(só os patches em `docs/*.sql`), então recriar à mão sairia diferente do que
está no ar — e uma demonstração que quebra numa tela é pior que nenhuma.

Copie **só o schema `public`**. O schema `auth` fica de fora de propósito: ele
guarda os e-mails e os hashes de senha de quem tem login. O usuário de
demonstração é criado do zero no passo 4.

```bash
supabase db dump --db-url "postgresql://postgres:SENHA_PROD@db.pcvcpylcpuvprpkydbxf.supabase.co:5432/postgres" --schema public -f demo-schema.sql
```

```bash
supabase db dump --db-url "postgresql://postgres:SENHA_PROD@db.pcvcpylcpuvprpkydbxf.supabase.co:5432/postgres" --schema public --data-only -f demo-dados.sql
```

E restaure os dois, nessa ordem, no projeto novo:

```bash
psql "postgresql://postgres:SENHA_DEMO@db.REF_DEMO.supabase.co:5432/postgres" -f demo-schema.sql
```

```bash
psql "postgresql://postgres:SENHA_DEMO@db.REF_DEMO.supabase.co:5432/postgres" -f demo-dados.sql
```

Se a restauração dos dados reclamar de chave estrangeira em `profiles` (ela
aponta pra `auth.users`, que não veio), rode `delete from profiles;` no projeto
de demonstração e siga — o passo 4 recria a linha que importa.

**Apague os dois arquivos `.sql` da sua máquina depois.** São uma cópia completa
do banco de produção, com todo o dado real de cliente dentro, e não podem ficar
soltos numa pasta nem entrar no Git (nunca commite esses arquivos).

## 3. Anonimizar

Ainda no projeto de demonstração, no SQL Editor:

```sql
create table if not exists este_banco_e_demo ();
```

Depois rode [`demo-anonimizacao.sql`](demo-anonimizacao.sql) inteiro. Ele apaga
as conversas do Atendimento, a lista de espera e os tokens da transportadora, e
troca nome, telefone, CPF, e-mail e endereço por valores inventados em toda
tabela onde essas colunas existirem.

A tabela `este_banco_e_demo` é a trava: sem ela o script se recusa a rodar. Ela
não existe em produção, e não deve ser criada lá em hipótese nenhuma.

No fim do arquivo há as consultas de conferência. **Rode e leia o resultado
antes de publicar o link** — as três primeiras têm que voltar vazias; as
seguintes mostram clientes, pedidos, fornecedores, vendedores e equipe para
você bater o olho. Se reconhecer **qualquer** nome, alguma coisa não foi
anonimizada; me avise antes de publicar.

Olhe com atenção especial para os nomes. A anonimização automática ignora, de
propósito, toda coluna chamada `name` (senão apagaria o catálogo de produtos), e
por isso as tabelas em que `name` é gente — `customers`, `fornecedores`,
`sellers`, `profiles` — dependem de estarem listadas à mão na seção 6 do script.
É o ponto mais fácil de passar despercebido.

## 4. Criar o usuário de demonstração

No projeto de demonstração, **Authentication → Add user**:

- E-mail: `demo@sistemidalessi.com.br`
- Senha: uma simples, de uso público — ela vai ficar escrita no README
- Marque **Auto Confirm User** (senão o login trava esperando confirmação)

Copie o `id` do usuário criado e rode, no SQL Editor do mesmo projeto:

```sql
insert into profiles (id, role, name)
values ('COLE_O_ID_AQUI', 'admin', 'Visitante');
```

Papel `admin` de propósito: numa base de dados falsos não há o que proteger, e a
graça da demonstração é a pessoa ver o sistema inteiro, inclusive Financeiro e
Configurações.

## 5. O que NÃO levar para a demonstração

As três Edge Functions ficam **sem deploy** no projeto de demonstração:

- `meta-webhook` e `meta-send` — falam com a API da Meta usando o token da conta
  real da JJ Solene. Um visitante clicando em "responder" mandaria WhatsApp de
  verdade para o telefone que estivesse na tela.
- `melhor-envio-callback` — usa a conta real da transportadora.

Sem elas o Atendimento abre vazio e o frete no catálogo não cota. É o
comportamento certo: são as duas telas que dependem de conta de terceiro, e
numa demonstração ninguém espera que elas funcionem.

## 6. Publicar

Com o projeto pronto, me passe **a URL e a chave anônima** dele (Settings → API).
A chave anônima pode ser pública — quem protege o banco é a RLS, e nesse projeto
não há nada a proteger de qualquer forma.

Com esses dois valores eu monto a versão de demonstração servida pelo GitHub
Pages junto com o resto do repositório, já entrando logada, e troco o
"sob solicitação" do README da Sistemi Dalessi pelo link direto.

## 7. Atualizar a demonstração depois

Quando o sistema ganhar telas novas e a demonstração ficar velha, repita os
passos 2 e 3 (o projeto e o usuário continuam os mesmos). Vale reservar isso
para quando a diferença for grande — cada repetição é uma cópia do banco real
passando pela sua máquina, e esse é o momento de risco do processo.
