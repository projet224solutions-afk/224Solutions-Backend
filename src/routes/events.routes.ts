/**
 * 🎟️ BILLETTERIE ÉVÉNEMENTS — routes backend (marque blanche).
 * - POST /organizer        : le PRESTATAIRE crée le compte organisateur (auth admin) + rattachement + wallet temporaire.
 * - POST /tickets/buy      : achat par WALLET (RPC buy_event_ticket, atomique/idempotent) + email billet (best-effort).
 * - POST /tickets/pay-init : achat OM/MoMo (Djomy payin) — AUCUN billet avant le webhook confirmé (fail-closed).
 * - POST /tickets/pay-card : achat CARTE (Stripe 2 temps : init → confirm succeeded → billet).
 * - GET  /tickets/pay-status : poll du statut d'un paiement mobile money (le billet arrive via webhook).
 * INVARIANT : le billet n'est JAMAIS délivré sans paiement confirmé (wallet débité ou provider confirmé).
 */
import { Router, Response } from 'express';
import Stripe from 'stripe';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { ok, fail } from '../utils/apiResponse.js';
import { verifyJWT, AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { initiatePayin, djomyConfigured, type DjomyOperator } from '../services/djomy.service.js';
import { sendEmail, wrapEmailHtml } from '../services/transactionEmail.service.js';

const router = Router();
const FRONT_URL = (process.env.FRONTEND_URL || 'https://224solution.net').replace(/\/$/, '');

/** Email billet (best-effort) : infos + lien PRIVÉ /billet/:token (QR + PDF re-téléchargeables dans l'app). */
async function sendTicketEmail(buyerId: string, eventTitle: string, typeName: string, qr: string): Promise<void> {
  try {
    const { data: p } = await supabaseAdmin.from('profiles').select('email, first_name').eq('id', buyerId).maybeSingle();
    const email = (p as any)?.email;
    if (!email) return;
    const link = `${FRONT_URL}/billet/${qr}`;
    const html = wrapEmailHtml(`
      <h2>🎫 Votre billet est prêt</h2>
      <p>Bonjour${(p as any)?.first_name ? ' ' + (p as any).first_name : ''},</p>
      <p>Votre billet <b>${typeName}</b> pour <b>${eventTitle}</b> est confirmé.</p>
      <p style="margin:24px 0"><a href="${link}" style="background:#ff4000;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none">Voir mon billet (QR + PDF)</a></p>
      <p>Présentez le QR code à l'entrée. Ce lien est personnel — ne le partagez pas.</p>
    `, 'Votre billet — 224Solutions');
    await sendEmail(email, `🎫 Votre billet — ${eventTitle}`, html);
  } catch (e: any) {
    logger.warn(`[events] email billet non envoyé: ${e?.message}`);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// POST /organizer — le prestataire crée le compte organisateur de SON événement.
// ═══════════════════════════════════════════════════════════════════════════
router.post('/organizer', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const actor = req.user!.id;
  const { event_id, full_name, email, phone, password } = req.body || {};
  if (!event_id || !email || !password) { fail(res, 400, 'event_id, email et mot de passe requis', 'MISSING_FIELDS'); return; }
  if (String(password).length < 8) { fail(res, 400, 'Mot de passe trop court (8 caractères minimum)', 'WEAK_PASSWORD'); return; }

  // Ownership : seul le PRESTATAIRE créateur de l'événement crée son organisateur.
  const { data: ev } = await supabaseAdmin.from('events')
    .select('id, title, provider_user_id, organizer_user_id, status').eq('id', event_id).maybeSingle();
  if (!ev) { fail(res, 404, 'Événement introuvable', 'EVENT_NOT_FOUND'); return; }
  if ((ev as any).provider_user_id !== actor) { fail(res, 403, 'Vous n\'êtes pas le prestataire de cet événement', 'NOT_PROVIDER'); return; }
  if (['archived', 'cancelled'].includes((ev as any).status)) { fail(res, 409, 'Événement clôturé', 'EVENT_CLOSED'); return; }
  if ((ev as any).organizer_user_id) { fail(res, 409, 'Un organisateur est déjà rattaché à cet événement', 'ORGANIZER_EXISTS'); return; }

  // Compte auth (email confirmé d'office : identifiants remis en main propre par le prestataire).
  const { data: created, error: createErr } = await supabaseAdmin.auth.admin.createUser({
    email: String(email).trim().toLowerCase(),
    password: String(password),
    email_confirm: true,
    ...(phone ? { phone: String(phone).trim() } : {}),
    user_metadata: { full_name: full_name || null, event_organizer: true, event_id },
  });
  if (createErr || !created?.user) {
    const msg = createErr?.message || 'Création du compte impossible';
    fail(res, /already/i.test(msg) ? 409 : 500, msg, 'CREATE_USER_FAILED'); return;
  }
  const organizerId = created.user.id;

  // Rattachement + portefeuille temporaire (retrait-only) — service_role.
  const { error: linkErr } = await supabaseAdmin.from('events')
    .update({ organizer_user_id: organizerId }).eq('id', event_id);
  if (linkErr) { fail(res, 500, linkErr.message, 'LINK_FAILED'); return; }
  await supabaseAdmin.from('organizer_wallets')
    .upsert({ organizer_user_id: organizerId, event_id }, { onConflict: 'event_id' });

  logger.info(`[events] organisateur ${organizerId} créé pour ${event_id} par ${actor}`);
  ok(res, { organizer_user_id: organizerId, email: created.user.email });
});

// ═══════════════════════════════════════════════════════════════════════════
// POST /tickets/buy — rail WALLET (immédiat). Le RPC débite + crédite + assigne, atomique.
// ═══════════════════════════════════════════════════════════════════════════
router.post('/tickets/buy', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const buyer = req.user!.id;
  const { ticket_type_id, idempotency_key } = req.body || {};
  if (!ticket_type_id || !idempotency_key) { fail(res, 400, 'ticket_type_id et idempotency_key requis', 'MISSING_FIELDS'); return; }

  const { data, error } = await supabaseAdmin.rpc('buy_event_ticket', {
    p_ticket_type_id: ticket_type_id, p_idempotency: String(idempotency_key), p_buyer: buyer,
  });
  if (error) {
    const msg = error.message || 'Achat impossible';
    fail(res, /INSUFFICIENT/i.test(msg) ? 402 : 400, msg, 'BUY_FAILED'); return;
  }
  const r = data as any;
  if (!r?.success) {
    const map: Record<string, [number, string]> = {
      SOLD_OUT: [409, 'Plus de billets disponibles'], EVENT_NOT_ACTIVE: [409, 'Événement non actif'],
      TICKET_TYPE_NOT_FOUND: [404, 'Type de billet introuvable'], NO_ORGANIZER: [409, 'Événement sans organisateur'],
    };
    const [code, msg] = map[r?.error] || [400, r?.error || 'Achat impossible'];
    fail(res, code, msg, r?.error); return;
  }

  // Email billet (best-effort, jamais bloquant).
  if (!r.already) {
    const { data: tt } = await supabaseAdmin.from('event_ticket_types')
      .select('name, events(title)').eq('id', ticket_type_id).maybeSingle();
    void sendTicketEmail(buyer, (tt as any)?.events?.title || 'Événement', (tt as any)?.name || 'Billet', r.qr_code);
  }
  ok(res, r);
});

// ═══════════════════════════════════════════════════════════════════════════
// POST /tickets/pay-init — rail OM/MoMo (Djomy). Init payin ; le billet arrive au WEBHOOK confirmé.
// ═══════════════════════════════════════════════════════════════════════════
router.post('/tickets/pay-init', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const buyer = req.user!.id;
  const { ticket_type_id, method, payer_phone } = req.body || {};
  if (!ticket_type_id || !method) { fail(res, 400, 'ticket_type_id et method requis', 'MISSING_FIELDS'); return; }
  if (!['orange_money', 'mtn_momo'].includes(method)) { fail(res, 400, 'Méthode invalide', 'BAD_METHOD'); return; }
  if (!djomyConfigured()) { fail(res, 503, 'Mobile money momentanément indisponible.', 'DJOMY_NOT_CONFIGURED'); return; }
  const phone = String(payer_phone || '').trim();
  if (!phone) { fail(res, 400, 'Numéro payeur requis', 'PHONE_REQUIRED'); return; }

  // Prix lu CÔTÉ SERVEUR (jamais le montant client) + stock/état vérifiés à l'init (re-vérifiés au règlement).
  const { data: tt } = await supabaseAdmin.from('event_ticket_types')
    .select('id, name, price, currency, quantity_total, quantity_sold, events(id, title, status, organizer_user_id)')
    .eq('id', ticket_type_id).maybeSingle();
  if (!tt) { fail(res, 404, 'Type de billet introuvable', 'TICKET_TYPE_NOT_FOUND'); return; }
  const ev = (tt as any).events;
  if (ev?.status !== 'active') { fail(res, 409, 'Événement non actif', 'EVENT_NOT_ACTIVE'); return; }
  if ((tt as any).quantity_sold >= (tt as any).quantity_total) { fail(res, 409, 'Plus de billets disponibles', 'SOLD_OUT'); return; }

  const amount = Number((tt as any).price);
  const merchantRef = `evt_${ticket_type_id}_${Date.now()}`;
  const payin = await initiatePayin({
    amount, currency: (tt as any).currency || 'GNF', msisdn: phone, operator: method as DjomyOperator,
    reference: merchantRef, description: `Billet ${(tt as any).name} — ${ev.title}`,
  });
  if (!payin.success || !payin.transactionId) {
    fail(res, 502, payin.error || "Échec de l'initiation du paiement mobile money", 'DJOMY_INIT_FAILED'); return;
  }
  // Ligne de SUIVI (aucun billet) — le webhook Djomy vérifié délivrera via buy_event_ticket.
  await supabaseAdmin.from('payment_transactions').insert({
    provider: 'djomy', provider_ref: payin.transactionId, user_id: buyer,
    amount, currency: (tt as any).currency || 'GNF', status: 'pending',
    description: `Billet ${(tt as any).name} — ${ev.title}`,
    metadata: { purpose: 'event_ticket', ticket_type_id, buyer_user_id: buyer, operator: method, merchant_ref: merchantRef },
  });
  ok(res, { reference: payin.transactionId, status: 'pending', amount, currency: (tt as any).currency || 'GNF' });
});

// GET /tickets/pay-status?ref= — poll OM/MoMo : renvoie le billet une fois le webhook réglé.
router.get('/tickets/pay-status', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const ref = String(req.query.ref || '').trim();
  if (!ref) { fail(res, 400, 'ref requis', 'MISSING_REF'); return; }
  const { data: pt } = await supabaseAdmin.from('payment_transactions')
    .select('status, user_id').eq('provider', 'djomy').eq('provider_ref', ref).maybeSingle();
  if (!pt || (pt as any).user_id !== req.user!.id) { fail(res, 404, 'Paiement introuvable', 'NOT_FOUND'); return; }
  if ((pt as any).status === 'completed') {
    const { data: t } = await supabaseAdmin.from('event_tickets')
      .select('id, qr_code').eq('purchase_ref', 'agg-' + ref).maybeSingle();
    ok(res, { status: 'completed', ticket_id: (t as any)?.id, qr_code: (t as any)?.qr_code }); return;
  }
  ok(res, { status: (pt as any).status });
});

// ═══════════════════════════════════════════════════════════════════════════
// POST /tickets/pay-card — rail CARTE (Stripe, 2 temps). Billet UNIQUEMENT si pi.status='succeeded'.
// ═══════════════════════════════════════════════════════════════════════════
router.post('/tickets/pay-card', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const buyer = req.user!.id;
  const stripeKey = process.env.STRIPE_SECRET_KEY?.trim();
  if (!stripeKey) { fail(res, 503, 'Paiement carte momentanément indisponible.', 'STRIPE_NOT_CONFIGURED'); return; }
  const stripe = new Stripe(stripeKey, { apiVersion: '2023-10-16' as any });
  const { ticket_type_id, payment_intent_id } = req.body || {};

  // ÉTAPE 2 — confirmation : Stripe a encaissé → billet (idempotent sur l'id Stripe).
  if (payment_intent_id) {
    const pi = await stripe.paymentIntents.retrieve(String(payment_intent_id));
    if (pi.metadata?.purpose !== 'event_ticket' || pi.metadata?.buyer_user_id !== buyer) {
      fail(res, 400, 'Paiement non lié à cet achat', 'PI_MISMATCH'); return;
    }
    if (pi.status !== 'succeeded') { fail(res, 409, 'Paiement non confirmé', 'NOT_SUCCEEDED'); return; }
    const { data, error } = await supabaseAdmin.rpc('buy_event_ticket', {
      p_ticket_type_id: pi.metadata.ticket_type_id, p_idempotency: 'card-' + pi.id, p_buyer: buyer,
    });
    if (error || !(data as any)?.success) { fail(res, 400, error?.message || (data as any)?.error || 'Délivrance impossible', 'DELIVER_FAILED'); return; }
    const r = data as any;
    if (!r.already) {
      const { data: tt } = await supabaseAdmin.from('event_ticket_types')
        .select('name, events(title)').eq('id', pi.metadata.ticket_type_id).maybeSingle();
      void sendTicketEmail(buyer, (tt as any)?.events?.title || 'Événement', (tt as any)?.name || 'Billet', r.qr_code);
    }
    ok(res, r); return;
  }

  // ÉTAPE 1 — création du PaymentIntent (prix lu côté serveur).
  if (!ticket_type_id) { fail(res, 400, 'ticket_type_id requis', 'MISSING_FIELDS'); return; }
  const { data: tt } = await supabaseAdmin.from('event_ticket_types')
    .select('id, name, price, currency, quantity_total, quantity_sold, events(title, status)')
    .eq('id', ticket_type_id).maybeSingle();
  if (!tt) { fail(res, 404, 'Type de billet introuvable', 'TICKET_TYPE_NOT_FOUND'); return; }
  if ((tt as any).events?.status !== 'active') { fail(res, 409, 'Événement non actif', 'EVENT_NOT_ACTIVE'); return; }
  if ((tt as any).quantity_sold >= (tt as any).quantity_total) { fail(res, 409, 'Plus de billets disponibles', 'SOLD_OUT'); return; }
  const pi = await stripe.paymentIntents.create({
    amount: Number((tt as any).price), currency: String((tt as any).currency || 'GNF').toLowerCase(),
    automatic_payment_methods: { enabled: true },
    metadata: { purpose: 'event_ticket', ticket_type_id: String(ticket_type_id), buyer_user_id: buyer },
  });
  ok(res, { client_secret: pi.client_secret, payment_intent_id: pi.id, amount: Number((tt as any).price), currency: (tt as any).currency || 'GNF' });
});

export default router;
