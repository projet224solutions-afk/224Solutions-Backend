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
import { sendSms } from '../services/sms.service.js';
import { logger } from '../config/logger.js';

const router = Router();

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

    // Destinataire : email + téléphone depuis profiles.
    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('email, phone')
      .eq('id', user_id)
      .maybeSingle();

    if (!profile) {
      res.json({ success: true, email: false, sms: false, reason: 'profile_not_found' });
      return;
    }

    const subject = (title && String(title).trim()) || 'Notification 224Solutions';
    const out = { email: false, sms: false };

    // Email (Resend) — best-effort
    if (profile.email) {
      try { out.email = await sendEmail(profile.email, subject, buildEmailHtml(subject, message)); }
      catch (e) { logger.warn(`[notif-dispatch] email: ${(e as Error)?.message}`); }
    }

    // SMS (Twilio) — best-effort. Concaténé titre + message, tronqué.
    if (profile.phone) {
      try {
        const smsText = `${title ? String(title).trim() + ' : ' : ''}${String(message).trim()}`.slice(0, 320);
        const r = await sendSms(profile.phone, smsText);
        out.sms = r.ok;
      } catch (e) { logger.warn(`[notif-dispatch] sms: ${(e as Error)?.message}`); }
    }

    logger.info(`[notif-dispatch] user=${user_id} type=${type || '?'} email=${out.email} sms=${out.sms}`);
    res.json({ success: true, ...out });
  } catch (e: any) {
    logger.error(`[notif-dispatch] ${e?.message}`);
    // 200 quand même : le dispatch est best-effort, ne pas faire retenter le trigger en boucle.
    res.json({ success: false, error: 'dispatch_error' });
  }
});

export default router;
