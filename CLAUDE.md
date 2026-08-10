# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file admin/back-office web app for "JJ Solene" (a clothing/fashion business): inventory,
purchases, sales, sellers/commissions, customers, marketing, finance, invoices, a personal task
calendar, catalog publishing, and omnichannel customer service (Atendimento). The entire
application — HTML, CSS, and JS — lives in **`index.html`** (~3300 lines). There is no build
system, package manager, or bundler for the app itself, and no test suite in this repo; the one
piece with its own deploy step is the small set of Supabase Edge Functions described under
Architecture below.

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
- To preview the *public catalog* specifically (not just the admin app) without a full publish
  cycle: extract the `CATALOG_CSS` / `CATALOG_JS` string-array constants and the `buildCatalogHTML`
  function out of `index.html`, join each array with `'\n'` (they're stored as `[...].join('\n')`),
  and evaluate `buildCatalogHTML(DEFAULT_SB_URL, DEFAULT_SB_ANON)` in Node to get the standalone
  HTML — this is what `catalogo/index.html` itself is.

## Architecture

**Backend:** [Supabase](https://supabase.com) (Postgres + Auth + Storage), loaded from the
`@supabase/supabase-js@2` CDN script. Almost all data access happens client-side through the
Supabase JS client (`SUPA` in the admin app, `sb` inside the generated catalog), with every
admin-side call wrapped in the `q()` helper (`index.html:~225`), which unwraps `{ data, error }`,
toasts on error, and rethrows. The exceptions are three Supabase Edge Functions under
`supabase/functions/` (Deno, project ref `pcvcpylcpuvprpkydbxf`), used for the Atendimento module
and for shipping: `meta-webhook` (public, no Supabase JWT; verifies Meta's HMAC signature on the
request body instead) receives inbound WhatsApp/Instagram/Messenger events from Meta, and
`meta-send` (requires the caller's Supabase session JWT, re-validates conversation visibility
itself since it runs under service role and bypasses RLS) sends outbound messages/templates.
Shared helpers for those two live in `supabase/functions/_shared/meta.ts`. Deploy steps and
required secrets are in `docs/atendimento-deploy.md` / `docs/atendimento-setup-meta.md`; schema in
`docs/atendimento-schema.sql`. The third, `melhor-envio-callback` (public), handles the Melhor
Envio OAuth callback (exchanges the authorization `code` for tokens, stored in the single-row
`shipping_tokens` table) and, via a separate POST path, quotes shipping for the public catalog's
checkout — both the admin app and the catalog call it directly by URL rather than through
`SUPA`/`sb`, since it's plain shipping-carrier API proxying, not a Postgres RPC.

- Default project credentials are hardcoded (`DEFAULT_SB_URL` / `DEFAULT_SB_ANON`) so the app works
  out of the box. The anon key is safe to expose — access is gated by Postgres Row Level Security
  (RLS), not by hiding the key. **RLS is real and enforced** (as of the access-levels work below):
  don't assume "it's just the anon key" means anything goes.
- A user can instead paste their own project's URL/anon key on the "Conectar" screen
  (`renderConnectScreen`); cached in `localStorage` (`jjsolene_sb_url` / `jjsolene_sb_anon`).
- The Postgres schema is **not** version-controlled in this repo — it lives in the Supabase project.
  Tables used (via `SUPA.from(...)`): `settings`, `categories`, `products`, `product_media`,
  `product_sizes`, `purchases`, `purchase_items`, `sales`, `sale_items`, `orders`, `order_items`,
  `sellers`, `commission_payments`, `customers`, `banners`, `gift_rules`, `coupons`, `coupon_uses`,
  `waitlist`, `finance`, `recurring_expenses`, `invoices`, `fornecedores`, `profiles`, `tasks`,
  `cashback_ledger`.
- Postgres RPC functions (all `security definer`, so they bypass RLS for their own controlled
  writes — this is how the public, unauthenticated catalog can still create orders/customers):
  `reserve_stock`, `confirm_order`, `cancel_order`, `validate_coupon`, `upsert_customer`,
  `attach_payment_receipt`, `adjust_stock`, `set_order_referral_source`, `is_admin`,
  `current_seller_id`, `get_user_id_by_email`. Their SQL bodies aren't in this repo; if a change
  needs to touch one, ask the owner to paste `pg_get_functiondef('name'::regproc)` output first
  rather than guessing — `reserve_stock`/`confirm_order` in particular do multi-step stock/finance
  work that's risky to reconstruct blind.
- **`confirm_order` writes into `sales`/`sale_items`** (with `order_id` and `phone` set) — the
  `sales` table is the single source of truth for *all* revenue (manual + catalog), not just manual
  "Vendas" entries. Don't double-count by also summing `orders`.

**Access levels (Admin / Comercial):** `profiles` table maps `auth.users.id` → `role` (`'admin'` |
`'comercial'`) and, for comercial users, → `seller_id`. `currentProfile` (global) is loaded once at
login in `enterApp()`; `COMERCIAL_ALLOWED_TABS` gates both the sidebar (`applyRolePermissions()`)
and `showTab()` navigation. Comercial gets: Pedidos, Estoque (read-only), Vendas (own only,
auto-attributed), Clientes (create/edit, no delete), Agenda (own tasks only). This is enforced at
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
calls `renderTab(name)`, which dispatches to one `render*()` function per section (`renderDashboard`,
`renderAgenda`, `renderPedidos`, `renderEstoque`, `renderCompras`, `renderFornecedores`,
`renderVendas`, `renderVendedores`, `renderClientes`, `renderMarketing`, `renderFinanceiro`,
`renderNF`, `renderCatalogoTab`, `renderConfig`). Each `render*` function fetches its own data and
rebuilds its panel's `innerHTML` from scratch — no component/virtual-DOM layer, just string-built
HTML plus inline `onclick="..."` handlers wired to global functions.

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
