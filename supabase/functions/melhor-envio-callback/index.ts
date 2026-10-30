// Edge Function: melhor-envio
// Duas responsabilidades:
//   1) GET  ?code=...        -> callback do OAuth (troca o "code" por access_token/refresh_token)
//   2) POST { cep_destino, itens } -> cotação de frete pro checkout do catálogo público
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
    Array.from({ length: it.qty || 1 }).map(() => ({
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return cors(new Response("ok"));

  try {
    const url = new URL(req.url);

    if (req.method === "GET" && url.searchParams.has("code")) {
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
      const body = await req.json();
      const result = await quoteShipping(body.cep_destino, body.itens || []);
      return cors(new Response(JSON.stringify(result), { headers: { "Content-Type": "application/json" } }));
    }

    return cors(new Response("Método não suportado", { status: 405 }));
  } catch (e) {
    return cors(
      new Response(JSON.stringify({ error: String(e?.message || e) }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      })
    );
  }
});