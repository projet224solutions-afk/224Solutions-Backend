/**
 * ✈️ VOL/HÔTEL Phase 2 — réservation + séquestre + billets (routes /api/v2/travel).
 *
 * Flux : le client RÉSERVE une offre d'agence → l'agence CONFIRME le prix (±30 %) → le client
 * PAIE (fonds en séquestre via hold_travel_booking_escrow) → l'agence dépose le BILLET (bucket
 * privé) → le client CONFIRME la réception (release_escrow_to_seller) OU auto-release J+14.
 *
 * Argent : RPC atomiques existantes/dédiées uniquement (jamais d'UPDATE direct de solde).
 * Contrat API : ok()/fail(). Modèle de commission UNIFIÉ (agence reçoit le prix complet, le
 * client paie la commission en plus). Billets = bucket privé, URL signée gatée (jamais public).
 */
import { Router, type Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { ok, fail } from '../utils/apiResponse.js';
import { verifyJWT, type AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { idempotencyGuard } from '../middlewares/idempotency.middleware.js';

const router = Router();
const UUID = '([0-9a-fA-F-]{36})';
const TRAVEL_BUCKET = 'travel-documents';
const SIGNED_URL_TTL = 300; // 5 min
const PDG_ROLES = ['admin', 'pdg', 'ceo'];
const MAX_DOC_BYTES = 6 * 1024 * 1024; // ~6 Mo (billet PDF/image)
const ALLOWED_DOC_TYPES = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

// ── Helpers ──────────────────────────────────────────────────────────────────

/** L'appelant est-il le propriétaire du service prestataire (agence) ? + son user_id. */
async function getAgencyOwner(agencyServiceId: string): Promise<string | null> {
  const { data } = await supabaseAdmin.from('professional_services').select('user_id').eq('id', agencyServiceId).maybeSingle();
  return (data as any)?.user_id ?? null;
}

/** customers.id du voyageur (get-or-create) — exigé par orders.customer_id. */
async function getOrCreateCustomerId(userId: string): Promise<string> {
  const { data: existing } = await supabaseAdmin.from('customers').select('id').eq('user_id', userId).maybeSingle();
  if ((existing as any)?.id) return (existing as any).id;
  const { data: created, error } = await supabaseAdmin.from('customers').insert({ user_id: userId }).select('id').single();
  if (error) throw error;
  return (created as any).id;
}

/** vendors.id ACTIF du user (l'agence doit avoir une boutique 224 pour recevoir en séquestre). */
async function resolveVendorId(sellerUserId: string): Promise<string | null> {
  const { data } = await supabaseAdmin.from('vendors').select('id').eq('user_id', sellerUserId).eq('is_active', true).maybeSingle();
  return (data as any)?.id ?? null;
}

/** Taux de commission plateforme sur le voyage — CONFIG PDG (pdg_settings), défaut 5 %. */
async function getTravelCommissionPct(): Promise<number> {
  try {
    const { data } = await supabaseAdmin.from('pdg_settings').select('setting_value').eq('setting_key', 'travel_commission_percentage').maybeSingle();
    const raw = (data as any)?.setting_value;
    const v = typeof raw === 'object' && raw !== null ? Number(raw.value) : Number(raw);
    if (Number.isFinite(v) && v >= 0 && v <= 100) return v;
  } catch { /* défaut ci-dessous */ }
  return 5;
}

const HOLD_ERR: Record<string, { status: number; msg: string; code: string }> = {
  INSUFFICIENT_FUNDS: { status: 400, msg: 'Solde insuffisant pour payer cette réservation.', code: 'INSUFFICIENT_FUNDS' },
  BUYER_WALLET_NOT_FOUND: { status: 400, msg: 'Aucun portefeuille dans cette devise.', code: 'NO_WALLET' },
  WALLET_BLOCKED: { status: 403, msg: 'Votre portefeuille est bloqué.', code: 'WALLET_BLOCKED' },
  PRICE_NOT_CONFIRMED: { status: 409, msg: "Le prix n'a pas encore été confirmé par l'agence.", code: 'PRICE_NOT_CONFIRMED' },
  AMOUNT_MISMATCH: { status: 409, msg: 'Le montant a changé, rafraîchissez la réservation.', code: 'AMOUNT_MISMATCH' },
  NOT_BOOKING_OWNER: { status: 403, msg: 'Réservation non autorisée.', code: 'FORBIDDEN' },
};
function mapHoldError(raw: string): { status: number; msg: string; code: string } {
  const key = String(raw || '').match(/[A-Z_]{5,}/)?.[0] || '';
  return HOLD_ERR[key] || { status: 400, msg: "Le paiement n'a pas pu aboutir.", code: 'HOLD_FAILED' };
}

// ── 1. POST /bookings — le client crée une demande de réservation (status 'pending') ──
router.post('/bookings', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const bookingType = String(req.body?.booking_type || '').toLowerCase();
    const offerId = String(req.body?.offer_id || '');
    const travelerInfo = (req.body?.traveler_info && typeof req.body.traveler_info === 'object') ? req.body.traveler_info : {};
    const guests = Math.max(1, Math.min(20, Number(req.body?.guests_count) || 1));
    if (!['flight', 'hotel'].includes(bookingType) || !offerId) return fail(res, 400, 'Paramètres invalides', 'BAD_PARAMS');

    // Offre d'AGENCE uniquement (agency_service_id présent) — les offres d'affiliation ne sont pas réservables ici.
    const table = bookingType === 'flight' ? 'flight_offers' : 'hotel_offers';
    const priceCol = bookingType === 'flight' ? 'price_adult' : 'price_per_night';
    const { data: offer } = await supabaseAdmin.from(table as any)
      .select(`id, agency_service_id, currency, ${priceCol}`).eq('id', offerId).maybeSingle();
    if (!offer || !(offer as any).agency_service_id) return fail(res, 400, "Cette offre n'est pas réservable en direct.", 'OFFER_NOT_BOOKABLE');

    const unit = Number((offer as any)[priceCol]) || 0;
    const estimate = Math.max(0, Math.round(unit * guests));
    const ref = 'TRV-' + Date.now().toString(36).toUpperCase() + '-' + Math.random().toString(36).slice(2, 6).toUpperCase();
    const row: any = {
      user_id: userId, booking_type: bookingType, booking_reference: ref, agency_service_id: (offer as any).agency_service_id,
      traveler_info: travelerInfo, guests_count: guests, total_amount: estimate, currency: (offer as any).currency || 'GNF',
      status: 'pending', payment_status: 'pending',
      check_in_date: req.body?.check_in_date || null, check_out_date: req.body?.check_out_date || null,
    };
    row[bookingType === 'flight' ? 'flight_offer_id' : 'hotel_offer_id'] = offerId;

    const { data: booking, error } = await supabaseAdmin.from('travel_bookings').insert(row).select('*').single();
    if (error) return fail(res, 400, error.message);
    return ok(res, { booking });
  } catch (e: any) {
    logger.error(`[travel/bookings] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── 2. POST /bookings/:id/confirm-price — l'AGENCE confirme le prix (±30 % de l'estimation) ──
router.post(`/bookings/:id${UUID}/confirm-price`, verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const bookingId = req.params.id;
    const amount = Math.round(Number(req.body?.amount) || 0);
    if (amount <= 0) return fail(res, 400, 'Montant invalide', 'BAD_AMOUNT');

    const { data: booking } = await supabaseAdmin.from('travel_bookings')
      .select('id, agency_service_id, status, total_amount').eq('id', bookingId).maybeSingle();
    if (!booking) return fail(res, 404, 'Réservation introuvable');
    const owner = await getAgencyOwner((booking as any).agency_service_id);
    if (!owner || owner !== userId) return fail(res, 403, "Réservé à l'agence propriétaire", 'FORBIDDEN');
    if ((booking as any).status !== 'pending') return fail(res, 409, 'Le prix a déjà été confirmé ou la réservation a changé.', 'NOT_PENDING');

    // Garde-fou : le prix confirmé reste dans ±30 % de l'estimation (anti-abus). Estimation nulle
    // = pas de repère fiable → on refuse (l'offre doit avoir un prix).
    const est = Number((booking as any).total_amount) || 0;
    if (est <= 0) return fail(res, 400, "L'offre n'a pas de prix de référence, réservation non confirmable.", 'NO_REFERENCE_PRICE');
    if (amount < est * 0.7 || amount > est * 1.3) {
      return fail(res, 400, 'Le prix confirmé doit rester dans ±30 % de l’estimation.', 'PRICE_OUT_OF_RANGE');
    }

    const { error } = await supabaseAdmin.from('travel_bookings')
      .update({ confirmed_amount: amount, price_confirmed_at: new Date().toISOString(), status: 'price_confirmed', updated_at: new Date().toISOString() })
      .eq('id', bookingId).eq('status', 'pending');
    if (error) return fail(res, 400, error.message);
    return ok(res, { confirmed_amount: amount });
  } catch (e: any) {
    logger.error(`[travel/confirm-price] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── 3. POST /bookings/:id/pay — le CLIENT paie → séquestre (RPC atomique) ──
router.post(`/bookings/:id${UUID}/pay`, verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const bookingId = req.params.id;
    const { data: booking } = await supabaseAdmin.from('travel_bookings')
      .select('id, user_id, agency_service_id, status, confirmed_amount, currency, escrow_id').eq('id', bookingId).maybeSingle();
    if (!booking) return fail(res, 404, 'Réservation introuvable');
    if ((booking as any).user_id !== userId) return fail(res, 403, 'Réservation non autorisée', 'FORBIDDEN');
    if ((booking as any).escrow_id) return ok(res, { already_paid: true, escrow_id: (booking as any).escrow_id });
    if ((booking as any).status !== 'price_confirmed' || !(booking as any).confirmed_amount) {
      return fail(res, 409, "Le prix n'a pas encore été confirmé.", 'PRICE_NOT_CONFIRMED');
    }

    const sellerUserId = await getAgencyOwner((booking as any).agency_service_id);
    if (!sellerUserId) return fail(res, 400, 'Agence introuvable', 'AGENCY_NOT_FOUND');
    if (sellerUserId === userId) return fail(res, 400, 'Vous ne pouvez pas réserver votre propre offre.', 'OWN_BOOKING');
    const vendorId = await resolveVendorId(sellerUserId);
    if (!vendorId) return fail(res, 400, 'Le paiement sécurisé requiert une agence avec une boutique 224Solutions.', 'ESCROW_SELLER_NOT_VENDOR');

    const customerId = await getOrCreateCustomerId(userId);
    const confirmed = Number((booking as any).confirmed_amount);
    const currency = (booking as any).currency || 'GNF';
    const pct = await getTravelCommissionPct();
    const commission = Math.round(confirmed * (pct / 100));
    const total = confirmed + commission; // modèle unifié : le client paie la commission en plus

    const { data, error } = await supabaseAdmin.rpc('hold_travel_booking_escrow', {
      p_booking_id: bookingId, p_buyer_user_id: userId, p_customer_id: customerId,
      p_vendor_id: vendorId, p_seller_user_id: sellerUserId,
      p_amount: total, p_commission: commission, p_currency: currency, p_auto_release_days: 14,
    });
    if (error) { const m = mapHoldError(error.message); logger.warn(`[travel/pay] ${error.message}`); return fail(res, m.status, m.msg, m.code); }
    return ok(res, { escrow_id: (data as any)?.escrow_id, order_id: (data as any)?.order_id, amount_paid: total, commission });
  } catch (e: any) {
    logger.error(`[travel/pay] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── 4. POST /bookings/:id/ticket — l'AGENCE dépose le billet (bucket privé) ──
router.post(`/bookings/:id${UUID}/ticket`, verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const bookingId = req.params.id;
    const fileB64 = String(req.body?.file_base64 || '');
    const contentType = String(req.body?.content_type || '');
    const filename = String(req.body?.filename || 'billet').replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 60);
    if (!fileB64 || !ALLOWED_DOC_TYPES.includes(contentType)) return fail(res, 400, 'Fichier invalide (PDF ou image).', 'BAD_FILE');

    const { data: booking } = await supabaseAdmin.from('travel_bookings')
      .select('id, agency_service_id, status, document_urls, escrow_id').eq('id', bookingId).maybeSingle();
    if (!booking) return fail(res, 404, 'Réservation introuvable');
    const owner = await getAgencyOwner((booking as any).agency_service_id);
    if (!owner || owner !== userId) return fail(res, 403, "Réservé à l'agence propriétaire", 'FORBIDDEN');
    if (!(booking as any).escrow_id) return fail(res, 409, "Le client n'a pas encore payé.", 'NOT_PAID');
    if (['completed', 'cancelled', 'refunded'].includes((booking as any).status)) {
      return fail(res, 409, 'Cette réservation est clôturée.', 'BOOKING_CLOSED');
    }

    const base64 = fileB64.includes(',') ? fileB64.split(',')[1] : fileB64;
    const buffer = Buffer.from(base64, 'base64');
    if (buffer.length === 0 || buffer.length > MAX_DOC_BYTES) return fail(res, 400, 'Fichier trop volumineux (max 6 Mo).', 'FILE_TOO_LARGE');

    const path = `${bookingId}/${Date.now()}_${filename}`;
    const { error: upErr } = await supabaseAdmin.storage.from(TRAVEL_BUCKET).upload(path, buffer, { contentType, upsert: false });
    if (upErr) { logger.error(`[travel/ticket] upload ${upErr.message}`); return fail(res, 400, "Échec de l'envoi du billet.", 'UPLOAD_FAILED'); }

    const docs = Array.isArray((booking as any).document_urls) ? (booking as any).document_urls : [];
    docs.push(path);
    const { error } = await supabaseAdmin.from('travel_bookings')
      .update({ document_urls: docs, ticket_url: path, status: 'ticket_delivered', updated_at: new Date().toISOString() })
      .eq('id', bookingId);
    if (error) return fail(res, 400, error.message);

    // PROTECTION : ce n'est qu'ICI (billet livré) qu'on ARME l'auto-release J+14 de l'escrow.
    // Avant, auto_release_at était NULL → aucun risque de payer l'agence sans livraison.
    const releaseAt = new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString();
    await supabaseAdmin.from('escrow_transactions')
      .update({ auto_release_at: releaseAt, auto_release_date: releaseAt })
      .eq('id', (booking as any).escrow_id).eq('status', 'held');
    return ok(res, { delivered: true, count: docs.length });
  } catch (e: any) {
    logger.error(`[travel/ticket] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── 5. GET /bookings/:id/ticket — URL signée du/des billet(s), GATÉE ──
router.get(`/bookings/:id${UUID}/ticket`, verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const role = String(req.user!.role || '').toLowerCase();
    const bookingId = req.params.id;
    const { data: booking } = await supabaseAdmin.from('travel_bookings')
      .select('id, user_id, agency_service_id, document_urls').eq('id', bookingId).maybeSingle();
    if (!booking) return fail(res, 404, 'Réservation introuvable');

    const isClient = (booking as any).user_id === userId;
    const isPdg = PDG_ROLES.includes(role);
    const owner = await getAgencyOwner((booking as any).agency_service_id);
    const isAgency = !!owner && owner === userId;
    if (!isClient && !isAgency && !isPdg) return fail(res, 403, 'Accès non autorisé', 'FORBIDDEN');

    const paths: string[] = Array.isArray((booking as any).document_urls) ? (booking as any).document_urls : [];
    const files: { url: string; name: string }[] = [];
    for (const p of paths) {
      const { data: s } = await supabaseAdmin.storage.from(TRAVEL_BUCKET).createSignedUrl(p, SIGNED_URL_TTL);
      if (s?.signedUrl) files.push({ url: s.signedUrl, name: p.split('/').pop() || 'billet' });
    }
    return ok(res, { files, expiresInSeconds: SIGNED_URL_TTL });
  } catch (e: any) {
    logger.error(`[travel/get-ticket] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── 6. POST /bookings/:id/confirm-delivery — le CLIENT confirme → libération escrow ──
router.post(`/bookings/:id${UUID}/confirm-delivery`, verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const bookingId = req.params.id;
    const { data: booking } = await supabaseAdmin.from('travel_bookings')
      .select('id, user_id, escrow_id, status').eq('id', bookingId).maybeSingle();
    if (!booking) return fail(res, 404, 'Réservation introuvable');
    if ((booking as any).user_id !== userId) return fail(res, 403, 'Non autorisé', 'FORBIDDEN');
    if (!(booking as any).escrow_id) return fail(res, 409, 'Aucun paiement en séquestre.', 'NO_ESCROW');
    if ((booking as any).status === 'completed') return ok(res, { already_released: true });

    // p_customer_id = payer_id de l'escrow = l'auth uid du voyageur (contrôle dans la RPC).
    const { data, error } = await supabaseAdmin.rpc('confirm_delivery_and_release_escrow', {
      p_escrow_id: (booking as any).escrow_id, p_customer_id: userId, p_notes: 'Réception confirmée par le voyageur',
    });
    if (error) { logger.warn(`[travel/confirm-delivery] ${error.message}`); return fail(res, 400, 'La libération a échoué.', 'RELEASE_FAILED'); }

    await supabaseAdmin.from('travel_bookings')
      .update({ status: 'completed', delivery_confirmed_at: new Date().toISOString(), updated_at: new Date().toISOString() })
      .eq('id', bookingId);
    return ok(res, { released: true, result: data });
  } catch (e: any) {
    logger.error(`[travel/confirm-delivery] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── 6bis. POST /bookings/:id/cancel — le CLIENT annule (recours si l'agence ne livre pas) ──
// pending/price_confirmed → simple annulation. paid (billet PAS encore livré) → remboursement
// escrow atomique (refund_order_escrow). Après ticket_delivered/completed → non annulable ici.
router.post(`/bookings/:id${UUID}/cancel`, verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const bookingId = req.params.id;
    const { data: booking } = await supabaseAdmin.from('travel_bookings')
      .select('id, user_id, status, order_id, escrow_id').eq('id', bookingId).maybeSingle();
    if (!booking) return fail(res, 404, 'Réservation introuvable');
    if ((booking as any).user_id !== userId) return fail(res, 403, 'Non autorisé', 'FORBIDDEN');
    const status = (booking as any).status;

    if (status === 'pending' || status === 'price_confirmed') {
      await supabaseAdmin.from('travel_bookings').update({ status: 'cancelled', updated_at: new Date().toISOString() }).eq('id', bookingId);
      return ok(res, { cancelled: true });
    }
    if (status === 'paid') {
      // Billet PAS encore livré → remboursement du voyageur via la primitive sûre.
      const { error } = await supabaseAdmin.rpc('refund_order_escrow', { p_order_id: (booking as any).order_id });
      if (error) { logger.warn(`[travel/cancel] ${error.message}`); return fail(res, 400, 'Le remboursement a échoué.', 'REFUND_FAILED'); }
      await supabaseAdmin.from('travel_bookings').update({ status: 'refunded', payment_status: 'refunded', updated_at: new Date().toISOString() }).eq('id', bookingId);
      return ok(res, { refunded: true });
    }
    return fail(res, 409, 'Cette réservation ne peut plus être annulée (billet déjà déposé). Contactez le support en cas de litige.', 'NOT_CANCELLABLE');
  } catch (e: any) {
    logger.error(`[travel/cancel] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── 7. GET /bookings/mine — les réservations du client ──
router.get('/bookings/mine', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data } = await supabaseAdmin.from('travel_bookings')
      .select('*').eq('user_id', req.user!.id).order('created_at', { ascending: false }).limit(100);
    return ok(res, { bookings: (data as any[]) || [] });
  } catch (e: any) {
    logger.error(`[travel/mine] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

// ── 8. GET /bookings/agency?service_id= — les réservations reçues par une agence ──
router.get('/bookings/agency', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const serviceId = String(req.query?.service_id || '');
    if (!serviceId) return fail(res, 400, 'service_id requis', 'BAD_PARAMS');
    const owner = await getAgencyOwner(serviceId);
    if (!owner || owner !== userId) return fail(res, 403, "Réservé à l'agence propriétaire", 'FORBIDDEN');
    const { data } = await supabaseAdmin.from('travel_bookings')
      .select('*').eq('agency_service_id', serviceId).order('created_at', { ascending: false }).limit(200);
    return ok(res, { bookings: (data as any[]) || [] });
  } catch (e: any) {
    logger.error(`[travel/agency] ${e?.message}`);
    return fail(res, 500, 'Erreur serveur');
  }
});

export default router;
