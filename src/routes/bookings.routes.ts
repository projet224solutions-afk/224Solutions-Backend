/**
 * 📅 RÉSERVATIONS DE PROXIMITÉ — RDV partagés (Ménage, Fitness, Coach, Réparation…).
 * Écritures sensibles via RPC service_role (atomiques, durcies REVOKE PUBLIC) :
 *   - POST /                 → créer une réservation (prestataire ou client).
 *   - POST /:id/status       → changer le statut (prestataire = tout ; client = annuler).
 * Lecture = directe via RLS côté front (chacun voit les siennes).
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

function mapError(msg: string): { code: number; error: string } {
  if (/BOOKING_LIMIT_REACHED/.test(msg)) return { code: 402, error: 'Limite de réservations de votre plan atteinte ce mois-ci. Passez à un plan supérieur.' };
  if (/NOT_AUTHORIZED/.test(msg)) return { code: 403, error: 'Action non autorisée' };
  if (/CLIENT_CAN_ONLY_CANCEL/.test(msg)) return { code: 403, error: 'Un client ne peut qu\'annuler la réservation' };
  if (/SERVICE_NOT_FOUND/.test(msg)) return { code: 404, error: 'Service introuvable' };
  if (/BOOKING_NOT_FOUND/.test(msg)) return { code: 404, error: 'Réservation introuvable' };
  if (/BAD_STATUS/.test(msg)) return { code: 400, error: 'Statut invalide' };
  return { code: 400, error: msg };
}

/** POST /api/v2/bookings — créer une réservation. */
router.post('/', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const b = req.body ?? {};
    const { data, error } = await supabaseAdmin.rpc('create_service_booking', {
      p_service_id: b.service_id,
      p_actor_user_id: req.user!.id,
      p_customer_name: b.customer_name ?? null,
      p_customer_phone: b.customer_phone ?? null,
      p_service_code: b.service_code ?? null,
      p_service_label: b.service_label ?? null,
      p_scheduled_date: b.scheduled_date ?? null,
      p_scheduled_time: b.scheduled_time ?? null,
      p_duration_minutes: b.duration_minutes ?? null,
      p_address: b.address ?? null,
      p_price: b.price ?? 0,
      p_recurring: b.recurring ?? false,
      p_frequency: b.frequency ?? null,
      p_notes: b.notes ?? null,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[bookings:create] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la création de la réservation' });
  }
});

/** POST /api/v2/bookings/:id/status — changer le statut. */
router.post('/:id/status', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('update_service_booking_status', {
      p_booking_id: req.params.id,
      p_actor_user_id: req.user!.id,
      p_status: String(req.body?.status ?? ''),
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[bookings:status] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la mise à jour de la réservation' });
  }
});

export default router;
