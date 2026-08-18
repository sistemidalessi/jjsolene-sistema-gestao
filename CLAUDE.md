# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file admin/back-office web app for "JJ Solene" (a clothing/fashion business): stock,
purchases, sales, bag delivery ("sacolinha"), barcode stock-counts, sellers/commissions, customers,
marketing, finance (incl. bank reconciliation), reports, invoices, a personal task calendar,
catalog publishing, and omnichannel customer service (Atendimento). The entire application — HTML,
CSS, and JS — lives in **`index.html`** (~6800 lines, and growing; note that lines 4783–6240 are the
embedded public-catalog template, not admin code). There is no build system, package manager,
or bundler for the app itself, and no test suite in this repo; the one piece with its own deploy
step is the small set of Supabase Edge Functions described under Architecture below.

The app loads four CDN scripts: `@supabase/supabase-js@2`, `JsBarcode` (barcode rendering for
product labels), `cropperjs` (4:5 crop on the main product photo), and Google's GSI client (one-way
Agenda → Google Calendar sync).

## Hosting — this is live, not just local

Both the admin app and the public catalog are hosted via **GitHub Pages** on this repo (owner:
`sistemidalessi` org — moved here from the personal account `afdalessi-commits` on 2026-08-07;
repo also renamed from `catalogo-jjsolene` to `jjsolene-sistema-gestao` the same day, to reflect
that this is the full management system, not just the catalog — the public catalog is one part of
it, generated from and served alongside the admin app. GitHub Pages URLs are owner/repo-specific
and do **not** redirect across a transfer or rename, so both the old `afdalessi-commits.github.io`
and the old `.../catalogo-jjsolene/` links now 404 — not an issue yet since nothing had been shared
publicly, but if a custom domain gets added later, this note can go away):

- **Sistema (admin)**: `https://sistemidalessi.github.io/jjsolene-sistema-gestao/` — serves
  `index.html` at the repo root directly.
- **Catálogo (público)**: `https://sistemidalessi.github.io/jjsolene-sistema-gestao/catalogo/` —
  serves **`catalogo/index.html`**, a *generated* file (see "Public catalog generator" below).
  Unlike a typical build artifact, this one **is committed to the repo** so GitHub Pages can serve
  it at a stable URL — regenerate and re-commit it whenever `CATALOG_CSS` / `CATALOG_JS` changes.
- Pushing to `main` auto-deploys both (GitHub Pages rebuild, usually live within ~1 minute).
- There used to be a separate local copy the owner opened directly (`sistema-jjsolene.html`,
  outside this repo) — that's deprecated in favor of the hosted links above. If asked to fix
  something and only the hosted version is visible, that's expected now.

## Running / developing

- There is nothing to install or build. Open `index.html` directly in a browser (or serve the repo
  root with a static file server) to work on it locally before pushing.
- All edits happen directly in `index.html`. There is no linter or automated test suite — verify
  changes by reloading in a browser and exercising the actual flow.
- The app talks to a live Supabase project over the network, so testing requires network access.
- **No DDL access**: schema changes (new tables/columns, RLS policies, Postgres functions) cannot
  be applied from the browser/anon key. When a task needs one, write the SQL and have the project
  owner run it in the Supabase SQL Editor — don't assume a migration file exists locally to check.
  `docs/*.sql` is **not** a complete schema, and its files come in two flavours — check which one
  you're reading before trusting it:
  - *Actually run* against the project: `atendimento-schema.sql`, `filtros-catalogo-schema.sql`,
    `pedidos-endereco-etiqueta-schema.sql`, `phibo-import-schema.sql`, plus the dated `limpeza-*`
    cleanup scripts.
  - *Reconstructed from client code*, never run, for the tables that only ever existed in the
    Supabase project: `bag-delivery-schema.sql`, `inventario-schema.sql`, `cashback-schema.sql`,
    `conciliacao-bancaria-schema.sql`, `ncm-reference-schema.sql`. Each carries a header saying so,
    the introspection query to check it against the real schema, and its RLS section commented out
    (a `create policy` under a new name *adds* a permissive policy rather than replacing the
    existing one, so blind-running it would loosen access). Treat these as documentation of what
    the app expects, and as a starting point for recreating the schema in a fresh project.

  When writing new DDL, save it under `docs/` with a descriptive (and, for cleanups, dated) name.
- **Don't edit `catalogo-jjsolene.html` at the repo root** — that's an old backup copy of the
  catalog, kept only for reference. The live one is `catalogo/index.html`, and the source of truth
  for both is `CATALOG_CSS`/`CATALOG_JS` inside `index.html`.
- To preview the *public catalog* specifically (not just the admin app) without a full publish
  cycle: extract the `CATALOG_CSS` / `CATALOG_JS` string-array constants and the `buildCatalogHTML`
  function out of `index.html`, join each array with `'\n'` (they're stored as `[...].join('\n')`),
  and evaluate `buildCatalogHTML(DEFAULT_SB_URL, DEFAULT_SB_ANON)` in Node to get the standalone
  HTML — this is what `catalogo/index.html` itself is. This needs Node on the machine; when it isn't
  available, just open the already-committed `catalogo/index.html` in a browser (it reads live data),
  or use the Catálogo tab's own generate button.

## Architecture

**Backend:** [Supabase](https://supabase.com) (Postgres + Auth + Storage), loaded from the
`@supabase/supabase-js@2` CDN script. Almost all data access happens client-side through the
Supabase JS client (`SUPA` in the admin app, `sb` inside the generated catalog), with every
admin-side call wrapped in the `q()` helper (`index.html:377`), which unwraps `{ data, error }`,
toasts on error, and rethrows. The exceptions are three Supabase Edge Functions under
`supabase/functions/` (Deno, project ref `pcvcpylcpuvprpkydbxf`), used for the Atendimento module
and for shipping: `meta-webhook` (public, no Supabase JWT; verifies Meta's HMAC signature on the
request body instead) receives inbound WhatsApp/Instagram/Messenger events from Meta, and
`meta-send` (requires the caller's Supabase session JWT, re-validates conversation visibility
itself since it runs under service role and bypasses RLS) sends outbound messages/templates. When
the "pedido confirmado" template fires (from `confirmOrderAction`, keyed on the order's phone),
`meta-send` also echoes it, best-effort, to any Instagram/Messenger conversation whose
`conversations.customer_phone` matches that phone — sent via the Messenger Send API with the
`POST_PURCHASE_UPDATE` tag (the one Meta category that allows a business-initiated message outside
the normal 24h reply window), since Instagram/Messenger don't have a phone-based identity the way
WhatsApp does and can only be reached through an existing conversation's PSID/IGSID. Staff link a
phone to a non-WhatsApp conversation manually, from the Atendimento thread view (there's no
automatic way to learn it). This path depends on the Instagram "Gerenciar mensagens e conteúdo no
Instagram" use case being approved in Meta's App Review — until then it just silently does nothing,
without affecting the WhatsApp send. Shared helpers for those two live in
`supabase/functions/_shared/meta.ts`. Deploy steps and
required secrets are in `docs/atendimento-deploy.md` / `docs/atendimento-setup-meta.md`; schema in
`docs/atendimento-schema.sql`. The third, `melhor-envio-callback` (public), handles the Melhor
Envio OAuth callback (exchanges the authorization `code` for tokens, stored in the single-row
`shipping_tokens` table) and, via a separate POST path, quotes shipping for the public catalog's
checkout. Only the **catalog** calls it (directly by URL rather than through `sb`, since it's plain
shipping-carrier API proxying, not a Postgres RPC) — the admin side never hits the shipping API; its
"Etiqueta de Envio" in Pedidos is just a print view built from the order's own address fields.

- Default project credentials are hardcoded (`DEFAULT_SB_URL` / `DEFAULT_SB_ANON`) so the app works
  out of the box. The anon key is safe to expose — access is gated by Postgres Row Level Security
  (RLS), not by hiding the key. **RLS is real and enforced** (as of the access-levels work below):
  don't assume "it's just the anon key" means anything goes.
- A user can instead paste their own project's URL/anon key on the "Conectar" screen
  (`renderConnectScreen`); cached in `localStorage` (`jjsolene_sb_url` / `jjsolene_sb_anon`).
- The Postgres schema is **not** version-controlled in this repo — it lives in the Supabase project.
  Tables used (via `SUPA.from(...)` / `sb.from(...)`), grouped by area:
  - core/catalog: `settings`, `categories`, `products`, `product_media`, `product_sizes`,
    `orders`, `order_items`, `waitlist`, `banners`, `gift_rules`, `coupons`, `coupon_uses`
  - stock & buying: `purchases`, `purchase_items`, `fornecedores`, `inventory_sessions`,
    `inventory_session_items`, `ncm_reference`
  - selling: `sales`, `sale_items`, `sellers`, `commission_payments`, `customers`,
    `bag_deliveries`, `bag_delivery_items`, `cashback_rules`, `cashback_ledger`
  - money: `finance`, `recurring_expenses`, `bank_import_transactions`, `invoices`
  - service & admin: `conversations`, `messages`, `message_templates`, `profiles`, `tasks`,
    plus the single-row `shipping_tokens` (written only by the `melhor-envio-callback` function)
- Postgres RPC functions (all `security definer`, so they bypass RLS for their own controlled
  writes — this is how the public, unauthenticated catalog can still create orders/customers).
  Called from the **catalog**: `reserve_stock`, `validate_coupon`, `upsert_customer`,
  `attach_payment_receipt`, `get_bestseller_counts`, `get_my_orders`, and the post-`reserve_stock`
  order-detail setters `set_order_referral_source`, `set_order_address`, `set_order_shipping`,
  `set_order_payment_method`, `set_order_installments`, `set_order_manual_gift`. Called from the
  **admin app**: `confirm_order`, `cancel_order`, `adjust_stock`, `reserve_bag_stock`,
  `get_user_id_by_email`. Called only from inside RLS policies (never client-side): `is_admin`,
  `current_seller_id`. Their SQL bodies aren't in this repo; if a change needs to touch one, ask the
  owner to paste `pg_get_functiondef('name'::regproc)` output first rather than guessing —
  `reserve_stock`/`confirm_order` in particular do multi-step stock/finance work that's risky to
  reconstruct blind.
- The pattern behind the `set_order_*` family is worth copying: `reserve_stock` isn't safe to modify
  blind, so every new checkout field gets its own tiny setter RPC called right after the reservation
  succeeds, rather than being threaded into `reserve_stock`'s signature.
- **`confirm_order` writes into `sales`/`sale_items`** (with `order_id` and `phone` set) — the
  `sales` table is the single source of truth for *all* revenue (manual + catalog), not just manual
  "Vendas" entries. Don't double-count by also summing `orders`.

**Access levels (Admin / Comercial):** `profiles` table maps `auth.users.id` → `role` (`'admin'` |
`'comercial'`) and, for comercial users, → `seller_id`. `currentProfile` (global) is loaded once at
login in `enterApp()`; `COMERCIAL_ALLOWED_TABS` gates both the sidebar (`applyRolePermissions()`)
and `showTab()` navigation. Comercial currently gets: Pedidos, Atendimento, Estoque (read-only),
Vendas (own only, auto-attributed), Bag Delivery (own bags only — `renderBagDelivery` filters by
`seller_id`), Clientes (create/edit, no delete), Agenda (own tasks only). This is enforced at
the RLS level too, not just hidden in the UI — most tables now have granular per-command policies
(e.g. `customers` allows insert/update to any authenticated user but delete to admin only; `sales`/
`sale_items` restrict comercial to rows matching their own `seller_id` via `current_seller_id()`).
New team members: create their Supabase Auth login first (Authentication → Add user), then grant
access via Configurações → Equipe (resolves email → user id via `get_user_id_by_email` RPC).

**Seller attribution for catalog sales:** sellers can be linked to a discount coupon
(`coupons.seller_id`). A seller's shareable catalog link
(`.../catalogo/?cupom=CODE`) auto-applies their coupon on load (`refCouponCode` in `CATALOG_JS`);
the commission report (`calcComissoes`) sums manual sales by `seller_id` *plus* confirmed orders
whose `coupon_code` matches a seller-linked coupon.

**App shell / navigation:** No client-side router or URL state. The sidebar has one `.nav-item` per
tab (`data-tab="..."`); `showTab(name)` toggles visibility of the matching `#tab-<name>` panel and
calls `renderTab(name)`, which dispatches to one `render*()` function per section. The 18 tabs, in
sidebar order: `dashboard`, `agenda`, `pedidos`, `atendimento`, `estoque`, `inventario`, `compras`,
`fornecedores`, `vendas`, `bagdelivery`, `vendedores`, `clientes`, `marketing`, `financeiro`,
`relatorios`, `nf`, `catalogo`, `config` — each with the matching `render*` function
(`renderBagDelivery` for `bagdelivery`, `renderCatalogoTab` for `catalogo`, `renderNF` for `nf`).
Each `render*` function fetches its own data and rebuilds its panel's `innerHTML` from scratch — no
component/virtual-DOM layer, just string-built HTML plus inline `onclick="..."` handlers wired to
global functions.

**Auth flow:** `boot()` → `initClient()` creates the Supabase client and calls `checkSession()` →
if no session, `renderLoginScreen()` (Supabase Auth email/password); if connection info is missing
entirely, `renderConnectScreen()` first. On success, `enterApp()` loads the caller's `profiles` row
(blocking access with a friendly message if none exists yet), applies role-based UI, and shows the
dashboard (or Pedidos, for comercial).

**Public catalog generator:** `renderCatalogoTab` / `generateCatalog` (Catálogo tab) —
`buildCatalogHTML()` stitches `CATALOG_CSS` and `CATALOG_JS` (large template strings later in the
file) into a self-contained HTML document. The in-app button downloads it locally for the owner to
re-publish by hand if needed, but the **canonical published copy is `catalogo/index.html` in this
repo**, served via GitHub Pages (see "Hosting" above) — regenerate and commit that file as part of
any change to `CATALOG_CSS`/`CATALOG_JS`, don't just leave it to the in-app download. It embeds the
same Supabase URL/anon key and reads products/stock/prices live, so ordinary data changes (new
product, price change, stock) need no republish at all — only visual/template changes do.

Notable catalog behavior: installment text (`installmentLines()`) supports N interest-free
installments plus up to M total with a configurable monthly rate, store-wide (`settings`) or
per-product override (`products.installments_*`); pricing uses `entry_value × cost_index = custo`,
`custo × sale_index = venda`; checkout requires "Como você conheceu a JJ Solene?"
(`orders.referral_source`, set post-`reserve_stock` via `set_order_referral_source` since
`reserve_stock` itself isn't safe to modify blind).

## Modules worth knowing before you touch them

Most tabs are ordinary CRUD over one or two tables. These are the ones with logic that isn't
obvious from the table names:

**Barcodes tie five tabs together.** `generateBarcode(sku, size)` builds `SKU-SIZE` (uppercased,
spaces stripped; falls back to a `JJ<base36 timestamp>` prefix when the product has no SKU) and
stores it on `product_sizes.barcode` when a product is saved. `findProductByBarcode()` resolves it
back, and Estoque, Inventário, Compras, Vendas and Bag Delivery each have their own `scanBarcode*`
entry point on top of it. Anything that changes the barcode format has to consider all of them.
Labels are rendered with `JsBarcode` (CODE128) and printed from the "Impressão de etiquetas"
section, sized for an **Elgin L42 Pro Full, 50×75mm** — several `settings` fields (`website_url`,
`exchange_policy_text`) and product fields (`ref`, `composition`) exist only to appear on that label.

**Inventário** = barcode stock-count sessions. Start a Total or Parcial count (`inventory_sessions`),
scan pieces into `inventory_session_items` (which snapshots `system_stock` at scan time next to
`counted_qty`), then the report diffs system × counted and can push corrections through
`adjust_stock` — per item or all at once — marking each row `corrected` so a second pass can't
double-apply the same delta.

**Bag Delivery** ("sacolinha") = pieces sent to a customer to try at home. Sending a bag moves stock
via `reserve_bag_stock` with a positive `p_delta`; closing it walks each item's decision
(kept/returned) and reverses the reservation with a negative delta for what comes back. It also
prints a promissory note (`printBagPromissoryNote`). Comercial users only see their own bags.

**Cashback** is rule-driven: `cashback_rules` rows have a `type` of `padrao`, `valor_minimo`,
`boas_vindas`, `validade` or `fidelidade` (the last one being 3 tiers keyed on the customer's total
spend), more than one can be active at a time, and `applyCashbackRules()` evaluates every active
rule and applies only the **single best percentage** — it does not stack. It runs on order
confirmation, writes a `credito` row to `cashback_ledger`, and updates `customers.cashback_balance`.

**Bank reconciliation** (inside Financeiro): `parseOFX()` reads an OFX bank statement into
`bank_import_transactions`, upserting on `fitid` with `ignoreDuplicates` so re-importing the same
file is safe. `matchBankTransactions()` then pairs unmatched rows against existing `finance`
entries; whatever stays unmatched can be turned into a new `finance` entry in one click.

**Relatórios**: Curva ABC, giro de estoque, and vendedor(a) × categoria, all driven by one period
selector (`relatoriosPeriodRange()`, default 90 days, `0` meaning everything).

**Agenda → Google Calendar** is a one-way sync. It uses Google Identity Services with an OAuth
client id the owner pastes into Configurações (`settings.google_client_id`), holds the access token
in memory only (`googleAccessToken`, never persisted — reconnect after a reload), and stores the
created event id on `tasks.google_event_id` so later edits PATCH instead of duplicating.

**Phibo importer** (Configurações): `parsePhiboCSV()` is a deliberately naive `;`-split parser for
the supplier's export — it does **not** handle quoted fields or embedded separators, so don't reach
for it as a generic CSV reader. `parseBRNumber()` accepts both `150,00` and `119.90` because
different Phibo exports have arrived in both formats.

## Conventions

- UI copy, all code comments, and variable/data conventions (e.g. date formatting via
  `toLocaleDateString('pt-BR')`, currency via `fmtMoney`) are in Brazilian Portuguese. Keep new UI
  text and comments in pt-BR for consistency.
- Sections of the script are separated by `/* ===== ... ===== */` banner comments — keep new
  top-level functionality organized the same way rather than interleaving unrelated logic.
- Money values are stored/handled as plain numbers and formatted for display only via `fmtMoney`;
  don't format at the data layer.
- Gender-neutral role naming: "Vendedor(a)" (singular) / "Vendedor(es)" (plural), not "vendedora" —
  sellers aren't assumed to be women. Apply this pattern to any new UI text referencing sellers.
- `todayISO()` returns the *local* date (fixed from a UTC bug); don't reintroduce
  `new Date().toISOString()` for "today" — it's wrong in the evening in UTC-negative timezones.
- Every report/list export goes through two shared helpers rather than a PDF library: `downloadCSV`
  (semicolon-separated, quoted, UTF-8 BOM so Excel pt-BR opens it correctly) and `printReport`
  (opens a styled `window.open` document and calls `window.print()`, which is how "PDF" is produced
  everywhere in this app). Reuse them instead of hand-rolling a third export path.
- User-visible data flows into HTML through `escapeHtml()`. Since every panel is built by string
  concatenation, forgetting it is an XSS hole *and* breaks rendering on any name with an apostrophe
  — check new `innerHTML` strings for it.
