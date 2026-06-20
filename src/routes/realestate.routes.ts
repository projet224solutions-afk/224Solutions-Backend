/**
 * 🏠 IMMOBILIER / LOCATION — cycle locatif atomique (caution escrow + quittances).
 *   POST /api/v2/realestate/lease/start            → le locataire démarre un bail (caution + 1er loyer).
 *   POST /api/v2/realestate/lease/:id/pay-rent      → le locataire paie un loyer (quittance).
 *   POST /api/v2/realestate/lease/:id/release-deposit → le bailleur clôture + libère/retient la caution.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

function mapError(msg: string): { code: number; error: string } {
  if (/PROPERTY_NOT_FOUND|LEASE_NOT_FOUND/.test(msg)) return { code: 404, error: 'Introuvable' };
  if (/NOT_FOR_RENT/.test(msg)) return { code: 409, error: 'Ce bien n\'est pas en location' };
  if (/NOT_AVAILABLE/.test(msg)) return { code: 409, error: 'Ce bien n\'est plus disponible' };
  if (/OWN_PROPERTY/.test(msg)) return { code: 403, error: 'Vous ne pouvez pas louer votre propre bien' };
  if (/NOT_TENANT/.test(msg)) return { code: 403, error: 'Action réservée au locataire' };
  if (/NOT_OWNER/.test(msg)) return { code: 403, error: 'Action réservée au bailleur' };
  if (/LEASE_NOT_ACTIVE/.test(msg)) return { code: 409, error: 'Bail inactif' };
  if (/INSUFFICIENT_FUNDS/.test(msg)) return { code: 402, error: 'Solde wallet insuffisant' };
  if (/WALLET_BLOCKED/.test(msg)) return { code: 403, error: 'Wallet bloqué' };
  return { code: 400, error: msg };
}

router.post('/lease/start', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { property_id, deposit_months, tenant_name, tenant_phone, start_date, end_date, terms } = req.body ?? {};
    if (!property_id) { res.status(400).json({ success: false, error: 'property_id requis' }); return; }
    const { data, error } = await supabaseAdmin.rpc('start_rental_lease_atomic', {
      p_actor_user_id: req.user!.id, p_property_id: property_id,
      p_deposit_months: deposit_months ?? 1, p_tenant_name: tenant_name ?? null, p_tenant_phone: tenant_phone ?? null,
      p_start_date: start_date ?? null, p_end_date: end_date ?? null, p_terms: terms ?? null,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[realestate/start] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur location' }); }
});

router.post('/lease/:id/pay-rent', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const period = req.body?.period;
    if (!period) { res.status(400).json({ success: false, error: 'period requis (ex: 2026-06)' }); return; }
    const { data, error } = await supabaseAdmin.rpc('pay_rent_atomic', {
      p_actor_user_id: req.user!.id, p_lease_id: req.params.id, p_period: period,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[realestate/pay-rent] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur paiement loyer' }); }
});

router.post('/lease/:id/release-deposit', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const refund = req.body?.refund !== false;
    const { data, error } = await supabaseAdmin.rpc('release_deposit_atomic', {
      p_actor_user_id: req.user!.id, p_lease_id: req.params.id, p_refund: refund,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[realestate/release] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur caution' }); }
});

export default router;
