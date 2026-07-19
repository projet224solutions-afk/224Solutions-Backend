/**
 * 📱 SMS SERVICE — passerelle multi-fournisseurs (Orange multi-pays → Twilio → Edge)
 *
 * Ordre de tentative (bascule au fournisseur suivant, JAMAIS d'échec silencieux) :
 *   0. ORANGE (si activé ET pays du destinataire configuré) — sender/solde propres
 *      à chaque pays via ORANGE_SMS_{ISO}_*. Un pays non configuré/désactivé ou un
 *      solde épuisé → refus propre → on bascule.
 *   1. Si le BACKEND a des clés Twilio (TWILIO_ACCOUNT_SID/AUTH_TOKEN + un
 *      expéditeur), on appelle Twilio directement.
 *   2. SINON, Edge Function Supabase `send-sms` (secrets Twilio du projet).
 *
 * Renvoie { ok, error } avec le message RÉEL du fournisseur (utile pour diagnostiquer :
 * « Invalid From Number », crédit épuisé, numéro non vérifié en trial…).
 */
import { env } from '../config/env.js';
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';
import { orangeSend } from './sms/orangeSms.js';

// Formatage E.164 pan-africain : logique pure extraite dans phoneFormat.ts (testable sans env).
// Ré-exporté ici pour ne pas casser les imports existants (`from '../services/sms.service.js'`).
export {
  formatPhoneIntl,
  dialCodeForCountry,
  COUNTRY_DIAL_CODES,
  DEFAULT_COUNTRY_ISO,
} from './phoneFormat.js';
import { formatPhoneIntl } from './phoneFormat.js';

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

export async function sendSms(to: string, message: string, countryCode?: string): Promise<{ ok: boolean; error?: string }> {
  if (!to || !message) return { ok: false, error: 'Destinataire ou message manquant' };
  const formattedPhone = formatPhoneIntl(to, countryCode);

  // ── Fournisseur 0 : Orange (multi-pays) ──────────────────────────────────
  // Tenté d'abord quand il est activé ; un refus (pays non configuré / solde
  // épuisé / échec API) fait BASCULER vers Twilio/Edge, jamais échouer en silence.
  try {
    const orange = await orangeSend(to, message, countryCode);
    if (orange.ok) return { ok: true };
    if (!orange.skipped) {
      logger.warn(`[SMS] Orange refus ${formattedPhone} (${orange.code}: ${orange.error}) → bascule fournisseur suivant`);
    }
  } catch (err: any) {
    logger.warn(`[SMS] Orange exception ${formattedPhone}: ${err?.message} → bascule`);
  }

  // ── Fournisseurs 1 & 2 : Twilio backend, sinon Edge ──────────────────────
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
