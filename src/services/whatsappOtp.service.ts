/**
 * 🟢 WhatsApp OTP — envoi du code de vérification via l'API WhatsApp Business Cloud (Meta).
 *
 * Décision PDG 01/08/2026 : le canal téléphone passe du SMS à WhatsApp (une intégration pour TOUS les
 * pays, sans enregistrement sender-ID par pays). Le SMS est GELÉ (voir services/sms/*). L'email reste le
 * repli pour les numéros sans WhatsApp.
 *
 * SEUL LE TRANSPORT change : la génération/vérif OTP (hash, expiration, tentatives, rate-limit) reste
 * celle du parcours existant. Ce service ne fait qu'ENVOYER un code déjà généré.
 *
 * Fail-closed : sans configuration Meta, renvoie WHATSAPP_NOT_CONFIGURED — JAMAIS un faux « envoyé ».
 * Secrets (token) jamais loggés, jamais commités (process.env uniquement).
 */
import { logger } from '../config/logger.js';

const API_VERSION = process.env.WHATSAPP_API_VERSION || 'v21.0';
const ACCESS_TOKEN = process.env.WHATSAPP_ACCESS_TOKEN || '';
const PHONE_NUMBER_ID = process.env.WHATSAPP_PHONE_NUMBER_ID || '';
const BUSINESS_ACCOUNT_ID = process.env.WHATSAPP_BUSINESS_ACCOUNT_ID || '';
const OTP_TEMPLATE = process.env.WHATSAPP_OTP_TEMPLATE || '';
// Langue du modèle approuvé (doit correspondre EXACTEMENT à la langue choisie à la création du template).
const OTP_LANG = process.env.WHATSAPP_OTP_LANG || 'fr';

export type WhatsAppOtpErrorCode = 'WHATSAPP_NOT_CONFIGURED' | 'WHATSAPP_NO_ACCOUNT' | 'WHATSAPP_TOKEN_EXPIRED' | 'WHATSAPP_SEND_FAILED';
export interface WhatsAppOtpResult {
  success: boolean;
  error_code?: WhatsAppOtpErrorCode;
  error?: string;
}

/** Le canal est-il armé ? (les 3 valeurs indispensables sont présentes). */
export function isWhatsAppConfigured(): boolean {
  return Boolean(ACCESS_TOKEN && PHONE_NUMBER_ID && OTP_TEMPLATE);
}

/** Masque un secret pour le log (garde les 4 derniers). */
function tail4(s: string): string {
  return s ? `…${s.slice(-4)}` : '(vide)';
}

/** Contrôle de config au démarrage — UNE ligne, secrets masqués. */
export function logWhatsAppConfig(): void {
  if (isWhatsAppConfigured()) {
    logger.info(`[whatsapp] configured (phone_number_id=${tail4(PHONE_NUMBER_ID)}, waba=${tail4(BUSINESS_ACCOUNT_ID)}, template=${OTP_TEMPLATE}, lang=${OTP_LANG}, api=${API_VERSION})`);
  } else {
    const missing = [
      !ACCESS_TOKEN && 'WHATSAPP_ACCESS_TOKEN',
      !PHONE_NUMBER_ID && 'WHATSAPP_PHONE_NUMBER_ID',
      !OTP_TEMPLATE && 'WHATSAPP_OTP_TEMPLATE',
    ].filter(Boolean).join(', ');
    logger.warn(`[whatsapp] NOT CONFIGURED (manque: ${missing}) → canal téléphone fail-closed (email disponible)`);
  }
}

/** Numéro E.164 → format Meta (chiffres seuls, sans « + »). */
function toMetaRecipient(phoneE164: string): string {
  return String(phoneE164).replace(/[^\d]/g, '');
}

/**
 * Envoie le code OTP par WhatsApp via un MODÈLE d'authentification (bouton « copier le code » natif).
 * `code` est le code DÉJÀ généré par le parcours OTP existant. Ne génère rien, ne stocke rien.
 */
export async function sendOtpWhatsApp(phoneE164: string, code: string): Promise<WhatsAppOtpResult> {
  if (!isWhatsAppConfigured()) {
    return { success: false, error_code: 'WHATSAPP_NOT_CONFIGURED', error: 'Canal WhatsApp non configuré' };
  }

  const url = `https://graph.facebook.com/${API_VERSION}/${PHONE_NUMBER_ID}/messages`;
  // Modèle d'authentification Meta : le code va dans le paramètre du BODY et dans le bouton COPY_CODE (url).
  const body = {
    messaging_product: 'whatsapp',
    to: toMetaRecipient(phoneE164),
    type: 'template',
    template: {
      name: OTP_TEMPLATE,
      language: { code: OTP_LANG },
      components: [
        { type: 'body', parameters: [{ type: 'text', text: code }] },
        { type: 'button', sub_type: 'url', index: '0', parameters: [{ type: 'text', text: code }] },
      ],
    },
  };

  let lastErr = '';
  // Timeout + 2 retries bornés (réseau/5xx transitoires ; on NE rejoue PAS une erreur métier 4xx).
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${ACCESS_TOKEN}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10000),
      });

      if (res.ok) return { success: true };

      const raw = (await res.text()).slice(0, 600);
      let meta: { error?: { code?: number; message?: string; error_subcode?: number } } = {};
      try { meta = JSON.parse(raw); } catch { /* corps non-JSON */ }
      const mCode = meta.error?.code;
      const mSub = meta.error?.error_subcode;
      const mMsg = meta.error?.message || raw;
      lastErr = `${res.status} code=${mCode} sub=${mSub}`;

      // 401 / session expirée : token temporaire (dev) périmé OU token permanent révoqué (prod).
      if (res.status === 401 || /session has expired|access token/i.test(mMsg)) {
        logger.error('[whatsapp] TOKEN EXPIRÉ/INVALIDE — régénérer (dev, 24h) ou passer au token permanent (prod, Utilisateur système). Canal fail-closed, email disponible.');
        // Alerte PDG best-effort (n'échoue jamais l'appel).
        void alertPdgTokenExpired().catch(() => {});
        return { success: false, error_code: 'WHATSAPP_TOKEN_EXPIRED', error: 'Token WhatsApp expiré' };
      }

      // Numéro sans compte WhatsApp / non joignable → repli email (bloc 3). Codes Meta usuels : 131026/131047/131051.
      if (mCode === 131026 || mCode === 131047 || mCode === 131051 || /not a valid whatsapp user|no whatsapp account/i.test(mMsg)) {
        return { success: false, error_code: 'WHATSAPP_NO_ACCOUNT', error: 'Ce numéro n\'a pas WhatsApp' };
      }

      // 5xx / 429 : transitoire → retry. 4xx métier : on arrête (pas de retry inutile).
      if (res.status < 500 && res.status !== 429) {
        logger.warn(`[whatsapp] envoi échoué (non-retry): ${lastErr} ${mMsg.slice(0, 200)}`);
        return { success: false, error_code: 'WHATSAPP_SEND_FAILED', error: 'Échec de l\'envoi WhatsApp' };
      }
      logger.warn(`[whatsapp] envoi transitoire (retry ${attempt + 1}/3): ${lastErr}`);
    } catch (e) {
      lastErr = (e as { message?: string })?.message || 'exception';
      logger.warn(`[whatsapp] exception envoi (retry ${attempt + 1}/3): ${lastErr}`);
    }
  }
  logger.error(`[whatsapp] envoi définitivement échoué après retries: ${lastErr}`);
  return { success: false, error_code: 'WHATSAPP_SEND_FAILED', error: 'Échec de l\'envoi WhatsApp' };
}

/** Alerte PDG (best-effort) quand le token WhatsApp expire — visible dans le centre de surveillance. */
async function alertPdgTokenExpired(): Promise<void> {
  try {
    const { supabaseAdmin } = await import('../config/supabase.js');
    await supabaseAdmin.from('system_alerts').insert({
      type: 'whatsapp_token_expired',
      severity: 'high',
      message: 'Token WhatsApp OTP expiré/invalide — régénérer (dev) ou passer au token permanent (prod). Canal téléphone en fail-closed, email disponible.',
    } as never);
  } catch { /* system_alerts absent → le log suffit */ }
}
