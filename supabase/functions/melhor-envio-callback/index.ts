// Edge Function: melhor-envio
// Duas responsabilidades:
//   1) GET  ?code=...        -> callback do OAuth (troca o "code" por access_token/refresh_token)
//   2) POST { cep_destino, itens } -> cotação de frete pro checkout do catálogo público
//   3) POST { acao: "fixar", order_id, service_id, cep } -> grava no pedido pendente o frete RECOTADO aqui, com os
//      itens do pedido e as medidas dos produtos do banco (06/11/2026). Antes o catálogo gravava o preço que o
//      navegador mandava (set_order_shipping), e dava para gravar frete R$ 0,00.
//
// OAuth (06/11/2026): o GET ?code= só é aceito com ?state= igual ao Secret ME_OAUTH_STATE. Sem esse Secret a
// conexão fica FECHADA: antes, qualquer pessoa que montasse a URL de autorização com o client_id da loja trocava o
// token da JJ pelo da conta dela. Para reconectar: gravar ME_OAUTH_STATE (valor aleatório) nos Secrets, abrir a
// URL de autorização com &state=<o mesmo valor>, autorizar, e apagar o Secret.
//
// Variáveis de ambiente necessárias (configurar em Project Settings > Edge Functions > Secrets):
//   MELHORENVIO_CLIENT_ID
//   MELHORENVIO_CLIENT_SECRET
//   MELHORENVIO_REDIRECT_URI   (a mesma URL cadastrada no app do Melhor Envio)
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já ficam disponíveis automaticamente.
//
// Nota (2026-10-30): a cotação ficou FORA DO AR de 09/09 a 30/10 — o token gravado à mão em 10/08
// venceu e a renovação automática falhava sempre com "invalid_client", sem nunca ter funcionado.
// Suspeita principal: segredos gravados a partir do Windows com CR (retorno de carro) no fim do valor,
// que o Melhor Envio rejeita como cliente inválido — por isso TODO valor de ambiente passa por env()
// com trim(). O User-Agent passou a ter o e-mail de contato, que o Melhor Envio exige nas chamadas
// à API. Em novo invalid_client, o log mostra tamanho e presença de CR dos segredos (nunca o valor).
//
// Nota (2026-08-10): a troca do "code" pelo token (exchangeCode) às vezes falha com
// "invalid_client"/"Client authentication failed" especificamente quando chamada a partir
// desta function, mesmo com client_id/secret/redirect_uri corretos e confirmados — a mesma
// chamada funciona normal a partir de outra rede. Suspeita é bloqueio de IP/rede do lado do
// Melhor Envio (não confirmado por eles ainda). Se acontecer de novo: pegue o "code" da URL
// de redirect antes que expire, troque por token manualmente fora da Supabase, e grave direto
// na tabela shipping_tokens (id=1) — não precisa mexer no client_id/secret.

import { createClient } from "jsr:@supabase/supabase-js@2";

const ME_BASE = "https://melhorenvio.com.br";
// Melhor Envio exige User-Agent "Aplicação (e-mail técnico)" em toda chamada.
const UA = "JJ Solene Catalogo (afdalessi@gmail.com)";
// Valor de ambiente sem espaço nem quebra de linha nas pontas (segredo gravado do Windows pode vir com CR).
function env(nome: string): string {
  return (Deno.env.get(nome) ?? "").trim();
}
// Diagnóstico seguro pro log: tamanhos e se havia CR/LF ou espaço nas pontas, nunca o valor.
function diagSegredos(): string {
  const bruto = (n: string) => Deno.env.get(n) ?? "";
  const tudo = bruto("MELHORENVIO_CLIENT_ID") + bruto("MELHORENVIO_CLIENT_SECRET") + bruto("MELHORENVIO_REDIRECT_URI");
  return JSON.stringify({
    client_id_len: bruto("MELHORENVIO_CLIENT_ID").length,
    client_secret_len: bruto("MELHORENVIO_CLIENT_SECRET").length,
    tinha_cr_ou_lf: tudo.includes(String.fromCharCode(13)) || tudo.includes(String.fromCharCode(10)),
    tinha_espaco_nas_pontas: tudo !== tudo.trim(),
  });
}

// comparação sem vazar pelo tempo quanto do segredo bateu
function igual(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

function cors(res: Response) {
  res.headers.set("Access-Control-Allow-Origin", "*");
  res.headers.set("Access-Control-Allow-Headers", "content-type, authorization");
  res.headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  return res;
}

async function saveTokens(tokens: { access_token: string; refresh_token: string; expires_in: number }) {
  const expires_at = new Date(Date.now() + tokens.expires_in * 1000).toISOString();
  await sb.from("shipping_tokens").upsert({
    id: 1,
    provider: "melhor_envio",
    access_token: tokens.access_token,
    refresh_token: tokens.refresh_token,
    expires_at,
    updated_at: new Date().toISOString(),
  });
}

async function exchangeCode(code: string) {
  const r = await fetch(`${ME_BASE}/oauth/token`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json", "User-Agent": UA },
    body: JSON.stringify({
      grant_type: "authorization_code",
      client_id: env("MELHORENVIO_CLIENT_ID"),
      client_secret: env("MELHORENVIO_CLIENT_SECRET"),
      redirect_uri: env("MELHORENVIO_REDIRECT_URI"),
      code,
    }),
  });
  const data = await r.json();
  if (!r.ok) { console.error("melhor-envio: falha ao trocar code", diagSegredos()); throw new Error("Falha ao trocar code por token: " + JSON.stringify(data)); }
  return data;
}

async function refreshToken(refresh_token: string) {
  const r = await fetch(`${ME_BASE}/oauth/token`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json", "User-Agent": UA },
    body: JSON.stringify({
      grant_type: "refresh_token",
      client_id: env("MELHORENVIO_CLIENT_ID"),
      client_secret: env("MELHORENVIO_CLIENT_SECRET"),
      refresh_token,
    }),
  });
  const data = await r.json();
  if (!r.ok) { console.error("melhor-envio: falha ao renovar token", diagSegredos()); throw new Error("Falha ao renovar token: " + JSON.stringify(data)); }
  return data;
}

async function getValidAccessToken(): Promise<string> {
  const { data: row } = await sb.from("shipping_tokens").select("*").eq("id", 1).maybeSingle();
  if (!row || !row.access_token) {
    throw new Error("Nenhum token salvo ainda. Faça a autorização primeiro.");
  }
  const expiresAt = new Date(row.expires_at).getTime();
  if (Date.now() < expiresAt - 60_000) {
    return row.access_token;
  }
  const fresh = await refreshToken(row.refresh_token);
  await saveTokens(fresh);
  return fresh.access_token;
}

async function quoteShipping(cepDestino: string, itens: Array<{ weight_kg: number; length_cm: number; width_cm: number; height_cm: number; qty: number }>) {
  const token = await getValidAccessToken();
  const { data: settings } = await sb.from("settings").select("origin_cep").eq("id", 1).maybeSingle();
  if (!settings?.origin_cep) throw new Error("CEP de origem não configurado em Configurações.");

  const products = itens.flatMap((it) =>
    Array.from({ length: Math.min(50, Math.max(1, Math.floor(Number(it.qty) || 1))) }).map(() => ({
      weight: it.weight_kg || 0.3,
      width: it.width_cm || 20,
      height: it.height_cm || 5,
      length: it.length_cm || 25,
      insurance_value: 0,
      quantity: 1,
    }))
  );

  const r = await fetch(`${ME_BASE}/api/v2/me/shipment/calculate`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      Authorization: `Bearer ${token}`,
      "User-Agent": UA,
    },
    body: JSON.stringify({
      from: { postal_code: settings.origin_cep },
      to: { postal_code: cepDestino },
      products,
    }),
  });
  const data = await r.json();
  if (!r.ok) throw new Error("Falha ao cotar frete: " + JSON.stringify(data));
  // O Melhor Envio nem sempre devolve uma lista: com uma única transportadora na conta vem UM objeto
  // (visto em 30/10/2026: só a JeT, e o catálogo mostrava "nenhuma transportadora"); e quando ele
  // filtra serviços no PHP, a lista vira objeto com chaves "0","2"... O catálogo espera lista, então
  // normaliza aqui — qualquer coisa que tenha id e price vira um item.
  if (Array.isArray(data)) return data;
  if (data && typeof data === "object") {
    if ("id" in data && "price" in data) return [data];
    return Object.values(data).filter((o) => o && typeof o === "object" && "id" in (o as Record<string, unknown>));
  }
  return [];
}

// Limite por IP na cotação (achado jjs-11, 03/11/2026): a função é pública (o catálogo chama sem login) e cada
// cotação gasta a cota da conta do Melhor Envio. Contador no banco (rate_limits / rate_limit_try, SQL em
// docs/seguranca-2026-11-03-limite-do-frete.sql), só a service_role alcança. FALHA ABERTA: sem a função no banco
// ou com erro, deixa passar e loga — limite nunca derruba uma venda honesta. 60 cotações por IP a cada 10 min:
// uma pessoa digitando CEP e mudando quantidade não chega perto; um script chega.
function ipDe(req: Request): string {
  const xff = req.headers.get("x-forwarded-for") || "";
  return (xff.split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "sem-ip").slice(0, 64);
}
async function cabeNoLimite(chave: string, limite: number, janelaS: number): Promise<boolean> {
  try {
    const { data, error } = await sb.rpc("rate_limit_try", { p_key: chave, p_limit: limite, p_window_s: janelaS });
    if (error) { console.error("rate_limit_try falhou (deixando passar):", error.message); return true; }
    return data !== false;
  } catch (e) {
    console.error("rate_limit_try exceção (deixando passar):", e);
    return true;
  }
}
// Frete do pedido recotado aqui (o equivalente do r3d-01 do Rafa): itens do pedido e medidas dos produtos saem do
// banco, o preço sai do Melhor Envio, e só o serviço escolhido e o CEP vêm do catálogo. O brinde (linha de preço 0
// do gift_product_id) fica fora, como o catálogo faz na cotação.
async function fixarFrete(body: Record<string, unknown>) {
  const orderId = String(body.order_id ?? "");
  const cep = String(body.cep ?? "").replace(/\D/g, "");
  const servico = Number(body.service_id);
  if (!/^[0-9a-f-]{36}$/i.test(orderId) || cep.length !== 8 || !Number.isInteger(servico)) return { error: "Pedido, CEP ou serviço inválido." };
  const { data: pedido } = await sb.from("orders").select("id, status, gift_product_id").eq("id", orderId).maybeSingle();
  if (!pedido || pedido.status !== "pendente") return { error: "Pedido não encontrado." };
  const { data: linhas } = await sb.from("order_items").select("product_id, qty, price").eq("order_id", orderId);
  const itens = (linhas || []).filter((l) => !(pedido.gift_product_id && l.product_id === pedido.gift_product_id && Number(l.price) === 0));
  if (!itens.length) return { error: "Pedido sem itens." };
  const { data: prods } = await sb.from("products").select("id, weight_kg, length_cm, width_cm, height_cm").in("id", itens.map((l) => l.product_id));
  const medidas = new Map((prods || []).map((p) => [p.id, p]));
  const opcoes = await quoteShipping(cep, itens.slice(0, 50).map((l) => {
    const p = medidas.get(l.product_id) || {};
    return { weight_kg: p.weight_kg, length_cm: p.length_cm, width_cm: p.width_cm, height_cm: p.height_cm, qty: l.qty };
  }));
  const op = opcoes.find((o) => Number((o as Record<string, unknown>).id) === servico) as Record<string, any> | undefined;
  const preco = Number(op?.price);
  if (!op || op.error || !(preco >= 0)) return { error: "Esse frete não está mais disponível. Calcule de novo." };
  const transportadora = (String(op.company?.name ?? "") + " - " + String(op.name ?? "")).slice(0, 80);
  const { error } = await sb.from("orders").update({ shipping_cost: preco, shipping_carrier: transportadora, shipping_cep: cep })
    .eq("id", orderId).eq("status", "pendente");
  if (error) { console.error("fixar frete: não gravou", error.message); return { error: "Não deu para gravar o frete agora." }; }
  return { ok: true, price: preco, carrier: transportadora };
}

const json = (corpo: unknown, status = 200) =>
  cors(new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json" } }));

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return cors(new Response("ok"));

  try {
    const url = new URL(req.url);

    if (req.method === "GET" && url.searchParams.has("code")) {
      if (!igual(url.searchParams.get("state") || "", env("ME_OAUTH_STATE"))) {
        return cors(new Response(
          "<h2>Conexão com o Melhor Envio fechada.</h2><p>Para conectar de novo, siga o passo a passo no início do código desta função.</p>",
          { status: 403, headers: { "Content-Type": "text/html; charset=utf-8" } }));
      }
      const code = url.searchParams.get("code")!;
      const tokens = await exchangeCode(code);
      await saveTokens(tokens);
      return cors(
        new Response(
          "<h2>Melhor Envio conectado com sucesso!</h2><p>Pode fechar essa aba e voltar pro sistema.</p>",
          { headers: { "Content-Type": "text/html; charset=utf-8" } }
        )
      );
    }

    if (req.method === "POST") {
      if (!(await cabeNoLimite("frete:ip:" + ipDe(req), 60, 600))) {
        return cors(new Response(JSON.stringify({ error: "Muitas consultas de frete seguidas. Espere uns minutos e tente de novo." }),
          { status: 429, headers: { "Content-Type": "application/json", "Retry-After": "600" } }));
      }
      const body = await req.json();
      if (body?.acao === "fixar") return json(await fixarFrete(body));
      const cep = String(body?.cep_destino ?? "").replace(/\D/g, "");
      const itens = Array.isArray(body?.itens) ? body.itens.slice(0, 50) : [];
      if (cep.length !== 8) return json({ error: "CEP inválido." }, 400);
      const result = await quoteShipping(cep, itens);
      return json(result);
    }

    return cors(new Response("Método não suportado", { status: 405 }));
  } catch (e) {
    // O detalhe (resposta do Melhor Envio, token, etc.) vai só pro log da função; quem chamou recebe uma frase
    // genérica (achado jjs-11). O catálogo já mostra a própria mensagem de "não deu pra calcular o frete".
    console.error("melhor-envio-callback:", e?.message || e);
    if (req.method === "GET") {
      return cors(new Response("<h2>Não deu pra conectar o Melhor Envio.</h2><p>O motivo ficou no log da função (Supabase → Edge Functions → melhor-envio-callback → Logs).</p>",
        { status: 500, headers: { "Content-Type": "text/html; charset=utf-8" } }));
    }
    return json({ error: "Não foi possível calcular o frete agora." }, 500);
  }
});