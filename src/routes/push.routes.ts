/**
 * 📲 PUSH ROUTES - Backend Node.js
 *
 * Envoi de notifications push (FCM) pour réveiller un client hors ligne.
 * Logique en Node ; l'envoi FCM est délégué à l'Edge Function existante
 * `smart-notifications` (clé FIREBASE_SERVER_KEY déjà configurée côté Supabase),
 * pour ne pas dupliquer le secret côté backend.
 *
 * Endpoint (monté sur /api/v2/push) :
 *   - POST /locate-request { target_user_id, driver_name? }
 *     → push « Un chauffeur veut vous localiser » au client ciblé.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

router.post('/locate-request', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { target_user_id, driver_name } = req.body || {};
    if (!target_user_id || typeof target_user_id !== 'string' || !UUID_RE.test(target_user_id)) {
      res.status(400).json({ success: false, error: 'target_user_id (UUID) requis' });
      return;
    }

    // 🛡️ Anti-spam : pas plus d'un push « localiser » par utilisateur toutes les 2 min
    const since = new Date(Date.now() - 2 * 60 * 1000).toISOString();
    const { data: recent } = await supabaseAdmin
      .from('notifications')
      .select('id')
      .eq('user_id', target_user_id)
      .ilike('title', '%localiser%')
      .gte('created_at', since)
      .limit(1)
      .maybeSingle();
    if (recent) {
      res.json({ success: true, delivered: false, reason: 'throttled' });
      return;
    }

    // Le client a-t-il un token FCM ? (sinon, push impossible)
    const { data: tokenRow } = await supabaseAdmin
      .from('user_fcm_tokens')
      .select('fcm_token')
      .eq('user_id', target_user_id)
      .limit(1)
      .maybeSingle();

    if (!tokenRow?.fcm_token) {
      res.json({ success: true, delivered: false, reason: 'no_token' });
      return;
    }

    const url = process.env.SUPABASE_URL;
    const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !serviceKey) {
      res.status(503).json({ success: false, error: 'Configuration Supabase manquante' });
      return;
    }

    // Délègue l'envoi FCM à l'Edge Function smart-notifications (clé serveur déjà configurée)
    const r = await fetch(`${url}/functions/v1/smart-notifications`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${serviceKey}`,
        apikey: serviceKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        userId: target_user_id,
        type: 'system',
        title: '🚕 Un chauffeur veut vous localiser',
        message: 'Ouvrez l\'application pour partager votre position.',
        actionUrl: '/taxi-moto',
        sendPush: true,
        data: { type: 'locate_request', driverName: driver_name || 'Un chauffeur' },
      }),
    });

    if (!r.ok) {
      const txt = await r.text().catch(() => '');
      logger.warn(`[push/locate-request] smart-notifications HTTP ${r.status}: ${txt.slice(0, 200)}`);
      res.json({ success: false, delivered: false, error: 'Échec de l\'envoi de la notification' });
      return;
    }

    logger.info(`[push/locate-request] Push envoyé à ${target_user_id}`);
    res.json({ success: true, delivered: true });
  } catch (error: any) {
    logger.error(`[push/locate-request] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'envoi de la notification' });
  }
});

/**
 * POST /call-notify { target_user_id, caller_name?, mode? }
 * → push « 📞 Appel entrant » au destinataire pour qu'il ouvre l'app.
 * Une fois l'app ouverte, le canal de signalisation WebRTC se réabonne et
 * l'offre (réémise toutes les 2 s côté appelant) fait sonner l'appel.
 */
router.post('/call-notify', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { target_user_id, caller_name, mode } = req.body || {};
    if (!target_user_id || typeof target_user_id !== 'string' || !UUID_RE.test(target_user_id)) {
      res.status(400).json({ success: false, error: 'target_user_id (UUID) requis' });
      return;
    }

    const callMode = mode === 'video' ? 'video' : 'audio';
    const callerLabel = (typeof caller_name === 'string' && caller_name.trim()) ? caller_name.trim().slice(0, 60) : 'Quelqu\'un';

    // 🛡️ Anti-spam : pas plus d'un push d'appel par destinataire toutes les 15 s
    const since = new Date(Date.now() - 15 * 1000).toISOString();
    const { data: recent } = await supabaseAdmin
      .from('notifications')
      .select('id')
      .eq('user_id', target_user_id)
      .ilike('title', '%Appel entrant%')
      .gte('created_at', since)
      .limit(1)
      .maybeSingle();
    if (recent) {
      res.json({ success: true, delivered: false, reason: 'throttled' });
      return;
    }

    // Le destinataire a-t-il un token FCM ? (sinon, push impossible)
    const { data: tokenRow } = await supabaseAdmin
      .from('user_fcm_tokens')
      .select('fcm_token')
      .eq('user_id', target_user_id)
      .limit(1)
      .maybeSingle();

    if (!tokenRow?.fcm_token) {
      res.json({ success: true, delivered: false, reason: 'no_token' });
      return;
    }

    const url = process.env.SUPABASE_URL;
    const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !serviceKey) {
      res.status(503).json({ success: false, error: 'Configuration Supabase manquante' });
      return;
    }

    const r = await fetch(`${url}/functions/v1/smart-notifications`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${serviceKey}`,
        apikey: serviceKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        userId: target_user_id,
        type: 'system',
        title: callMode === 'video' ? '📹 Appel vidéo entrant' : '📞 Appel entrant',
        message: `${callerLabel} vous appelle. Ouvrez l'application pour répondre.`,
        actionUrl: '/messages',
        sendPush: true,
        data: {
          type: 'incoming_call',
          caller_id: req.user?.id || '',
          caller_name: callerLabel,
          mode: callMode,
          url: '/messages',
        },
      }),
    });

    if (!r.ok) {
      const txt = await r.text().catch(() => '');
      logger.warn(`[push/call-notify] smart-notifications HTTP ${r.status}: ${txt.slice(0, 200)}`);
      res.json({ success: false, delivered: false, error: 'Échec de l\'envoi de la notification d\'appel' });
      return;
    }

    logger.info(`[push/call-notify] Push d'appel envoyé à ${target_user_id} (${callMode})`);
    res.json({ success: true, delivered: true });
  } catch (error: any) {
    logger.error(`[push/call-notify] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'envoi de la notification d\'appel' });
  }
});

export default router;
