/**
 * 🚗 MOBILITÉ (VTC & Livraison) — paiement wallet d'une course/livraison (atomique).
 *   POST /api/v2/mobility/:id/pay → le client paie en wallet (débit → net prestataire).
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

function mapError(msg: string): { code: number; error: string } {
  if (/JOB_NOT_FOUND/.test(msg)) return { code: 404, error: 'Course/livraison introuvable' };
  if (/JOB_CANCELLED/.test(msg)) return { code: 409, error: 'Course annulée' };
  if (/OWN_JOB/.test(msg)) return { code: 403, error: 'Vous ne pouvez pas payer votre propre course' };
  if (/BAD_AMOUNT/.test(msg)) return { code: 400, error: 'Montant invalide' };
  if (/INSUFFICIENT_FUNDS/.test(msg)) return { code: 402, error: 'Solde wallet insuffisant' };
  if (/WALLET_BLOCKED/.test(msg)) return { code: 403, error: 'Wallet bloqué' };
  return { code: 400, error: msg };
}

router.post('/:id/pay', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('settle_mobility_job_atomic', { p_actor_user_id: req.user!.id, p_job_id: req.params.id });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[mobility/pay] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur paiement' }); }
});

export default router;
