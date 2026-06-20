/**
 * 🧾 DEVIS (socle Maison/Photo/Freelance/Réparation/Informatique) — paiement direct
 * ou ESCROW + libération à la validation client. RPC atomiques (REVOKE PUBLIC).
 *   POST /api/v2/quotes/:id/pay      → le client paie le devis.
 *   POST /api/v2/quotes/:id/release  → le client valide (escrow) → libère au prestataire.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

function mapError(msg: string): { code: number; error: string } {
  if (/QUOTE_NOT_FOUND/.test(msg)) return { code: 404, error: 'Devis introuvable' };
  if (/QUOTE_CANCELLED/.test(msg)) return { code: 409, error: 'Devis annulé' };
  if (/OWN_QUOTE/.test(msg)) return { code: 403, error: 'Vous ne pouvez pas payer votre propre devis' };
  if (/NOT_CLIENT/.test(msg)) return { code: 403, error: 'Action réservée au client' };
  if (/NOT_HELD/.test(msg)) return { code: 409, error: 'Aucun fonds en séquestre à libérer' };
  if (/BAD_AMOUNT/.test(msg)) return { code: 400, error: 'Montant invalide' };
  if (/INSUFFICIENT_FUNDS/.test(msg)) return { code: 402, error: 'Solde wallet insuffisant' };
  if (/WALLET_BLOCKED/.test(msg)) return { code: 403, error: 'Wallet bloqué' };
  return { code: 400, error: msg };
}

router.post('/:id/pay', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('pay_quote_atomic', { p_actor_user_id: req.user!.id, p_quote_id: req.params.id });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[quotes/pay] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur paiement devis' }); }
});

router.post('/:id/release', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('release_quote_atomic', { p_actor_user_id: req.user!.id, p_quote_id: req.params.id });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[quotes/release] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur libération' }); }
});

export default router;
