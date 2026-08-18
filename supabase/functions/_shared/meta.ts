// Helpers compartilhados entre meta-webhook e meta-send.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const GRAPH_API_VERSION = "v20.0";

export function createAdminClient() {
  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  return createClient(url, serviceRoleKey, { auth: { persistSession: false } });
}

export async function verifyMetaSignature(
  rawBody: string,
  signatureHeader: string | null,
  appSecret: string,
): Promise<boolean> {
  if (!signatureHeader || !appSecret) return false;
  const expectedHex = signatureHeader.startsWith("sha256=") ? signatureHeader.slice(7) : signatureHeader;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(appSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sigBuffer = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  const computedHex = Array.from(new Uint8Array(sigBuffer)).map((b) => b.toString(16).padStart(2, "0")).join("");
  return timingSafeEqualHex(computedHex, expectedHex);
}

function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function fillTemplate(body: string, params: Record<string, string>): string {
  return body.replace(/\{\{(\w+)\}\}/g, (_, key) => params[key] ?? "");
}

export async function sendWhatsAppText(
  phoneNumberId: string,
  token: string,
  to: string,
  body: string,
): Promise<string | null> {
  const res = await fetch(`https://graph.facebook.com/${GRAPH_API_VERSION}/${phoneNumberId}/messages`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${token}` },
    body: JSON.stringify({ messaging_product: "whatsapp", to, type: "text", text: { body } }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data?.error?.message || "Falha ao enviar mensagem de texto no WhatsApp");
  return data?.messages?.[0]?.id ?? null;
}

export async function sendWhatsAppTemplate(
  phoneNumberId: string,
  token: string,
  to: string,
  templateName: string,
  bodyParams: { name: string; value: string }[],
): Promise<string | null> {
  const res = await fetch(`https://graph.facebook.com/${GRAPH_API_VERSION}/${phoneNumberId}/messages`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${token}` },
    body: JSON.stringify({
      messaging_product: "whatsapp",
      to,
      type: "template",
      template: {
        name: templateName,
        language: { code: "pt_BR" },
        components: [{
          type: "body",
          parameters: bodyParams.map((p) => ({ type: "text", parameter_name: p.name, text: p.value })),
        }],
      },
    }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data?.error?.message || "Falha ao enviar template no WhatsApp");
  return data?.messages?.[0]?.id ?? null;
}

// Instagram/Messenger: implementação completa é a Fase 5 do projeto (extensão de canais),
// feita depois de validar o fluxo do WhatsApp de ponta a ponta com um número de teste. O
// endpoint abaixo segue a Send API da Messenger Platform (reaproveitada pelo Instagram
// quando a conta profissional está vinculada à Página) conforme a documentação atual da
// Meta — revisar contra a documentação oficial no momento de ativar esses canais de
// verdade, pois a Meta muda detalhes de API com alguma frequência e isso não foi testado
// contra credenciais reais ainda.
export async function sendMessengerText(
  pageId: string,
  pageToken: string,
  recipientId: string,
  text: string,
  tag?: string,
): Promise<string | null> {
  // Resposta manual do atendente (sem tag) só é aceita pela Meta dentro da janela de 24h
  // desde a última mensagem da cliente. Avisos automáticos (ex: pedido confirmado) podem
  // chegar depois disso, então usam messaging_type MESSAGE_TAG com a tag POST_PURCHASE_UPDATE
  // — a única categoria da Meta que cobre esse caso (fora da janela, sem ser propaganda).
  const body: Record<string, unknown> = tag
    ? { recipient: { id: recipientId }, message: { text }, messaging_type: "MESSAGE_TAG", tag }
    : { recipient: { id: recipientId }, message: { text }, messaging_type: "RESPONSE" };
  const res = await fetch(`https://graph.facebook.com/${GRAPH_API_VERSION}/${pageId}/messages`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${pageToken}` },
    body: JSON.stringify(body),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data?.error?.message || "Falha ao enviar mensagem no Messenger/Instagram");
  return data?.message_id ?? null;
}
