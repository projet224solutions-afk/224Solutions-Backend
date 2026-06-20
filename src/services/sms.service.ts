/**
 * 📱 SMS SERVICE — Twilio (backend Node.js) avec repli Edge Function
 *
 * Ordre de tentative :
 *   1. Si le BACKEND a des clés Twilio (TWILIO_ACCOUNT_SID/AUTH_TOKEN + un
 *      expéditeur), on appelle Twilio directement.
 *   2. SINON, on bascule sur l'Edge Function Supabase `send-sms` (qui détient
 *      déjà les secrets Twilio du projet) → pas besoin de dupliquer les clés
 *      dans le backend.
 *
 * Renvoie { ok, error } avec le message RÉEL de Twilio (utile pour diagnostiquer :
 * « Invalid From Number », crédit épuisé, numéro non vérifié en trial…).
 */
import { env } from '../config/env.js';
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';

export function formatPhoneIntl(raw: string): string {
  // E.164 : on retire espaces, tirets, points et parenthèses (les numéros sont souvent
  // stockés « +224 612… » → Twilio rejette les espaces). Le « + » initial est conservé.
  let phone = String(raw || '').replace(/[\s().-]/g, '').trim();
  if (!phone) return phone;
  if (phone.startsWith('6')) phone = `+224${phone}`;
  else if (phone.startsWith('00224')) phone = phone.replace('00224', '+224');
  else if (!phone.startsWith('+')) phone = `+${phone}`;
  return phone;
}

/** Envoi direct via l'API Twilio (clés backend). */
async function sendViaBackendTwilio(toFormatted: string, message: string): Promise<{ ok: boolean; error?: string }> {
  const accountSid = env.TWILIO_ACCOUNT_SID;
  const authToken = env.TWILIO_AUTH_TOKEN;
  const messagingServiceSid = env.TWILIO_MESSAGING_SERVICE_SID;
  const fromPhone = env.TWILIO_PHONE_NUMBER;

  const body = new URLSearchParams({ To: toFormatted, Body: message });
  if (messagingServiceSid) body.append('MessagingServiceSid', messagingServiceSid);
  else body.append('From', fromPhone as string);

  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`, {
    method: 'POST',
    headers: {
      'Authorization': 'Basic ' + Buffer.from(`${accountSid}:${authToken}`).toString('base64'),
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: body.toString(),
  });
  if (!res.ok) {
    let detail = `${res.status}`;
    try { const j = await res.json(); detail = j?.message || JSON.stringify(j); } catch { /* ignore */ }
    return { ok: false, error: detail };
  }
  return { ok: true };
}

/** Repli : Edge Function Supabase `send-sms` (secrets Twilio du projet). */
async function sendViaEdge(toFormatted: string, message: string): Promise<{ ok: boolean; error?: string }> {
  const { data, error } = await supabaseAdmin.functions.invoke('send-sms', {
    body: { to: toFormatted, message },
  });
  if (error) {
    let detail = error.message;
    try { const ctx = await (error as any).context?.json?.(); if (ctx?.error) detail = ctx.error; } catch { /* ignore */ }
    return { ok: false, error: detail };
  }
  if (data && (data as any).success === false) {
    return { ok: false, error: (data as any).error || 'Échec Edge send-sms' };
  }
  return { ok: true };
}

export async function sendSms(to: string, message: string): Promise<{ ok: boolean; error?: string }> {
  if (!to || !message) return { ok: false, error: 'Destinataire ou message manquant' };
  const formattedPhone = formatPhoneIntl(to);

  const hasBackendTwilio = Boolean(
    env.TWILIO_ACCOUNT_SID && env.TWILIO_AUTH_TOKEN && (env.TWILIO_MESSAGING_SERVICE_SID || env.TWILIO_PHONE_NUMBER)
  );

  try {
    const result = hasBackendTwilio
      ? await sendViaBackendTwilio(formattedPhone, message)
      : await sendViaEdge(formattedPhone, message);

    if (!result.ok) {
      logger.warn(`[SMS] échec ${formattedPhone} (${hasBackendTwilio ? 'backend' : 'edge'}): ${result.error}`);
    }
    return result;
  } catch (err: any) {
    logger.warn(`[SMS] exception ${formattedPhone}: ${err?.message}`);
    return { ok: false, error: err?.message || 'Erreur SMS' };
  }
}
