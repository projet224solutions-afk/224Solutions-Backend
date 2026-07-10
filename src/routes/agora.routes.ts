/**
 * 📞 AGORA — routes /api/v2/agora (contrat {success,data} via ok()/fail()).
 *
 * Émet un token RTC Agora pour les APPELS 1-1 (audio/vidéo), généré NATIVEMENT côté backend
 * (services/agoraToken.ts) avec le certificat en `process.env` — JAMAIS l'edge Supabase
 * (dont l'algorithme 006 était malformé → tokens rejetés au join). Auth : verifyJWT.
 *
 * Le client (useAgora) appelle POST /token puis rejoint le canal avec {appId, token, uid}.
 */

import { Router, type Response } from 'express';
import { env } from '../config/env.js';
import { logger } from '../config/logger.js';
import { ok, fail } from '../utils/apiResponse.js';
import { verifyJWT, type AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import {
  generateAgoraRtcToken,
  sanitizeAgoraChannel,
  uuidToNumericUid,
  AgoraRole,
} from '../services/agoraToken.js';

const router = Router();

/**
 * POST /api/v2/agora/token
 * Body: { channel: string, uid?: string|number, role?: 'publisher'|'subscriber' }
 * Renvoie: { appId, token, channel, uid, role, expiresAt }
 */
router.post('/token', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const appId = env.AGORA_APP_ID;
    const appCert = env.AGORA_APP_CERTIFICATE;
    // Pas de repli DB/edge : si le secret n'est pas configuré → échec explicite (convention 224).
    if (!appId || !appCert) {
      return fail(res, 503, 'Appels non configurés (certificat Agora absent côté backend)', 'AGORA_NOT_CONFIGURED');
    }

    const { channel, uid: rawUid, role: rawRole } = (req.body || {}) as {
      channel?: string;
      uid?: string | number;
      role?: string;
    };
    if (!channel || typeof channel !== 'string') {
      return fail(res, 400, 'Canal requis', 'CHANNEL_REQUIRED');
    }

    const safeChannel = sanitizeAgoraChannel(channel);

    // UID : fourni par le client s'il est valide (doit matcher l'uid utilisé au join RTC),
    // sinon repli déterministe dérivé de l'utilisateur authentifié.
    const provided = rawUid != null ? String(rawUid).trim() : '';
    const uid =
      provided.length > 0 && /^[a-zA-Z0-9_\-]{1,64}$/.test(provided)
        ? provided.substring(0, 64)
        : String(uuidToNumericUid(req.user!.id));

    const roleValue = rawRole === 'subscriber' ? AgoraRole.SUBSCRIBER : AgoraRole.PUBLISHER;
    const expiresAt = Math.floor(Date.now() / 1000) + 86400; // 24 h

    const token = generateAgoraRtcToken(appId, appCert, safeChannel, uid, roleValue, expiresAt);

    return ok(res, {
      appId,
      token,
      channel: safeChannel,
      uid,
      role: roleValue === AgoraRole.PUBLISHER ? 'publisher' : 'subscriber',
      expiresAt,
    });
  } catch (e: any) {
    logger.error(`[agora/token] ${e?.message}`);
    return fail(res, 500, 'Erreur lors de la génération du token Agora');
  }
});

export default router;
