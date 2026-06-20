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

    // Déjà un custom_id ?
    const { data: existing } = await supabaseAdmin
      .from('user_ids')
      .select('custom_id')
      .eq('user_id', userId)
      .maybeSingle();

    if (existing?.custom_id) {
      res.json({ success: true, data: { custom_id: existing.custom_id, created: false } });
      return;
    }

    // Rôle + public_id éventuel
    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('role, public_id')
      .eq('id', userId)
      .maybeSingle();

    const role = profile?.role || 'client';
    let customId = profile?.public_id || null;

    // Générer un ID si aucun public_id existant
    if (!customId) {
      const { data: gen, error: genErr } = await supabaseAdmin.rpc('generate_custom_id_with_role', { p_role: role });
      if (genErr || !gen) {
        logger.error(`[identity/ensure] génération ID échouée: ${genErr?.message || 'no data'}`);
        res.status(500).json({ success: false, error: 'Génération d\'identifiant impossible' });
        return;
      }
      customId = gen as string;
    }

    // Écrire user_ids (service_role) + synchroniser profiles.public_id
    const { error: upErr } = await supabaseAdmin
      .from('user_ids')
      .upsert({ user_id: userId, custom_id: customId }, { onConflict: 'user_id' });
    if (upErr) {
      logger.error(`[identity/ensure] upsert user_ids: ${upErr.message}`);
      res.status(500).json({ success: false, error: 'Création d\'identifiant impossible' });
      return;
    }

    if (!profile?.public_id) {
      await supabaseAdmin.from('profiles').update({ public_id: customId }).eq('id', userId);
    }

    logger.info(`[identity/ensure] ID assuré user=${userId} custom_id=${customId}`);
    res.json({ success: true, data: { custom_id: customId, created: true } });
  } catch (error: any) {
    logger.error(`[identity/ensure] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la création de l\'identifiant' });
  }
});

export default router;
