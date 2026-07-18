/**
 * 🚚 DELIVERY ROUTES - Backend Node.js centralisé
 *
 * Données critiques de livraison déplacées côté backend (gains, paiement wallet).
 * Le frontend ne calcule plus les gains ni ne déclenche de mouvement wallet directement.
 *
 * Tables utilisées : `deliveries`, `drivers`, `wallets` (via wallet.service)
 *
 * Endpoints (montés sur /api/v2/delivery) :
 *   - GET  /stats     — statistiques de gains (jour/semaine/mois/total) du livreur connecté
 *   - POST /complete  — finalise une livraison : écrit driver_earning + incrémente les totaux driver
 *   - POST /payment   — encaisse : crédite le wallet du livreur (idempotent) et marque la livraison payée
 *
 * ⚠️ deliveries.driver_id référence profiles.id = user.id (auth uid).
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { creditWallet } from '../services/wallet.service.js';
import { createNotifications } from '../services/notification.service.js';
import { emitCoreFeatureEvent } from '../services/coreFeatureEvents.service.js';

const router = Router();

// Commission plateforme : le livreur perçoit 98,5 % des frais de livraison.
const DRIVER_EARNING_RATE = 0.985;

// Méthodes de paiement déclenchant un crédit wallet (le cash est encaissé en main propre).
const ELECTRONIC_METHODS = new Set(['wallet', 'mobile_money', 'prepaid', 'card', 'bank']);

/** Gain livreur pour une livraison (driver_earning si présent, sinon 98,5 % des frais). */
function resolveDriverEarning(delivery: { driver_earning?: number | null; delivery_fee?: number | null }): number {
  const stored = Number(delivery.driver_earning);
  if (Number.isFinite(stored) && stored > 0) return stored;
  const fee = Number(delivery.delivery_fee) || 0;
  return Math.round(fee * DRIVER_EARNING_RATE);
}

/**
 * GET /api/v2/delivery/stats
 * Gains et nombre de livraisons du livreur connecté (jour / semaine / mois / total).
 * Corrige le bug historique : filtre sur driver_id = user.id (et non drivers.id).
 */
router.get('/stats', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const now = new Date();
    const startOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate()).toISOString();
    const weekStart = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000).toISOString();
    const monthStart = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000).toISOString();

    const { data, error } = await supabaseAdmin
      .from('deliveries')
      .select('driver_earning, delivery_fee, completed_at')
      .eq('driver_id', userId)
      .eq('status', 'delivered');

    if (error) throw error;

    const rows = data || [];
    const sumSince = (since: string) => {
      const filtered = rows.filter((d: any) => d.completed_at && d.completed_at >= since);
      return {
        earnings: filtered.reduce((s: number, d: any) => s + resolveDriverEarning(d), 0),
        count: filtered.length,
      };
    };

    const today = sumSince(startOfDay);
    const week = sumSince(weekStart);
    const month = sumSince(monthStart);
    const totalEarnings = rows.reduce((s: number, d: any) => s + resolveDriverEarning(d), 0);

    res.json({
      success: true,
      data: {
        todayEarnings: today.earnings,
        todayDeliveries: today.count,
        weekEarnings: week.earnings,
        weekDeliveries: week.count,
        monthEarnings: month.earnings,
        monthDeliveries: month.count,
        totalEarnings,
        totalDeliveries: rows.length,
      },
    });
  } catch (error: any) {
    logger.error(`[Delivery] stats error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du chargement des statistiques' });
  }
});

/**
 * POST /api/v2/delivery/complete
 * Finalise une livraison : écrit driver_earning (98,5 %) + incrémente les totaux du driver.
 * N'effectue AUCUN mouvement wallet (l'encaissement passe par /payment).
 *
 * Body : { delivery_id, proof_photo_url?, signature? }
 */
router.post('/complete', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { delivery_id, proof_photo_url, signature } = req.body || {};

    if (!delivery_id || typeof delivery_id !== 'string') {
      res.status(400).json({ success: false, error: 'delivery_id requis' });
      return;
    }

    // 1) Transition ATOMIQUE en base : livraison 'delivered' + gain + totaux livreur dans
    //    UNE seule transaction (RPC FOR UPDATE + autorisation + idempotence). Plus d'état partiel.
    const { data: rpcRes, error: rpcError } = await supabaseAdmin.rpc('complete_delivery', {
      p_delivery_id: delivery_id,
      p_driver_id: userId,
      p_proof: proof_photo_url || null,
      p_signature: signature || null,
    });
    if (rpcError) throw rpcError;
    const r = (rpcRes || {}) as any;

    if (!r.success) {
      res.status(404).json({ success: false, error: 'Livraison introuvable ou non assignée à ce livreur' });
      return;
    }

    const earning = Number(r.driver_earning) || 0;
    const isCash = !!r.is_cash;
    const alreadyDelivered = !!r.already_completed;
    let credited = false;

    // 2) Règlement du gain — idempotent ET ré-essayable (clé `delivery-earning:<id>`).
    //    Le RPC marque déjà le cash comme réglé ; ici on traite l'électronique.
    if (!isCash && !r.already_paid) {
      const creditResult = await creditWallet(
        userId,
        earning,
        `Gain livraison #${String(delivery_id).slice(0, 8)}`,
        `delivery_${delivery_id}`,
        'delivery_earning',
        `delivery-earning:${delivery_id}`,
      );
      credited = creditResult.success;
      if (credited) {
        // Marquer réglé seulement après crédit RÉUSSI (sinon un futur appel pourra recréditer).
        await supabaseAdmin
          .from('deliveries')
          .update({ driver_payment_method: String(r.payment_method || 'wallet') })
          .eq('id', delivery_id)
          .eq('driver_id', userId);
      } else {
        logger.warn(`[Delivery] wallet credit failed for delivery=${delivery_id}: ${creditResult.error}`);
      }
    }

    logger.info(`[Delivery] Completed: delivery=${delivery_id}, driver=${userId}, earning=${earning}, credited=${credited}, alreadyDelivered=${alreadyDelivered}`);
    await emitCoreFeatureEvent({
      featureKey: 'delivery.complete',
      coreEngine: 'commerce',
      ownerModule: 'delivery',
      criticality: 'high',
      status: 'success',
      userId,
      payload: { delivery_id, driver_earning: earning, credited, already_completed: alreadyDelivered },
    });

    res.json({ success: true, driver_earning: earning, credited, already_completed: alreadyDelivered });
  } catch (error: any) {
    logger.error(`[Delivery] complete error: ${error.message}`);
    await emitCoreFeatureEvent({
      featureKey: 'delivery.complete',
      coreEngine: 'commerce',
      ownerModule: 'delivery',
      criticality: 'high',
      status: 'failure',
      userId: req.user?.id || null,
      payload: { error: error.message },
    });
    res.status(500).json({ success: false, error: 'Erreur lors de la finalisation de la livraison' });
  }
});

/**
 * POST /api/v2/delivery/payment
 * Encaisse une livraison terminée.
 *  - Méthodes électroniques (wallet, mobile money, prépayé…) → crédite le wallet du livreur (idempotent).
 *  - Espèces (cash) → aucun mouvement wallet (encaissé en main propre), simple marquage.
 * Marque la livraison payée via driver_payment_method.
 *
 * Body : { delivery_id, payment_method }
 */
router.post('/payment', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { delivery_id, payment_method } = req.body || {};

    if (!delivery_id || typeof delivery_id !== 'string') {
      res.status(400).json({ success: false, error: 'delivery_id requis' });
      return;
    }
    const method = String(payment_method || 'cash').toLowerCase();

    const { data: delivery, error: fetchError } = await supabaseAdmin
      .from('deliveries')
      .select('id, status, driver_id, delivery_fee, driver_earning, driver_payment_method')
      .eq('id', delivery_id)
      .eq('driver_id', userId)
      .maybeSingle();

    if (fetchError) throw fetchError;
    if (!delivery) {
      res.status(404).json({ success: false, error: 'Livraison introuvable ou non assignée à ce livreur' });
      return;
    }
    if (delivery.status !== 'delivered') {
      res.status(400).json({ success: false, error: 'La livraison doit être terminée avant l\'encaissement' });
      return;
    }

    const earning = resolveDriverEarning(delivery);

    // Idempotent : déjà encaissée
    if (delivery.driver_payment_method) {
      res.json({ success: true, already_paid: true, amount: earning, credited: false });
      return;
    }

    const isElectronic = ELECTRONIC_METHODS.has(method);
    let credited = false;

    if (isElectronic) {
      const idemKey = `delivery-earning:${delivery_id}`;
      const result = await creditWallet(
        userId,
        earning,
        `Gain livraison #${String(delivery_id).slice(0, 8)}`,
        `delivery_${delivery_id}`,
        'delivery_earning',
        idemKey,
      );

      if (!result.success) {
        await emitCoreFeatureEvent({
          featureKey: 'delivery.payment',
          coreEngine: 'payment',
          ownerModule: 'delivery',
          criticality: 'critical',
          status: 'failure',
          userId,
          payload: { delivery_id, amount: earning, method, error: result.error || 'credit_failed' },
        });
        res.status(400).json({ success: false, error: result.error || 'Échec du crédit wallet' });
        return;
      }
      credited = true;
    }

    // Marquer la livraison comme payée (driver_payment_method = marqueur d'encaissement)
    const { error: markError } = await supabaseAdmin
      .from('deliveries')
      .update({ driver_payment_method: method, payment_method: method })
      .eq('id', delivery_id)
      .eq('driver_id', userId);

    if (markError) throw markError;

    logger.info(`[Delivery] Payment: delivery=${delivery_id}, driver=${userId}, amount=${earning}, method=${method}, credited=${credited}`);
    await emitCoreFeatureEvent({
      featureKey: 'delivery.payment',
      coreEngine: 'payment',
      ownerModule: 'delivery',
      criticality: 'critical',
      status: 'success',
      userId,
      payload: { delivery_id, amount: earning, method, credited },
    });

    res.json({ success: true, amount: earning, credited, method });
  } catch (error: any) {
    logger.error(`[Delivery] payment error: ${error.message}`);
    await emitCoreFeatureEvent({
      featureKey: 'delivery.payment',
      coreEngine: 'payment',
      ownerModule: 'delivery',
      criticality: 'critical',
      status: 'failure',
      userId: req.user?.id || null,
      payload: { error: error.message },
    });
    res.status(500).json({ success: false, error: 'Erreur lors de l\'encaissement' });
  }
});

/** Statuts considérés comme « en cours » pour une livraison assignée à un livreur. */
const ACTIVE_DRIVER_STATUSES = new Set(['assigned', 'picked_up', 'in_transit']);

/**
 * POST /api/v2/delivery/accept
 * Le livreur réclame une livraison DISPONIBLE. Claim ATOMIQUE : l'update conditionnel
 * (status='pending' AND driver_id IS NULL) garantit qu'un seul livreur l'obtient même en
 * cas de course (anti double-affectation). Idempotent si le même livreur réessaie.
 *
 * Body : { delivery_id }
 */
router.post('/accept', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { delivery_id } = req.body || {};
    if (!delivery_id || typeof delivery_id !== 'string') {
      res.status(400).json({ success: false, error: 'delivery_id requis' });
      return;
    }

    // Claim ATOMIQUE en base (FOR UPDATE + autorisation + idempotence dans le RPC).
    const { data: rpcRes, error: rpcError } = await supabaseAdmin
      .rpc('accept_delivery', { p_delivery_id: delivery_id, p_driver_id: userId });
    if (rpcError) throw rpcError;
    const r = (rpcRes || {}) as any;

    if (!r.success) {
      const status = r.error === 'not_found' ? 404 : 409;
      res.status(status).json({
        success: false,
        error: r.error === 'not_found' ? 'Livraison introuvable' : 'Cette livraison n\'est plus disponible',
      });
      return;
    }

    // Charger la ligne (le frontend en a besoin pour afficher la course courante).
    const { data: row } = await supabaseAdmin.from('deliveries').select('*').eq('id', delivery_id).maybeSingle();

    if (!r.already_assigned) {
      await emitCoreFeatureEvent({
        featureKey: 'delivery.accept', coreEngine: 'commerce', ownerModule: 'delivery',
        criticality: 'high', status: 'success', userId, payload: { delivery_id },
      });
    }
    res.json({ success: true, data: row, already_assigned: !!r.already_assigned });
  } catch (error: any) {
    logger.error(`[Delivery] accept error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'acceptation de la livraison' });
  }
});

/**
 * POST /api/v2/delivery/start
 * Démarre une livraison (colis récupéré). Transition autorisée seulement si la livraison
 * est ASSIGNÉE à CE livreur (update conditionnel).
 *
 * Body : { delivery_id }
 */
router.post('/start', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { delivery_id } = req.body || {};
    if (!delivery_id || typeof delivery_id !== 'string') {
      res.status(400).json({ success: false, error: 'delivery_id requis' });
      return;
    }

    const { data: rpcRes, error: rpcError } = await supabaseAdmin
      .rpc('start_delivery', { p_delivery_id: delivery_id, p_driver_id: userId });
    if (rpcError) throw rpcError;
    const r = (rpcRes || {}) as any;

    if (!r.success) {
      const msg = r.error === 'not_owner'
        ? 'Livraison non assignée à ce livreur'
        : 'État invalide pour le démarrage';
      res.status(400).json({ success: false, error: msg });
      return;
    }

    const { data: row } = await supabaseAdmin.from('deliveries').select('*').eq('id', delivery_id).maybeSingle();
    res.json({ success: true, data: row, already_started: !!r.already_started });
  } catch (error: any) {
    logger.error(`[Delivery] start error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du démarrage de la livraison' });
  }
});

/**
 * POST /api/v2/delivery/cancel
 * Annule une livraison assignée à CE livreur (tant qu'elle n'est pas livrée). On NE remet
 * PAS driver_id à null (trace d'audit) ; le statut 'cancelled' la sort des files actives.
 *
 * Body : { delivery_id, reason }
 */
router.post('/cancel', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { delivery_id, reason } = req.body || {};
    if (!delivery_id || typeof delivery_id !== 'string') {
      res.status(400).json({ success: false, error: 'delivery_id requis' });
      return;
    }

    const { data: rpcRes, error: rpcError } = await supabaseAdmin
      .rpc('cancel_delivery', { p_delivery_id: delivery_id, p_driver_id: userId, p_reason: reason || null });
    if (rpcError) throw rpcError;
    const r = (rpcRes || {}) as any;

    if (!r.success) {
      if (r.error === 'not_owner') {
        res.status(404).json({ success: false, error: 'Livraison introuvable ou non assignée à ce livreur' });
      } else if (r.error === 'already_delivered') {
        res.status(400).json({ success: false, error: 'Une livraison terminée ne peut pas être annulée' });
      } else {
        res.status(400).json({ success: false, error: 'Annulation impossible' });
      }
      return;
    }

    if (!r.already_cancelled) {
      await emitCoreFeatureEvent({
        featureKey: 'delivery.cancel', coreEngine: 'commerce', ownerModule: 'delivery',
        criticality: 'medium', status: 'success', userId, payload: { delivery_id, reason: reason || null },
      });
    }
    res.json({ success: true, already_cancelled: !!r.already_cancelled });
  } catch (error: any) {
    logger.error(`[Delivery] cancel error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'annulation de la livraison' });
  }
});

/**
 * POST /api/v2/delivery/track
 * Enregistre un point GPS du livreur (source de vérité = backend, validé). Le client garde
 * la diffusion broadcast pour la basse latence ; ICI on sécurise l'écriture en base : seul le
 * livreur ASSIGNÉ peut tracer SA livraison active. Best-effort, non bloquant côté client.
 *
 * Body : { delivery_id, latitude, longitude, speed?, heading?, accuracy? }
 */
router.post('/track', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { delivery_id, latitude, longitude, speed, heading, accuracy } = req.body || {};

    if (!delivery_id || typeof delivery_id !== 'string') {
      res.status(400).json({ success: false, error: 'delivery_id requis' });
      return;
    }
    const lat = Number(latitude), lng = Number(longitude);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      res.status(400).json({ success: false, error: 'Coordonnées invalides' });
      return;
    }

    // Autorisation : la livraison doit appartenir à ce livreur ET être active.
    const { data: delivery, error: fetchError } = await supabaseAdmin
      .from('deliveries')
      .select('id, status, driver_id')
      .eq('id', delivery_id)
      .eq('driver_id', userId)
      .maybeSingle();

    if (fetchError) throw fetchError;
    if (!delivery || !ACTIVE_DRIVER_STATUSES.has(delivery.status)) {
      res.status(403).json({ success: false, error: 'Suivi non autorisé pour cette livraison' });
      return;
    }

    const { error: insertError } = await supabaseAdmin
      .from('delivery_tracking')
      .insert({
        delivery_id,
        driver_id: userId,
        latitude: lat,
        longitude: lng,
        speed: Number.isFinite(Number(speed)) ? Number(speed) : null,
        heading: Number.isFinite(Number(heading)) ? Number(heading) : null,
        accuracy: Number.isFinite(Number(accuracy)) ? Number(accuracy) : null,
        recorded_at: new Date().toISOString(),
      });

    if (insertError) throw insertError;
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[Delivery] track error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'enregistrement de la position' });
  }
});

/** Charge une livraison ET vérifie que l'appelant est bien le VENDEUR propriétaire. */
async function loadDeliveryOwnedByVendor(deliveryId: string, userId: string) {
  const { data: delivery, error } = await supabaseAdmin
    .from('deliveries')
    .select('id, status, driver_id, vendor_id, vendor_name, delivery_fee, distance_km, pickup_address, delivery_address, customer_name, payment_method, price')
    .eq('id', deliveryId)
    .maybeSingle();
  if (error) throw error;
  if (!delivery) return { delivery: null as any, owned: false };
  const { data: vendor, error: vErr } = await supabaseAdmin
    .from('vendors')
    .select('id, user_id, business_name, latitude, longitude')
    .eq('id', (delivery as any).vendor_id)
    .maybeSingle();
  if (vErr) throw vErr;
  return { delivery: delivery as any, vendor: vendor as any, owned: !!vendor && (vendor as any).user_id === userId };
}

/**
 * POST /api/v2/delivery/dispatch
 * « Confier à un livreur 224 » : propose la course au réseau — offres tracées
 * (delivery_offers, 15 min) + notification in-app à chaque candidat. Candidats :
 *  1. taxi-motos EN LIGNE avec position ≤ 10 km (haversine du moteur taxi existant) ;
 *  2. livreurs de la plateforme (rôle livreur/driver) — le modèle « pull » existant
 *     (liste des courses pending) reste leur filet, la notification les fait venir.
 * L'ACCEPTATION reste le claim atomique existant (/accept) : premier arrivé, premier servi.
 *
 * Body : { delivery_id }
 */
router.post('/dispatch', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { delivery_id } = req.body || {};
    if (!delivery_id || typeof delivery_id !== 'string') {
      res.status(400).json({ success: false, error: 'delivery_id requis' });
      return;
    }

    const { delivery, vendor, owned } = await loadDeliveryOwnedByVendor(delivery_id, userId);
    if (!delivery) { res.status(404).json({ success: false, error: 'Livraison introuvable' }); return; }
    if (!owned) { res.status(403).json({ success: false, error: 'Cette livraison ne vous appartient pas' }); return; }
    if (delivery.status !== 'pending' || delivery.driver_id) {
      res.status(400).json({ success: false, error: 'Livraison déjà assignée ou hors dispatch' });
      return;
    }

    const fee = Number(delivery.delivery_fee) || 0;
    const estimatedEarnings = Math.round(fee * DRIVER_EARNING_RATE);
    const pickup = (delivery.pickup_address || {}) as any;
    const pLat = Number(pickup.lat ?? vendor?.latitude);
    const pLng = Number(pickup.lng ?? vendor?.longitude);

    // Candidats : user_id → distance connue (km) ou null.
    const candidates = new Map<string, number | null>();

    // 1) Taxi-motos proches (haversine, moteur existant) — best-effort : un échec de la RPC
    //    ne bloque pas le dispatch (les livreurs « pull » restent notifiés).
    if (Number.isFinite(pLat) && Number.isFinite(pLng)) {
      try {
        const { data: nearby } = await supabaseAdmin.rpc('find_nearby_taxi_drivers', {
          p_lat: pLat, p_lng: pLng, p_radius_km: 10, p_limit: 10, p_taxi_category: null,
        } as any);
        for (const d of (nearby || []) as any[]) {
          const uid = d.user_id || d.driver_user_id;
          if (uid) candidates.set(String(uid), Number(d.distance_km) || null);
        }
      } catch (e: any) {
        logger.warn(`[Delivery] dispatch nearby lookup failed: ${e.message}`);
      }
    }

    // 2) Livreurs plateforme (rôle livreur/driver) — position inconnue hors course.
    const { data: couriers } = await supabaseAdmin
      .from('profiles')
      .select('id')
      .in('role', ['livreur', 'driver'])
      .limit(30);
    for (const p of (couriers || []) as any[]) {
      if (!candidates.has(String(p.id))) candidates.set(String(p.id), null);
    }
    candidates.delete(userId); // jamais s'auto-proposer

    if (candidates.size === 0) {
      res.status(404).json({ success: false, error: 'Aucun livreur disponible sur la plateforme', error_code: 'NO_COURIER' });
      return;
    }

    // 3) Offres tracées (15 min) — best-effort, la notification est le signal principal.
    const now = Date.now();
    const offers = Array.from(candidates.entries()).map(([driverUserId, dist]) => ({
      delivery_id,
      driver_id: driverUserId,
      status: 'sent',
      offered_at: new Date(now).toISOString(),
      expires_at: new Date(now + 15 * 60 * 1000).toISOString(),
      distance_to_vendor: dist,
      estimated_earnings: estimatedEarnings,
    }));
    const { error: offersError } = await supabaseAdmin.from('delivery_offers').insert(offers as any);
    if (offersError) logger.warn(`[Delivery] dispatch offers insert failed: ${offersError.message}`);

    // 4) Notification in-app à chaque candidat (cloche + deep-link vers l'espace livreur).
    const destination = ((delivery.delivery_address || {}) as any).address || ((delivery.delivery_address || {}) as any).address_line || '';
    const notified = await createNotifications(
      Array.from(candidates.keys()).map((driverUserId) => ({
        userId: driverUserId,
        title: '🛵 Course de livraison proposée',
        message: `${vendor?.business_name || delivery.vendor_name || 'Vendeur 224'} → ${destination} · gain estimé ${estimatedEarnings.toLocaleString('fr-FR')} GNF`,
        type: 'delivery',
        metadata: { link: '/livreur', delivery_id, estimated_earnings: estimatedEarnings },
      })),
    );

    logger.info(`[Delivery] dispatch: delivery=${delivery_id}, vendor=${userId}, candidates=${candidates.size}, notified=${notified}`);
    res.json({ success: true, data: { candidates: candidates.size, notified } });
  } catch (error: any) {
    logger.error(`[Delivery] dispatch error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la proposition aux livreurs' });
  }
});

/**
 * POST /api/v2/delivery/self-assign
 * « Je livre moi-même » : le vendeur devient le livreur de SA livraison. Claim atomique
 * (status pending + sans livreur), gain à zéro et encaissement marqué 'self' — le circuit
 * de gains livreur (98,5 % + crédit wallet) ne se déclenche JAMAIS pour une auto-livraison.
 *
 * Body : { delivery_id }
 */
router.post('/self-assign', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { delivery_id } = req.body || {};
    if (!delivery_id || typeof delivery_id !== 'string') {
      res.status(400).json({ success: false, error: 'delivery_id requis' });
      return;
    }

    const { delivery, owned } = await loadDeliveryOwnedByVendor(delivery_id, userId);
    if (!delivery) { res.status(404).json({ success: false, error: 'Livraison introuvable' }); return; }
    if (!owned) { res.status(403).json({ success: false, error: 'Cette livraison ne vous appartient pas' }); return; }
    if (delivery.driver_id === userId) { res.json({ success: true, already: true }); return; }

    // Claim atomique : même garde que /accept (pending + sans livreur).
    const { data: claimed, error: claimError } = await supabaseAdmin
      .from('deliveries')
      .update({
        driver_id: userId,
        status: 'assigned',
        accepted_at: new Date().toISOString(),
        driver_earning: 0,
        driver_payment_method: 'self', // déjà « réglé » → aucun crédit wallet au /complete
      })
      .eq('id', delivery_id)
      .eq('status', 'pending')
      .is('driver_id', null)
      .select('id')
      .maybeSingle();
    if (claimError) throw claimError;
    if (!claimed) {
      res.status(409).json({ success: false, error: 'Livraison déjà prise par un livreur' });
      return;
    }

    logger.info(`[Delivery] self-assign: delivery=${delivery_id}, vendor=${userId}`);
    res.json({ success: true });
  } catch (error: any) {
    logger.error(`[Delivery] self-assign error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'auto-assignation' });
  }
});

export default router;
