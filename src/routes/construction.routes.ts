/**
 * 🏗️ CONSTRUCTION/BTP — jalons escrow (financer + libérer), RPC atomiques (REVOKE PUBLIC).
 *   POST /api/v2/construction/milestone/:id/fund     → le client finance (débit → escrow).
 *   POST /api/v2/construction/milestone/:id/release  → le client valide → crédite le prestataire.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

function mapError(msg: string): { code: number; error: string } {
  if (/NOT_CLIENT/.test(msg)) return { code: 403, error: 'Seul le client peut effectuer cette action' };
  if (/NOT_FOUND/.test(msg)) return { code: 404, error: 'Jalon introuvable' };
  if (/NOT_FUNDED/.test(msg)) return { code: 409, error: 'Le jalon doit être financé avant validation' };
  if (/INSUFFICIENT_FUNDS/.test(msg)) return { code: 402, error: 'Solde wallet insuffisant' };
  if (/WALLET_BLOCKED/.test(msg)) return { code: 403, error: 'Wallet bloqué' };
  if (/BAD_AMOUNT/.test(msg)) return { code: 400, error: 'Montant invalide' };
  return { code: 400, error: msg };
}

router.post('/project/:id/claim', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('claim_construction_project', { p_project_id: req.params.id, p_actor_user_id: req.user!.id });
    if (error) { const code = /ALREADY_CLAIMED/.test(error.message) ? 409 : 400; res.status(code).json({ success: false, error: error.message }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[btp/claim] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur' }); }
});

router.post('/milestone/:id/fund', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('fund_construction_milestone_atomic', { p_milestone_id: req.params.id, p_actor_user_id: req.user!.id });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[btp/fund] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur financement' }); }
});

router.post('/milestone/:id/release', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('release_construction_milestone_atomic', { p_milestone_id: req.params.id, p_actor_user_id: req.user!.id });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[btp/release] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur libération' }); }
});

export default router;
