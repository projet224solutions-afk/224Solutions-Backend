/**
 * 🚢✈️  FRET (module transitaire) — Phase 1 : DEVIS À PRIX SERVEUR.
 * POST /api/v2/freight/quote → RPC calculate_freight_quote (seule source de vérité du prix).
 *
 * Le client envoie les paramètres physiques (mode, itinéraire, poids, dimensions,
 * pièces) ; le SERVEUR lit la grille tarifaire active du transitaire et renvoie le
 * prix + le détail. Un éventuel « price » dans le body est IGNORÉ — jamais de prix client.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { ok, fail } from '../utils/apiResponse.js';

const router = Router();

const num = (v: unknown): number => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// POST /api/v2/freight/quote — calcule un devis (aérien ou maritime) via la RPC serveur.
router.post('/quote', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const b = req.body ?? {};
    // Le transitaire teste ses propres grilles par défaut ; un transitaire_id explicite
    // (devis chez un autre transitaire) reste possible pour un usage futur côté client.
    // transitaire_id explicite (devis chez un autre transitaire) : valider le format UUID
    // AVANT la RPC — sinon PostgREST renvoie une erreur uuid brute → 500 générique.
    if (b.transitaire_id != null && b.transitaire_id !== '' && !UUID_RE.test(String(b.transitaire_id))) {
      return fail(res, 400, 'Transitaire invalide', 'INVALID_TRANSITAIRE');
    }
    const transitaireId: string = b.transitaire_id || req.user!.id;
    const mode: string = b.mode;
    const origin: string = b.origin;
    const dest: string = b.dest;

    if (mode !== 'air' && mode !== 'sea') {
      return fail(res, 400, 'Mode de transport invalide (air ou sea)', 'INVALID_MODE');
    }
    if (!origin || !String(origin).trim() || !dest || !String(dest).trim()) {
      return fail(res, 400, 'Origine et destination requises', 'ROUTE_REQUIRED');
    }

    const { data, error } = await supabaseAdmin.rpc('calculate_freight_quote', {
      p_transitaire_id: transitaireId,
      p_mode:           mode,
      p_origin:         String(origin).trim(),
      p_dest:           String(dest).trim(),
      p_weight_kg:      num(b.weight_kg),
      p_length_cm:      num(b.length_cm),
      p_width_cm:       num(b.width_cm),
      p_height_cm:      num(b.height_cm),
      p_pieces:         Math.max(1, Math.trunc(num(b.pieces)) || 1),
    });

    if (error) {
      logger.error(`[freight/quote] rpc: ${error.message}`);
      return fail(res, 500, 'Erreur lors du calcul du devis');
    }

    const quote = data as Record<string, unknown> | null;
    if (!quote || quote.success !== true) {
      const code = String(quote?.error ?? 'QUOTE_FAILED');
      const status = code === 'NO_RATE_FOUND' ? 404 : 400;
      const friendly =
        code === 'NO_RATE_FOUND'
          ? "Aucune grille tarifaire disponible pour cet itinéraire"
          : code === 'INVALID_MODE'
            ? 'Mode de transport invalide'
            : code === 'ROUTE_REQUIRED'
              ? 'Origine et destination requises'
              : 'Impossible de calculer le devis';
      return fail(res, status, friendly, code);
    }

    return ok(res, quote);
  } catch (e: unknown) {
    logger.error(`[freight/quote] ${(e as Error)?.message}`);
    return fail(res, 500, 'Erreur lors du calcul du devis');
  }
});

export default router;
