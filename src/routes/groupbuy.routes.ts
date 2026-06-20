/**
 * 🛒 ACHAT GROUPÉ (Pinduoduo) — création + participation, via RPC atomiques (REVOKE PUBLIC).
 *   POST /api/v2/group-buy            → lancer un achat groupé (l'initiateur rejoint).
 *   POST /api/v2/group-buy/:id/join   → rejoindre (débit ; si minimum atteint → succès).
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

function mapError(msg: string): { code: number; error: string } {
  if (/GROUP_NOT_FOUND/.test(msg)) return { code: 404, error: 'Achat groupé introuvable' };
  if (/GROUP_CLOSED/.test(msg)) return { code: 409, error: 'Cet achat groupé est clôturé' };
  if (/GROUP_EXPIRED/.test(msg)) return { code: 409, error: 'Cet achat groupé a expiré' };
  if (/ALREADY_JOINED/.test(msg)) return { code: 409, error: 'Vous participez déjà' };
  if (/INSUFFICIENT_FUNDS/.test(msg)) return { code: 402, error: 'Solde wallet insuffisant' };
  if (/WALLET_BLOCKED/.test(msg)) return { code: 403, error: 'Wallet bloqué' };
  if (/BAD_PRICE/.test(msg)) return { code: 400, error: 'Prix invalide' };
  return { code: 400, error: msg };
}

router.post('/', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const b = req.body ?? {};
    const { data, error } = await supabaseAdmin.rpc('create_group_buy_atomic', {
      p_actor_user_id: req.user!.id,
      p_product_id: b.product_id ?? null,
      p_product_name: b.product_name ?? null,
      p_group_price: b.group_price ?? 0,
      p_min: b.min ?? 3,
      p_quantity: b.quantity ?? 1,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[group-buy:create] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la création' });
  }
});

router.post('/:id/join', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('join_group_buy_atomic', {
      p_group: req.params.id, p_actor_user_id: req.user!.id, p_quantity: req.body?.quantity ?? 1,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[group-buy:join] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la participation' });
  }
});

export default router;
