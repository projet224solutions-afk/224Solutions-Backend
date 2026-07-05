/**
 * 🔔 DISPATCH MULTICANAL DES NOTIFICATIONS — email + SMS.
 *
 * Appelé par le trigger DB `trg_dispatch_notification_channels` (pg_net) à CHAQUE insertion
 * dans `notifications`, quelle que soit la source (backend, frontend direct, RPC). Récupère
 * l'email + le téléphone du destinataire (profiles) puis envoie l'email (Resend) et le SMS
 * (Twilio). 100 % best-effort : n'échoue jamais le flux appelant ; l'in-app reste la source
 * de vérité. Protégé par x-internal-api-key (authenticateInternal).
 */
import { Router, Response } from 'express';
import { authenticateInternal } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { sendEmail } from '../services/transactionEmail.service.js';
import { sendSms, formatPhoneIntl } from '../services/sms.service.js';
import { enqueueRetry, processNotificationRetries } from '../services/notificationRetry.service.js';
import { logger } from '../config/logger.js';

const router = Router();

/**
 * 💸 POLITIQUE COÛT SMS — n'envoyer un SMS que pour les types CRITIQUES (configurable PDG).
 *
 * Réglage `pdg_settings` clé `sms_notification_types` (jsonb liste). Sans SMS ciblé, un blast
 * SMS partirait pour CHAQUE notification (email + in-app restent, eux, toujours envoyés).
 * Lu avec un cache mémoire ~60s pour éviter un SELECT par notification.
 */
const DEFAULT_SMS_TYPES = ['transfer', 'withdrawal', 'security', 'otp', 'payment_received'];
const SMS_TYPES_TTL_MS = 60 * 1000;
let smsTypesCache: { value: string[]; at: number } | null = null;

async function getSmsNotificationTypes(): Promise<string[]> {
  if (smsTypesCache && Date.now() - smsTypesCache.at < SMS_TYPES_TTL_MS) return smsTypesCache.value;
  let value = DEFAULT_SMS_TYPES;
  try {
    const { data } = await supabaseAdmin
      .from('pdg_settings')
      .select('setting_value')
      .eq('setting_key', 'sms_notification_types')
      .maybeSingle();
    const raw: any = data?.setting_value;
    // Tolère un array brut, {types:[...]} ou {value:[...]} (variantes de stockage pdg_settings).
    const arr = Array.isArray(raw) ? raw : Array.isArray(raw?.types) ? raw.types : Array.isArray(raw?.value) ? raw.value : null;
    if (arr && arr.length) value = arr.map((s: any) => String(s).toLowerCase().trim()).filter(Boolean);
  } catch (e) {
    logger.warn(`[notif-dispatch] lecture sms_notification_types échouée → défaut: ${(e as Error)?.message}`);
  }
  smsTypesCache = { value, at: Date.now() };
  return value;
}

/** Un SMS est-il autorisé pour ce type de notification ? (membership + inclusion, ex: 'transfer_out' ⊇ 'transfer'). */
function smsAllowedForType(type: string | undefined, allowed: string[]): boolean {
  const t = String(type || '').toLowerCase().trim();
  if (!t) return false; // type inconnu → non critique → pas de SMS (email + in-app conservés)
  return allowed.some((a) => t === a || t.includes(a));
}

/**
 * Types EXCLUS de l'envoi email/SMS automatique : les campagnes/marketing gèrent DÉJÀ
 * leurs propres canaux (in_app / push / email / sms sélectionnés par l'admin). Les inclure
 * provoquerait un double-envoi + un blast SMS sur toute la base. L'in-app reste créé.
 */
const SKIP_MULTICHANNEL_TYPES = new Set([
  'promotion', 'marketing', 'campaign', 'campagne', 'broadcast', 'promo', 'newsletter', 'ad', 'pub',
]);

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string));
}

function buildEmailHtml(title: string, message: string): string {
  return `<!DOCTYPE html><html><body style="margin:0;background:#f5f5f5;font-family:Arial,Helvetica,sans-serif">
    <div style="max-width:560px;margin:24px auto;background:#fff;border-radius:12px;overflow:hidden;border:1px solid #eee">
      <div style="background:#04439e;padding:16px 24px"><span style="color:#fff;font-size:18px;font-weight:bold">224Solutions</span></div>
      <div style="padding:24px">
        <h2 style="margin:0 0 12px;color:#111;font-size:18px">${escapeHtml(title || 'Notification')}</h2>
        <p style="margin:0;color:#444;font-size:15px;line-height:1.5">${escapeHtml(message || '')}</p>
      </div>
      <div style="padding:14px 24px;background:#fafafa;color:#999;font-size:12px;border-top:1px solid #eee">Notification automatique 224Solutions — ne pas répondre à cet email.</div>
    </div></body></html>`;
}

// ✅ Templates SMS adaptés au contexte — message court et clair
function buildSmsText(type: string, title: string, message: string): string {
  const t = (type || '').toLowerCase();
  const clean = (s: string) => String(s || '').replace(/[<>]/g, '').trim().slice(0, 100);

  if (t.includes('order') || t.includes('commande')) {
    return `224App : Commande ${clean(title)}. ${clean(message)}`;
  }
  if (t.includes('payment') || t.includes('paiement') || t.includes('wallet')) {
    return `224App - Paiement : ${clean(message)}`;
  }
  if (t.includes('taxi') || t.includes('ride') || t.includes('course')) {
    return `224App Taxi : ${clean(message)}`;
  }
  if (t.includes('delivery') || t.includes('livraison')) {
    return `224App Livraison : ${clean(message)}`;
  }
  if (t.includes('security') || t.includes('securite') || t.includes('otp')) {
    return `224App Securite : ${clean(message)} - Ne partagez pas ce code.`;
  }
  if (t.includes('syndicat') || t.includes('bureau') || t.includes('cotisation')) {
    return `224Syndicat : ${clean(message)}`;
  }
  // Générique
  const prefix = clean(title);
  return prefix ? `224App - ${prefix} : ${clean(message)}` : `224App : ${clean(message)}`;
}

// Retry SMS : enqueueRetry + processNotificationRetries sont centralisés dans
// notificationRetry.service.ts (réutilisés par le planificateur worker + la route ci-dessous).

// ✅ Anti-spam : max 1 SMS/email par type par utilisateur toutes les 5 minutes
// Stocké en mémoire (redémarre à chaque restart, suffisant pour anti-spam léger)
const recentlySent = new Map<string, number>(); // key: `${userId}:${type}` → timestamp
const SPAM_WINDOW_MS = 5 * 60 * 1000; // 5 minutes

function isThrottled(userId: string, type: string): boolean {
  const key  = `${userId}:${type}`;
  const last = recentlySent.get(key);
  if (last && Date.now() - last < SPAM_WINDOW_MS) return true;
  recentlySent.set(key, Date.now());
  return false;
}

/**
 * POST /api/v2/notifications/dispatch
 * body: { notification_id?, user_id, title, message, type }
 */
router.post('/dispatch', authenticateInternal, async (req, res: Response): Promise<void> => {
  try {
    const { user_id, title, message, type } = req.body || {};
    if (!user_id || !message) {
      res.status(400).json({ success: false, error: 'user_id et message requis' });
      return;
    }

    // Marketing/campagne → canaux gérés par le système de campagnes (anti double-envoi/blast).
    if (type && SKIP_MULTICHANNEL_TYPES.has(String(type).toLowerCase())) {
      res.json({ success: true, skipped: 'marketing_type', email: false, sms: false });
      return;
    }

    // Destinataire : email + téléphone (+ pays pour le format E.164 pan-africain) depuis profiles.
    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('email, phone, country_code')
      .eq('id', user_id)
      .maybeSingle();

    if (!profile) {
      res.json({ success: true, email: false, sms: false, reason: 'profile_not_found' });
      return;
    }

    // ✅ Anti-spam : types répétitifs groupés sur 5 minutes
    const GROUPABLE_TYPES = new Set(['order', 'commande', 'delivery', 'livraison', 'promotion']);
    const shouldThrottle  = type && GROUPABLE_TYPES.has(String(type).toLowerCase());
    if (shouldThrottle && isThrottled(user_id, String(type))) {
      logger.info(`[notif-dispatch] throttled user=${user_id} type=${type}`);
      res.json({ success: true, email: false, sms: false, throttled: true });
      return;
    }

    const subject = (title && String(title).trim()) || 'Notification 224Solutions';
    const out = { email: false, sms: false };

    // Email (Resend) — best-effort
    if (profile.email) {
      try { out.email = await sendEmail(profile.email, subject, buildEmailHtml(subject, message)); }
      catch (e) { logger.warn(`[notif-dispatch] email: ${(e as Error)?.message}`); }
    }

    // SMS (Twilio) — best-effort, UNIQUEMENT pour les types critiques (politique coût PDG).
    if (profile.phone) {
      const allowedTypes = await getSmsNotificationTypes();
      if (!smsAllowedForType(type, allowedTypes)) {
        // Hors liste : email + in-app conservés, pas de SMS (évite le blast SMS).
        logger.debug(`[notif-dispatch] SMS ignoré (type '${type || '?'}' hors liste critique) user=${user_id}`);
      } else {
        try {
          // Numéro normalisé E.164 selon le pays du profil (pan-africain).
          const e164 = formatPhoneIntl(profile.phone, (profile as any).country_code || undefined);
          // ✅ Template contextuel selon le type de notification
          const smsText = buildSmsText(type || '', title || '', message || '').slice(0, 320);
          const r = await sendSms(e164, smsText);
          out.sms = r.ok;

          // ✅ Si SMS échoue → enfile en retry (numéro déjà E.164 pour le worker sans pays).
          if (!r.ok) {
            await enqueueRetry(user_id, e164, smsText);
            logger.warn(`[notif-dispatch] SMS échoué → retry enfilé: ${r.error}`);
          }
        } catch (e) { logger.warn(`[notif-dispatch] sms: ${(e as Error)?.message}`); }
      }
    }

    logger.info(`[notif-dispatch] user=${user_id} type=${type || '?'} email=${out.email} sms=${out.sms}`);
    res.json({ success: true, ...out });
  } catch (e: any) {
    logger.error(`[notif-dispatch] ${e?.message}`);
    // 200 quand même : le dispatch est best-effort, ne pas faire retenter le trigger en boucle.
    res.json({ success: false, error: 'dispatch_error' });
  }
});

/**
 * POST /api/v2/notifications/process-retries
 * Appelé toutes les 5 minutes par un cron (pg_cron ou cron externe).
 * Retraite les SMS en échec (max 3 tentatives, backoff 5min/15min/1h).
 */
router.post('/process-retries', authenticateInternal, async (req, res: Response): Promise<void> => {
  try {
    // Logique centralisée (partagée avec le planificateur worker notificationRetryScheduler).
    const result = await processNotificationRetries();
    res.json({ success: true, ...result });
  } catch (e: any) {
    logger.error(`[notif-retry] ${e?.message}`);
    res.status(500).json({ success: false, error: e?.message });
  }
});

export default router;
