/**
 * 📞 TURN (WebRTC) — pont Twilio Network Traversal.
 *
 * Renvoie des identifiants TURN ÉPHÉMÈRES (valides ~ttl) au client pour relayer les appels
 * WebRTC quand la connexion directe (STUN) échoue (NAT symétrique). Utilise les MÊMES
 * credentials Twilio que les SMS (TWILIO_ACCOUNT_SID/AUTH_TOKEN) — aucune ressource à créer.
 * ⚠️ TWILIO_AUTH_TOKEN n'est JAMAIS exposé : seuls les identifiants temporaires générés par
 * Twilio transitent. REST direct (pas de SDK), même pattern que sms.service.
 */
import { Router, type Response } from 'express';
import { env } from '../config/env.js';
import { logger } from '../config/logger.js';
import { ok, fail } from '../utils/apiResponse.js';
import { verifyJWT, type AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { routeRateLimit } from '../middlewares/routeRateLimiter.js';

const router = Router();

// Le token Twilio est valable ~1h → inutile d'en demander à chaque render. Rate-limit léger.
const turnRateLimit = routeRateLimit({ windowSeconds: 60, maxRequests: 20, keyPrefix: 'turn', perUser: true });

interface TwilioIceServer { url?: string; urls?: string; username?: string; credential?: string }

// GET /api/v2/turn-credentials — identifiants TURN éphémères normalisés { urls, username, credential }.
router.get('/turn-credentials', verifyJWT, turnRateLimit, async (_req: AuthenticatedRequest, res: Response) => {
  const sid = env.TWILIO_ACCOUNT_SID;
  const token = env.TWILIO_AUTH_TOKEN;
  if (!sid || !token) return fail(res, 503, 'TURN non configuré', 'TURN_NOT_CONFIGURED');
  try {
    const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Tokens.json`, {
      method: 'POST',
      headers: {
        Authorization: 'Basic ' + Buffer.from(`${sid}:${token}`).toString('base64'),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
    });
    if (!r.ok) {
      logger.warn(`[turn] Twilio Tokens.json HTTP ${r.status}`);
      return fail(res, 502, 'Twilio TURN indisponible', 'TURN_UPSTREAM_ERROR');
    }
    const data = await r.json();
    // Twilio renvoie chaque entrée avec `url` (singulier) ET `urls` (pluriel) → on normalise
    // vers { urls, username?, credential? } (forme attendue par RTCPeerConnection).
    const iceServers = (data.ice_servers ?? []).map((s: TwilioIceServer) => ({
      urls: s.urls || s.url,
      ...(s.username ? { username: s.username } : {}),
      ...(s.credential ? { credential: s.credential } : {}),
    }));
    return ok(res, { iceServers, ttl: data.ttl ?? 3600 });
  } catch (e: any) {
    logger.error(`[turn] ${e?.message}`);
    return fail(res, 502, 'Échec récupération TURN', 'TURN_FETCH_FAILED');
  }
});

export default router;
