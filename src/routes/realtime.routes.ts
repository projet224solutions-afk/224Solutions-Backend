/**
 * 📡 REALTIME ROUTES - Backend Node.js
 *
 * Émission de tokens Ably (Phase 1 scalabilité temps réel).
 * Le frontend ne voit JAMAIS la clé API : il reçoit un token signé, scopé à son user.
 *
 * INACTIF tant que ABLY_API_KEY n'est pas défini (Supabase Realtime reste le défaut).
 *
 * Endpoint (monté sur /api/v2/realtime) :
 *   - POST /token  → renvoie un Ably TokenRequest pour l'utilisateur authentifié
 */

import { Router, Response } from 'express';
import * as Ably from 'ably';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { logger } from '../config/logger.js';

const router = Router();

/**
 * POST /api/v2/realtime/token
 * Renvoie un TokenRequest Ably (auth déléguée). Auth : verifyJWT.
 * Le corps de réponse est le TokenRequest brut attendu par le SDK Ably (authCallback).
 */
router.post('/token', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  const apiKey = process.env.ABLY_API_KEY;
  if (!apiKey) {
    res.status(503).json({
      success: false,
      error: 'Temps réel non configuré (ABLY_API_KEY manquant côté backend)',
    });
    return;
  }

  try {
    const rest = new Ably.Rest(apiKey);
    // clientId = user → permet la presence et le scoping par utilisateur
    const tokenRequest = await rest.auth.createTokenRequest({ clientId: req.user!.id });
    // Le SDK Ably (authCallback) attend directement le TokenRequest
    res.json(tokenRequest);
  } catch (error: any) {
    logger.error(`[Realtime] token error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la génération du token temps réel' });
  }
});

export default router;
