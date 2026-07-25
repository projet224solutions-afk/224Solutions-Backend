/**
 * 🔒 GARDE D'ABONNEMENT CÔTÉ SERVEUR — requireFeature('<clé>')
 *
 * Source de vérité = RPC SQL `has_active_feature(user, feature)` (migration
 * 20260725120000). À appliquer sur les routes de CRÉATION/MODIFICATION d'une
 * fonctionnalité payante — JAMAIS sur la lecture des données propres du vendeur,
 * ni sur les routes publiques/acheteurs.
 *
 * Refus → HTTP 402 Payment Required { success:false, error:'subscription_required',
 * feature } pour que le frontend affiche l'écran d'abonnement plutôt qu'une erreur
 * générique.
 *
 * FAIL-CLOSED : si la RPC échoue, on REFUSE (jamais d'accès gratuit à une
 * fonctionnalité payante à cause d'un incident) — même posture que les routes
 * financières (routeRateLimiter.failClosed).
 *
 * Cache Redis 60 s des résultats POSITIFS uniquement (amortit les allers-retours DB
 * et un éventuel blip pour un user déjà vérifié). Un refus n'est JAMAIS mis en cache
 * → un vendeur qui vient de renouveler n'est pas bloqué pendant 60 s.
 */

import { Response, NextFunction } from 'express';
import type { AuthenticatedRequest } from './auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { cache } from '../config/redis.js';

function denyPaymentRequired(res: Response, feature: string): void {
  res.status(402).json({
    success: false,
    error: 'subscription_required',
    feature,
    error_code: 'SUBSCRIPTION_REQUIRED',
  });
}

export function requireFeature(feature: string) {
  return async (req: AuthenticatedRequest, res: Response, next: NextFunction): Promise<void> => {
    const userId = req.user?.id;
    if (!userId) {
      res.status(401).json({ success: false, error: 'unauthorized', error_code: 'UNAUTHENTICATED' });
      return;
    }

    const cacheKey = `feature:${userId}:${feature}`;

    // 1) Cache positif (best-effort) — un « true » récent laisse passer sans requête DB.
    try {
      if ((await cache.get(cacheKey)) === true) {
        next();
        return;
      }
    } catch {
      /* cache indisponible → on interroge la DB */
    }

    // 2) Source de vérité
    try {
      const { data, error } = await supabaseAdmin.rpc('has_active_feature' as never, {
        p_user_id: userId,
        p_feature: feature,
      });

      if (error) {
        logger.error(
          `[requireFeature] has_active_feature a échoué (FAIL-CLOSED, refus) user=${userId} feature=${feature}: ${error.message}`,
        );
        denyPaymentRequired(res, feature);
        return;
      }

      if (data === true) {
        try { await cache.set(cacheKey, true, 60); } catch { /* best-effort */ }
        next();
        return;
      }

      denyPaymentRequired(res, feature);
    } catch (e) {
      logger.error(
        `[requireFeature] exception (FAIL-CLOSED, refus) user=${userId} feature=${feature}: ${(e as Error)?.message || e}`,
      );
      denyPaymentRequired(res, feature);
    }
  };
}
