/**
 * Push FCM réutilisable — même mécanisme que push.routes.ts : détection du token via
 * user_fcm_tokens, envoi délégué à l'Edge Function smart-notifications (la clé FCM y vit, jamais
 * dupliquée côté backend). Sert aux flux de confirmation cash (push+PIN) et aux notices de dépôt.
 */
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

/** Le client a-t-il un token push actif ? (détermine push vs bascule OTP). */
export async function userHasFcmToken(userId: string): Promise<boolean> {
  try {
    const { data } = await supabaseAdmin
      .from('user_fcm_tokens')
      .select('fcm_token')
      .eq('user_id', userId)
      .limit(1)
      .maybeSingle();
    return !!(data as any)?.fcm_token;
  } catch {
    return false;
  }
}

/** Envoie un push à un utilisateur via l'Edge smart-notifications. Best-effort (jamais bloquant). */
export async function sendPushToUser(
  userId: string,
  opts: { title: string; message: string; actionUrl?: string; data?: Record<string, unknown> }
): Promise<boolean> {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return false;
  try {
    const r = await fetch(`${url}/functions/v1/smart-notifications`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, apikey: key, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        userId, type: 'system', title: opts.title, message: opts.message,
        actionUrl: opts.actionUrl, sendPush: true, data: opts.data || {},
      }),
    });
    return r.ok;
  } catch (e: any) {
    logger.warn(`[push.service] ${e?.message}`);
    return false;
  }
}
