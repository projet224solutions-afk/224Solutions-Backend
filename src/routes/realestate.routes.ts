/**
 * 🏠 IMMOBILIER / LOCATION — cycle locatif atomique (caution escrow + quittances).
 *   POST /api/v2/realestate/lease/start              → le locataire démarre un bail (caution + 1er loyer).
 *   POST /api/v2/realestate/lease/:id/pay-rent        → le locataire paie un loyer (quittance).
 *   POST /api/v2/realestate/lease/:id/release-deposit → le bailleur clôture : retenue PARTIELLE + motif.
 *   POST /api/v2/realestate/lease/:id/dispute-deposit → le locataire conteste une retenue (litige PDG).
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
  if (/RETENUE_INVALIDE/.test(msg)) return { code: 400, error: 'Montant de retenue invalide (0 à la caution)' };
  if (/MOTIF_REQUIS/.test(msg)) return { code: 400, error: 'Un motif est obligatoire pour retenir une partie de la caution' };
  if (/ETAT_DES_LIEUX_INVALIDE/.test(msg)) return { code: 400, error: 'État des lieux de sortie invalide' };
  if (/REMBOURSEMENT_LOCATAIRE_ECHOUE|RETENUE_BAILLEUR_ECHOUE/.test(msg)) return { code: 409, error: 'Crédit du wallet impossible — règlement annulé' };
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
    const body = req.body ?? {};
    const reason: string | null = typeof body.reason === 'string' && body.reason.trim() ? body.reason.trim() : null;
    const inventory_id: string | null = typeof body.inventory_id === 'string' && body.inventory_id ? body.inventory_id : null;

    // Nouveau contrat : { retained_amount, reason?, inventory_id? }.
    // Rétro-compat de l'ancien { refund }: refund===false ⇒ retenir toute la caution
    // (on lit le montant), sinon (refund true/absent) ⇒ 0 (tout rendre).
    let retained_amount: number;
    if (typeof body.retained_amount === 'number' && Number.isFinite(body.retained_amount)) {
      retained_amount = body.retained_amount;
    } else if (body.refund === false) {
      const { data: lease } = await supabaseAdmin.from('rental_leases').select('deposit_amount').eq('id', req.params.id).maybeSingle();
      retained_amount = lease ? Number((lease as any).deposit_amount) || 0 : 0;
    } else {
      retained_amount = 0;
    }
    if (retained_amount < 0) { res.status(400).json({ success: false, error: 'Montant de retenue invalide' }); return; }

    const { data, error } = await supabaseAdmin.rpc('release_deposit_atomic', {
      p_actor_user_id: req.user!.id,
      p_lease_id: req.params.id,
      p_retained_amount: retained_amount,
      p_reason: reason,
      p_inventory_id: inventory_id,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[realestate/release] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur caution' }); }
});

/**
 * POST /lease/:id/dispute-deposit — le LOCATAIRE conteste une retenue de caution.
 * Ouvre un litige dans escrow_disputes (circuit d'arbitrage PDG existant), SANS mouvement
 * d'argent (les fonds ont déjà été répartis par release_deposit_atomic). Le bail est relié
 * via metadata.lease_id ; l'index partiel uniq_open_lease_deposit_dispute empêche le doublon.
 */
router.post('/lease/:id/dispute-deposit', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const leaseId = req.params.id;
    const userId = req.user!.id;
    const reason = typeof req.body?.reason === 'string' ? req.body.reason.trim() : '';
    if (!reason) { res.status(400).json({ success: false, error: 'Motif de contestation requis' }); return; }

    const { data: lease, error: leaseErr } = await supabaseAdmin
      .from('rental_leases')
      .select('id, tenant_user_id, property_id, deposit_amount, deposit_retained_amount, deposit_settled_at')
      .eq('id', leaseId)
      .maybeSingle();
    if (leaseErr) throw leaseErr;
    if (!lease) { res.status(404).json({ success: false, error: 'Bail introuvable' }); return; }
    if ((lease as any).tenant_user_id !== userId) { res.status(403).json({ success: false, error: 'Action réservée au locataire' }); return; }

    const retained = Number((lease as any).deposit_retained_amount || 0);
    if (retained <= 0) { res.status(409).json({ success: false, error: 'Aucune retenue à contester' }); return; }

    // Délai de contestation : 30 jours après le règlement de la caution.
    const settledAt = (lease as any).deposit_settled_at ? new Date((lease as any).deposit_settled_at) : null;
    if (settledAt && (Date.now() - settledAt.getTime()) / 86400000 > 30) {
      res.status(409).json({ success: false, error: 'Délai de contestation dépassé (30 jours)' }); return;
    }

    const { data: dispute, error: insErr } = await supabaseAdmin
      .from('escrow_disputes')
      .insert({
        escrow_id: null,
        initiator_user_id: userId,
        initiator_role: 'buyer',
        reason: `Contestation de retenue de caution (bail ${leaseId}) — ${retained} GNF retenus. ${reason}`,
        status: 'open',
        metadata: {
          entity_type: 'rental_lease',
          type: 'deposit_retention',
          lease_id: leaseId,
          property_id: (lease as any).property_id,
          deposit_amount: (lease as any).deposit_amount,
          retained_amount: retained,
        },
      })
      .select('id')
      .single();
    if (insErr || !dispute) {
      if ((insErr as any)?.code === '23505') { res.status(409).json({ success: false, error: 'Une contestation est déjà en cours pour ce bail' }); return; }
      logger.error(`[realestate/dispute-deposit] ${insErr?.message}`);
      res.status(500).json({ success: false, error: 'Erreur ouverture du litige' }); return;
    }

    // Notifier le PDG actif (best-effort — le litige est déjà visible dans /disputes/list).
    try {
      const { data: pdg } = await supabaseAdmin.from('pdg_management').select('user_id').eq('is_active', true).limit(1).maybeSingle();
      if ((pdg as any)?.user_id) {
        await supabaseAdmin.from('notifications').insert({
          user_id: (pdg as any).user_id,
          title: 'Contestation de caution locative',
          message: `Un locataire conteste une retenue de caution de ${retained} GNF.`,
          type: 'dispute',
          read: false,
          metadata: { entity_type: 'rental_lease', lease_id: leaseId, dispute_id: (dispute as any).id },
        });
      }
    } catch { /* best-effort : ne bloque pas la contestation */ }

    res.json({ success: true, dispute_id: (dispute as any).id });
  } catch (e: any) { logger.error(`[realestate/dispute-deposit] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur contestation caution' }); }
});

export default router;
