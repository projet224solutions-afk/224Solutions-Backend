/**
 * 🆔 IDENTITY ROUTES - Backend Node.js
 *
 * Garantit/lit l'identifiant de l'utilisateur courant, côté serveur (service_role),
 * pour que les colonnes d'identité ne soient jamais écrites depuis le navigateur.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

/**
 * POST /api/identity/ensure
 * Garantit que l'utilisateur authentifié possède un user_ids.custom_id.
 * Génère l'ID côté serveur (RPC generate_custom_id_with_role) si manquant et
 * synchronise profiles.public_id. Remplace l'auto-création client de useAuth.
 */
router.post('/ensure', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;

    // 🔒 ATOMIQUE + ANTI-RACE : tout est fait en une seule transaction côté serveur
    // (verrou par utilisateur, idempotent, user_ids + profiles.public_id synchronisés).
    // Remplace l'ancienne séquence lecture→génération→upsert→update (non atomique,
    // sujette à des custom_id divergents en cas d'appels concurrents).
    const { data, error } = await supabaseAdmin.rpc('ensure_user_identity', { p_user_id: userId });

    const result = data as { success?: boolean; custom_id?: string; created?: boolean; error?: string } | null;
    if (error || !result?.success || !result.custom_id) {
      logger.error(`[identity/ensure] échec RPC: ${error?.message || result?.error || 'no data'}`);
      res.status(500).json({ success: false, error: 'Création d\'identifiant impossible' });
      return;
    }

    logger.info(`[identity/ensure] ID assuré user=${userId} custom_id=${result.custom_id} (created=${result.created})`);
    res.json({ success: true, data: { custom_id: result.custom_id, created: !!result.created } });
  } catch (error: any) {
    logger.error(`[identity/ensure] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la création de l\'identifiant' });
  }
});

export default router;
