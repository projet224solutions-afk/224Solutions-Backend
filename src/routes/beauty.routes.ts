/**
 * 💇 BEAUTÉ — actions sensibles (no-show avec pénalité wallet atomique).
 * POST /api/v2/beauty/appointment/:id/no-show → RPC mark_beauty_no_show_atomic.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

// Réservation PAYANTE atomique (verrou créneau + idempotence + dépôt + domicile/walk-in).
router.post('/book', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { service_id, beauty_service_id, slot_date, slot_time, booking_type, client_address, customer_name, customer_phone, idempotency_key } = req.body ?? {};
    if (!service_id || !beauty_service_id || !slot_date || !slot_time) {
      res.status(400).json({ success: false, error: 'Paramètres manquants' }); return;
    }
    const { data, error } = await supabaseAdmin.rpc('process_beauty_booking_atomic', {
      p_actor_user_id: req.user!.id, p_service_id: service_id, p_beauty_service_id: beauty_service_id,
      p_slot_date: slot_date, p_slot_time: slot_time, p_booking_type: booking_type || 'salon',
      p_client_address: client_address ?? null, p_customer_name: customer_name ?? null,
      p_customer_phone: customer_phone ?? null, p_idempotency_key: idempotency_key ?? null,
    });
    if (error) {
      const msg = error.message || '';
      const code = /SERVICE_NOT_FOUND/.test(msg) ? 404 : /CRENEAU_DEJA_PRIS/.test(msg) ? 409
        : /SERVICE_INACTIVE|OWN_SERVICE/.test(msg) ? 409 : /INSUFFICIENT_FUNDS/.test(msg) ? 402
        : /WALLET_BLOCKED/.test(msg) ? 403 : 400;
      const friendly = /CRENEAU_DEJA_PRIS/.test(msg) ? 'Ce créneau vient d\'être pris, choisissez-en un autre'
        : /INSUFFICIENT_FUNDS/.test(msg) ? 'Solde wallet insuffisant'
        : /OWN_SERVICE/.test(msg) ? 'Vous ne pouvez pas réserver votre propre salon' : msg;
      res.status(code).json({ success: false, error: friendly });
      return;
    }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[beauty/book] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur réservation' });
  }
});

// Annulation par le client (remboursement ou pénalité selon le délai).
router.post('/appointment/:id/cancel', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('cancel_beauty_booking_atomic', { p_actor_user_id: req.user!.id, p_appointment_id: req.params.id });
    if (error) {
      const msg = error.message || '';
      const code = /NOT_CLIENT/.test(msg) ? 403 : /NOT_FOUND/.test(msg) ? 404 : /NOT_CANCELLABLE/.test(msg) ? 409 : 400;
      res.status(code).json({ success: false, error: msg }); return;
    }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[beauty/cancel] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur annulation' }); }
});

// Avis vérifié (client du RDV uniquement).
router.post('/appointment/:id/review', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { rating, text } = req.body ?? {};
    const { data, error } = await supabaseAdmin.rpc('submit_beauty_review_atomic', { p_actor_user_id: req.user!.id, p_appointment_id: req.params.id, p_rating: Math.round(Number(rating)), p_text: text ?? null });
    if (error) {
      const msg = error.message || '';
      const code = /NOT_CLIENT/.test(msg) ? 403 : /NOT_FOUND/.test(msg) ? 404 : 400;
      res.status(code).json({ success: false, error: msg }); return;
    }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[beauty/review] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur avis' }); }
});

router.post('/appointment/:id/no-show', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('mark_beauty_no_show_atomic', {
      p_appointment_id: req.params.id, p_actor_user_id: req.user!.id,
    });
    if (error) {
      const msg = error.message || '';
      const code = /NOT_PROVIDER/.test(msg) ? 403 : /NOT_FOUND/.test(msg) ? 404 : /INSUFFICIENT_FUNDS/.test(msg) ? 402 : 400;
      res.status(code).json({ success: false, error: msg });
      return;
    }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[beauty/no-show] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur no-show' });
  }
});

export default router;
