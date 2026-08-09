// Recebe webhooks da Meta (WhatsApp Cloud API, Messenger, Instagram) — endpoint público,
// sem autenticação de usuário (a própria Meta chama direto, sem JWT do Supabase). A única
// segurança real é a validação da assinatura HMAC no corpo da requisição (verifyMetaSignature).
import {
  createAdminClient,
  verifyMetaSignature,
  sendWhatsAppText,
  sendMessengerText,
  fillTemplate,
} from "../_shared/meta.ts";

const META_VERIFY_TOKEN = Deno.env.get("META_VERIFY_TOKEN") ?? "";
const META_APP_SECRET = Deno.env.get("META_APP_SECRET") ?? "";
const WHATSAPP_TOKEN = Deno.env.get("WHATSAPP_TOKEN") ?? "";
const WHATSAPP_PHONE_NUMBER_ID = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID") ?? "";
const PAGE_TOKEN = Deno.env.get("PAGE_TOKEN") ?? "";
const FACEBOOK_PAGE_ID = Deno.env.get("FACEBOOK_PAGE_ID") ?? "";

Deno.serve(async (req) => {
  const url = new URL(req.url);

  if (req.method === "GET") {
    // Handshake de verificação do webhook (feito uma vez, ao registrar a URL na Meta)
    const mode = url.searchParams.get("hub.mode");
    const token = url.searchParams.get("hub.verify_token");
    const challenge = url.searchParams.get("hub.challenge");
    if (mode === "subscribe" && token === META_VERIFY_TOKEN && challenge) {
      return new Response(challenge, { status: 200 });
    }
    return new Response("Forbidden", { status: 403 });
  }

  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  const rawBody = await req.text();
  const signature = req.headers.get("x-hub-signature-256");
  const validSignature = await verifyMetaSignature(rawBody, signature, META_APP_SECRET);
  if (!validSignature) {
    return new Response("Invalid signature", { status: 401 });
  }

  let payload: any;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return new Response("Bad Request", { status: 400 });
  }

  const supabase = createAdminClient();

  try {
    if (payload.object === "whatsapp_business_account") {
      await handleWhatsAppEvent(supabase, payload);
    } else if (payload.object === "instagram" || payload.object === "page") {
      await handleMessengerOrInstagramEvent(supabase, payload, payload.object);
    }
  } catch (e) {
    // Sempre respondemos 200 pra Meta não ficar reenviando o mesmo evento em loop —
    // o erro real fica só no log da function pra investigação depois.
    console.error("Erro ao processar webhook:", e);
  }

  return new Response("OK", { status: 200 });
});

async function handleWhatsAppEvent(supabase: any, payload: any) {
  for (const entry of payload.entry || []) {
    for (const change of entry.changes || []) {
      const value = change.value || {};

      // Recibos de status (entregue/lido/falhou) das mensagens que NÓS enviamos
      for (const status of value.statuses || []) {
        await supabase.from("messages").update({
          status: mapWhatsAppStatus(status.status),
          error_detail: status.errors ? JSON.stringify(status.errors) : null,
        }).eq("meta_message_id", status.id);
      }

      const contacts = value.contacts || [];
      for (const msg of value.messages || []) {
        const fromPhone = msg.from as string; // já vem só com dígitos, com código do país
        const contact = contacts.find((c: any) => c.wa_id === fromPhone);
        const name = contact?.profile?.name || null;
        const body = extractWhatsAppBody(msg);
        if (body == null) continue; // tipos não suportados ainda (mídia, localização etc.)

        const conversation = await upsertConversation(supabase, {
          channel: "whatsapp",
          external_thread_id: fromPhone,
          customer_name: name,
          customer_phone: fromPhone,
          preview: body,
        });

        await insertInboundMessage(supabase, conversation.id, body, msg.id);

        if (conversation.isNew) {
          await maybeSendFirstContactReply(supabase, "whatsapp", fromPhone, conversation.id, name);
        }
        if (conversation.wasIdle) {
          await maybeSendInternalAlert(supabase, "WhatsApp", name || fromPhone, body);
        }
      }
    }
  }
}

function mapWhatsAppStatus(status: string): string {
  if (status === "delivered") return "delivered";
  if (status === "read") return "read";
  if (status === "failed") return "failed";
  return "sent";
}

function extractWhatsAppBody(msg: any): string | null {
  if (msg.type === "text") return msg.text?.body ?? "";
  if (msg.type === "button") return msg.button?.text ?? "";
  if (msg.type === "interactive") {
    return msg.interactive?.button_reply?.title || msg.interactive?.list_reply?.title || null;
  }
  return null;
}

async function handleMessengerOrInstagramEvent(supabase: any, payload: any, object: string) {
  const channel = object === "instagram" ? "instagram" : "messenger";
  for (const entry of payload.entry || []) {
    for (const messaging of entry.messaging || []) {
      if (messaging.message?.is_echo) continue; // eco das nossas próprias mensagens enviadas
      const senderId = messaging.sender?.id;
      const text = messaging.message?.text;
      if (!senderId || !text) continue;

      const conversation = await upsertConversation(supabase, {
        channel,
        external_thread_id: senderId,
        customer_name: null,
        customer_phone: null,
        preview: text,
      });

      await insertInboundMessage(supabase, conversation.id, text, messaging.message?.mid);

      if (conversation.isNew) {
        await maybeSendFirstContactReply(supabase, channel, senderId, conversation.id);
      }
      if (conversation.wasIdle) {
        const channelLabel = channel === "instagram" ? "Instagram" : "Messenger";
        await maybeSendInternalAlert(supabase, channelLabel, senderId, text);
      }
    }
  }
}

async function upsertConversation(
  supabase: any,
  args: {
    channel: string;
    external_thread_id: string;
    customer_name: string | null;
    customer_phone: string | null;
    preview: string;
  },
): Promise<{ id: string; isNew: boolean; wasIdle: boolean }> {
  const { data: existing } = await supabase.from("conversations")
    .select("id, unread_count")
    .eq("channel", args.channel)
    .eq("external_thread_id", args.external_thread_id)
    .maybeSingle();

  if (existing) {
    await supabase.from("conversations").update({
      last_message_at: new Date().toISOString(),
      last_message_preview: args.preview,
      unread_count: (existing.unread_count || 0) + 1,
      resolved_at: null, // nova mensagem reabre a conversa, mesmo se tinha sido marcada como resolvida
    }).eq("id", existing.id);
    return { id: existing.id, isNew: false, wasIdle: (existing.unread_count || 0) === 0 };
  }

  const { data: created, error } = await supabase.from("conversations").insert({
    channel: args.channel,
    external_thread_id: args.external_thread_id,
    customer_name: args.customer_name,
    customer_phone: args.customer_phone,
    last_message_preview: args.preview,
    unread_count: 1,
  }).select("id").single();
  if (error) throw error;
  return { id: created.id, isNew: true, wasIdle: true };
}
// Avisa por WhatsApp um número interno quando chega mensagem nova sem ninguém acompanhando —
// funciona mesmo com o sistema fechado, já que roda no servidor. Opcional: settings.atendimento_alert_phone
// vazio/nulo (ou coluna ainda não criada) desliga o recurso silenciosamente.
async function maybeSendInternalAlert(supabase: any, channelLabel: string, customerLabel: string, body: string) {
  try {
    const { data: settings } = await supabase.from("settings")
      .select("atendimento_alert_phone").eq("id", 1).maybeSingle();
    const alertPhones = String(settings?.atendimento_alert_phone || "")
      .split(",").map((p: string) => p.replace(/\D/g, "")).filter((p: string) => p);
    if (!alertPhones.length) return;
    const preview = body.length > 200 ? body.slice(0, 200) + "…" : body;
    const text = `📩 Nova mensagem (${channelLabel}) de ${customerLabel}:\n"${preview}"`;
    for (const phone of alertPhones) {
      try {
        await sendWhatsAppText(WHATSAPP_PHONE_NUMBER_ID, WHATSAPP_TOKEN, phone, text);
      } catch (e) {
        console.error("Erro ao enviar alerta interno do Atendimento pra " + phone + ":", e);
      }
    }
  } catch (e) {
    console.error("Erro ao enviar alerta interno do Atendimento:", e);
  }
}

async function insertInboundMessage(
  supabase: any,
  conversationId: string,
  body: string,
  metaMessageId?: string,
) {
  // meta_message_id tem índice único parcial — se a Meta reenviar o mesmo evento (comum em
  // timeouts), o insert falha por duplicidade e é só logado, sem duplicar a mensagem.
  const { error } = await supabase.from("messages").insert({
    conversation_id: conversationId,
    direction: "inbound",
    sender_type: "customer",
    body,
    meta_message_id: metaMessageId || null,
  });
  if (error && error.code !== "23505") throw error;
}

async function maybeSendFirstContactReply(
  supabase: any,
  channel: string,
  threadId: string,
  conversationId: string,
  customerName?: string | null,
) {
  const { data: tpl } = await supabase.from("message_templates")
    .select("body, active").eq("key", "first_contact").maybeSingle();
  if (!tpl || !tpl.active) return;

  // Espaço já incluso no valor (não no template) pra "Oi{{customer_name}}!" ficar
  // "Oi Maria!" quando tem nome, ou só "Oi!" quando não tem (Instagram/Messenger, ou
  // contato do WhatsApp sem nome de perfil) — sem sobrar espaço solto nesse segundo caso.
  const text = fillTemplate(tpl.body, { customer_name: customerName ? " " + customerName : "" });
  let metaMessageId: string | null = null;
  try {
    if (channel === "whatsapp") {
      metaMessageId = await sendWhatsAppText(WHATSAPP_PHONE_NUMBER_ID, WHATSAPP_TOKEN, threadId, text);
    } else {
      // Instagram/Messenger: só funciona de verdade depois do App Review aprovar
      // pages_messaging/instagram_manage_messages — até lá, cai no catch abaixo e só loga.
      metaMessageId = await sendMessengerText(FACEBOOK_PAGE_ID, PAGE_TOKEN, threadId, text);
    }
  } catch (e) {
    console.error("Erro ao enviar resposta automática de primeiro contato:", e);
    return;
  }

  await supabase.from("messages").insert({
    conversation_id: conversationId,
    direction: "outbound",
    sender_type: "auto",
    body: text,
    meta_message_id: metaMessageId,
    template_key: "first_contact",
  });
}
