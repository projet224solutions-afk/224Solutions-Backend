/**
 * 💳 WALLET PAY — bouton « Payer » universel.
 * Canal QR wallet 224 : le client scanne le QR du vendeur → PIN → transfert atomique
 * (RPC pay_vendor_via_wallet qui APPELLE le transfert canonique). Le vendeur reçoit son prix plein.
 * Canaux OM/MoMo : délégués au flux payment_links existant (aucune logique de règlement ici).
 * PIN réutilisé via walletPin.service (aucun second mécanisme). Notif vendeur via notification.service.
 */
import { Router, Request, Response } from 'express';
import crypto from 'crypto';
import Stripe from 'stripe';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { paymentRateLimit, authRateLimit } from '../middlewares/routeRateLimiter.js';
import { verifyWalletPin, isPinSchemaAvailableForMoney } from '../services/walletPin.service.js';
import { createNotification } from '../services/notification.service.js';
import { normalizeQrRef } from '../utils/qrPayment.js';
import { initiatePayin, djomyConfigured, type DjomyOperator } from '../services/djomy.service.js';

const router = Router();
const newKey = () => crypto.randomUUID();
const posInt = (v: any) => Number.isFinite(Number(v)) && Number(v) > 0 && Number.isInteger(Number(v));

async function vendorForUser(userId: string) {
  const { data } = await supabaseAdmin.from('vendors').select('id, user_id, business_name').eq('user_id', userId).maybeSingle();
  return data as any;
}

function mapErr(msg: string): { code: number; error: string } {
  const m = (msg || '').toUpperCase();
  if (m.includes('QR_INVALIDE')) return { code: 400, error: 'QR invalide ou déjà utilisé.' };
  if (m.includes('QR_EXPIRE')) return { code: 409, error: 'QR expiré — demandez au vendeur d\'en régénérer un.' };
  if (m.includes('SOLDE_INSUFFISANT')) return { code: 409, error: 'Solde insuffisant.' };
  if (m.includes('MONTANT_INVALIDE')) return { code: 400, error: 'Montant invalide.' };
  if (m.includes('WALLET_INTROUVABLE') || m.includes('VENDEUR_INTROUVABLE') || m.includes('BENEFICIAIRE_INTROUVABLE')) return { code: 404, error: 'Compte introuvable.' };
  if (m.includes('FX_INDISPONIBLE')) return { code: 409, error: 'Conversion de devise momentanément indisponible — réessayez plus tard.' };
  return { code: 400, error: msg || 'Paiement refusé.' };
}

// ── Vendeur : créer/obtenir son QR de paiement ──
router.post('/vendor-qr', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const vendor = await vendorForUser(req.user!.id);
  if (!vendor) { res.status(403).json({ success: false, error: 'Compte vendeur introuvable' }); return; }
  const kind = req.body?.kind === 'dynamic' ? 'dynamic' : 'static';
  const amount = Number(req.body?.amount);

  if (kind === 'static') {
    const { data: existing } = await supabaseAdmin.from('vendor_payment_qr')
      .select('reference, kind, amount').eq('vendor_id', vendor.id).eq('kind', 'static').eq('status', 'active').maybeSingle();
    if (existing) { res.json({ success: true, data: existing }); return; }
    const reference = crypto.randomBytes(24).toString('base64url');
    const { data, error } = await supabaseAdmin.from('vendor_payment_qr')
      .insert({ vendor_id: vendor.id, owner_user_id: vendor.user_id, kind: 'static', reference }).select('reference, kind, amount').single();
    if (error) { res.status(500).json({ success: false, error: 'QR indisponible' }); return; }
    res.json({ success: true, data }); return;
  }

  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }
  const reference = crypto.randomBytes(24).toString('base64url');
  const { data, error } = await supabaseAdmin.from('vendor_payment_qr')
    .insert({ vendor_id: vendor.id, owner_user_id: vendor.user_id, kind: 'dynamic', amount, reference, expires_at: new Date(Date.now() + 15 * 60 * 1000).toISOString() })
    .select('reference, kind, amount, expires_at').single();
  if (error) { res.status(500).json({ success: false, error: 'QR indisponible' }); return; }
  res.json({ success: true, data });
});

// ── Client : résoudre un QR scanné → écran de confirmation ──
router.get('/resolve', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  // CHANTIER 0 : normaliser (URL canonique /p/<ref> OU référence brute). Non-paiement → message clair.
  const raw = String(req.query?.ref || '');
  if (!raw) { res.status(400).json({ success: false, error: 'Référence manquante' }); return; }
  const ref = normalizeQrRef(raw);
  if (!ref) { res.status(422).json({ success: false, error: "Ce QR n'est pas un QR de paiement" }); return; }
  const { data: qr } = await supabaseAdmin.from('vendor_payment_qr').select('vendor_id, kind, amount, status, expires_at').eq('reference', ref).maybeSingle();
  if (!qr || (qr as any).status !== 'active') { res.status(404).json({ success: false, error: 'QR invalide' }); return; }
  if ((qr as any).expires_at && new Date((qr as any).expires_at).getTime() < Date.now()) { res.status(409).json({ success: false, error: 'QR expiré' }); return; }
  const { data: vendor } = await supabaseAdmin.from('vendors').select('business_name').eq('id', (qr as any).vendor_id).maybeSingle();
  const { data: cfg } = await supabaseAdmin.rpc('wallet_pay_active_config');
  res.json({ success: true, data: {
    vendor_name: (vendor as any)?.business_name || 'Vendeur',
    kind: (qr as any).kind, amount: (qr as any).amount,
    client_fee_percent: (cfg as any)?.qr_wallet_client_fee_percent ?? 0,
  } });
});

// ── Préview de split plafond AML pour tout initiateur (envoi P2P, dépôt agent) ──
// Renvoie UNIQUEMENT la répartition du montant (disponible / en attente) — JAMAIS le solde ni le
// plafond exact du destinataire (vie privée). Un seul helper serveur : wallet_cap_preview.
router.post('/cap-preview', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const amount = Number(req.body?.amount);
  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }
  // Destinataire : par user_id direct OU par identifiant (téléphone / public_id / custom_id).
  let ownerId: string | null = req.body?.recipient_user_id ? String(req.body.recipient_user_id) : null;
  const ident = req.body?.identifier ? String(req.body.identifier).trim() : null;
  if (!ownerId && ident) {
    const { data: prof } = await supabaseAdmin.from('profiles').select('id')
      .or(`phone.eq.${ident},public_id.eq.${ident},custom_id.eq.${ident}`).maybeSingle();
    ownerId = (prof as { id?: string } | null)?.id ?? null;
  }
  if (!ownerId) { res.json({ success: true, data: { will_quarantine: false, available: amount, quarantined: 0 } }); return; }

  const { data: w } = await supabaseAdmin.from('wallets').select('balance, currency')
    .eq('user_id', ownerId).order('created_at', { ascending: true }).limit(1).maybeSingle();
  const wal = (w ?? {}) as { balance?: number; currency?: string };
  const cur = wal.currency || 'GNF';
  // Montant crédité au destinataire dans SA devise (conversion si l'initiateur envoie une autre devise).
  let credit = amount;
  const fromCur = req.body?.from_currency ? String(req.body.from_currency).toUpperCase() : cur;
  if (fromCur !== cur) {
    const { data: conv } = await supabaseAdmin.rpc('wallet_fx_resolve', { p_from_currency: fromCur, p_to_currency: cur, p_amount: amount }).then(
      (r: { data: unknown }) => ({ data: Array.isArray(r.data) ? (r.data as Array<{ converted_amount?: number }>)[0] : r.data as { converted_amount?: number } }), () => ({ data: null }));
    if ((conv as { converted_amount?: number } | null)?.converted_amount) credit = Number((conv as { converted_amount: number }).converted_amount);
  }
  const { data, error } = await supabaseAdmin.rpc('wallet_cap_preview', {
    p_user_id: ownerId, p_current_balance: wal.balance ?? 0, p_credit: credit, p_currency: cur,
  });
  if (error) { res.json({ success: true, data: { will_quarantine: false, available: credit, quarantined: 0, currency: cur } }); return; }
  const row = (Array.isArray(data) ? data[0] : data) as { available?: number; quarantined?: number } | null;
  const q = Number(row?.quarantined ?? 0);
  // On ne renvoie QUE le split + la devise du destinataire — ni solde, ni plafond.
  res.json({ success: true, data: {
    available: Number(row?.available ?? credit), quarantined: q, will_quarantine: q > 0, currency: cur,
  } });
});

// ── Client : DEVIS avant PIN (BLOC 5) — montant payeur + équivalent bénéficiaire + frais + total ──
// Le payeur voit les DEUX montants (sa devise ≈ celle du vendeur), les frais, le total débité, et
// si son solde suffit — AVANT de saisir le PIN. Taux malsain → FX_INDISPONIBLE (refus propre).
router.get('/quote', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const ref = normalizeQrRef(String(req.query?.ref || ''));
  if (!ref) { res.status(422).json({ success: false, error: "Ce QR n'est pas un QR de paiement" }); return; }
  const amount = req.query?.amount != null ? Number(req.query.amount) : null;
  if (amount != null && !posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }
  const { data, error } = await supabaseAdmin.rpc('wallet_pay_quote', {
    p_client_user_id: req.user!.id, p_qr_reference: ref, p_amount: amount,
  });
  if (error) { const e = mapErr(error.message); res.status(e.code).json({ success: false, error: e.error }); return; }
  res.json({ success: true, data });
});

// ── Client : payer (PIN wallet requis) ──
router.post('/pay', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const clientId = req.user!.id;
  const ref = normalizeQrRef(String(req.body?.reference || ''));   // CHANTIER 0 : URL ou référence brute
  const amount = req.body?.amount != null ? Number(req.body.amount) : undefined;
  const pin = String(req.body?.pin || '');
  if (!ref) { res.status(400).json({ success: false, error: 'QR manquant' }); return; }
  if (amount != null && !posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }

  // 🔒 Fail-closed argent : schéma PIN absent → refus (jamais de laissez-passer).
  if (!(await isPinSchemaAvailableForMoney())) {
    res.status(503).json({ success: false, error: 'Sécurité PIN indisponible — paiement refusé par prudence.', error_code: 'PIN_SCHEMA_UNAVAILABLE' });
    return;
  }
  // PIN via le service EXISTANT (verrous + tentatives gérés là-bas).
  const pinRes = await verifyWalletPin(clientId, pin);
  if (!pinRes.valid) { res.status(401).json({ success: false, error: pinRes.error || 'Code PIN invalide', locked_until: pinRes.lockedUntil }); return; }

  const { data, error } = await supabaseAdmin.rpc('pay_vendor_via_wallet', {
    p_client_user_id: clientId, p_qr_reference: ref, p_amount: amount ?? null, p_idempotency_key: req.body?.idempotency_key || newKey(),
  });
  if (error) { const e = mapErr(error.message); logger.warn(`[wallet-pay] ${error.message}`); res.status(e.code).json({ success: false, error: e.error }); return; }

  // « Le ding » : notifier le vendeur en direct.
  try {
    const { data: qr } = await supabaseAdmin.from('vendor_payment_qr').select('vendor_id').eq('reference', ref).maybeSingle();
    const { data: vendor } = await supabaseAdmin.from('vendors').select('user_id').eq('id', (qr as any)?.vendor_id).maybeSingle();
    if ((vendor as any)?.user_id) {
      await createNotification({ userId: (vendor as any).user_id, title: 'Paiement reçu',
        message: `Paiement de ${Number((data as any).amount).toLocaleString('fr-FR')} GNF reçu.`, type: 'payment_received',
        metadata: { amount: (data as any).amount, source: 'wallet_pay', transaction_id: (data as any).transaction_id } });
    }
  } catch (e: any) { logger.warn(`[wallet-pay] notif vendeur: ${e?.message}`); }

  res.json({ success: true, data });
});

// ── Client : payer via Orange Money / MTN MoMo → délégué au flux payment_links existant ──
// (Ancienne route JWT `/om-momo` supprimée : OM/MoMo passe désormais par la route PUBLIQUE
//  `/public/qr/:token/pay` avec method∈{orange_money,mtn_momo} → Djomy. Un seul chemin OM/MoMo,
//  sans compte, avec règlement atomique au webhook — plus de délégation payment_links.)

// ════════════════════════════════════════════════════════════════════════════
// CHANTIER C — PAIEMENT PUBLIC SANS COMPTE (carte). OM/MoMo : à venir (provider externe requis).
// Le payeur anonyme paie dans la DEVISE DU VENDEUR (aucune conversion côté anonyme). Le crédit
// vendeur passe par le settlement ATOMIQUE canonique (settle_qr_card_payment → credit_user_wallet_safe).
// ════════════════════════════════════════════════════════════════════════════

// Résout un QR public → bénéficiaire + devise (helper partagé GET/POST).
async function resolvePublicQr(ref: string): Promise<{ q: any; owner: string; name: string; logo: string | null; city: string | null; currency: string } | null> {
  const { data: qr } = await supabaseAdmin.from('vendor_payment_qr')
    .select('vendor_id, owner_user_id, kind, amount, status, expires_at').eq('reference', ref).maybeSingle();
  if (!qr || (qr as any).status !== 'active') return null;
  const q = qr as any;
  if (q.expires_at && new Date(q.expires_at).getTime() < Date.now()) return null;
  const owner = q.owner_user_id || (await supabaseAdmin.from('vendors').select('user_id').eq('id', q.vendor_id).maybeSingle()).data?.user_id;
  if (!owner) return null;
  let name: string | null = null; let logo: string | null = null; let city: string | null = null;
  const { data: v } = await supabaseAdmin.from('vendors').select('business_name, logo_url, city').eq('id', q.vendor_id).maybeSingle();
  if (v) { name = (v as any).business_name || null; logo = (v as any).logo_url || null; city = (v as any).city || null; }
  if (!name) {
    const { data: ps } = await supabaseAdmin.from('professional_services').select('business_name').eq('user_id', owner).order('created_at', { ascending: true }).limit(1).maybeSingle();
    name = (ps as any)?.business_name || null;
  }
  const { data: w } = await supabaseAdmin.from('wallets').select('currency').eq('user_id', owner).order('created_at', { ascending: true }).limit(1).maybeSingle();
  return { q, owner, name: name || 'Boutique', logo, city, currency: (w as any)?.currency || 'GNF' };
}

// GET /api/v2/wallet-pay/public/qr/:token — contexte PUBLIC (nom/ville/logo/devise/frais). Aucun compte.
router.get('/public/qr/:token', paymentRateLimit, async (req: Request, res: Response): Promise<void> => {
  const ref = normalizeQrRef(String(req.params.token || ''));
  if (!ref) { res.status(404).json({ success: false, error: 'QR introuvable' }); return; }
  const r = await resolvePublicQr(ref);
  if (!r) { res.status(404).json({ success: false, error: 'QR introuvable, inactif ou expiré' }); return; }
  const { data: cfg } = await supabaseAdmin.from('wallet_pay_config').select('qr_wallet_client_fee_percent').eq('is_active', true).maybeSingle();
  res.json({ success: true, data: {
    name: r.name, city: r.city, logo: r.logo, currency: r.currency,
    kind: r.q.kind, amount: r.q.amount ?? null,
    fee_percent: Number((cfg as { qr_wallet_client_fee_percent?: number } | null)?.qr_wallet_client_fee_percent ?? 0),
    card_available: !!process.env.STRIPE_SECRET_KEY,
    momo_available: djomyConfigured(),   // Orange Money / MTN MoMo via Djomy (sans compte)
  } });
});

// POST /api/v2/wallet-pay/public/qr/:token/pay — CARTE sans compte (étape 1 create → étape 2 confirm+settle).
router.post('/public/qr/:token/pay', paymentRateLimit, async (req: Request, res: Response): Promise<void> => {
  const ref = normalizeQrRef(String(req.params.token || ''));
  if (!ref) { res.status(404).json({ success: false, error: 'QR introuvable' }); return; }
  const method = String(req.body?.method || 'card');
  const r = await resolvePublicQr(ref);
  if (!r) { res.status(404).json({ success: false, error: 'QR invalide, inactif ou expiré' }); return; }

  // ── Rail OM/MoMo (Djomy) — sans compte : initie un PAYIN (push USSD), NE CRÉDITE RIEN.
  //    Le crédit vendeur se fait UNIQUEMENT au webhook Djomy vérifié (settle_qr_payment). ──
  if (method === 'orange_money' || method === 'mtn_momo') {
    if (!djomyConfigured()) { res.status(503).json({ success: false, error: 'Mobile money momentanément indisponible.', error_code: 'DJOMY_NOT_CONFIGURED' }); return; }
    const amount = r.q.kind === 'dynamic' ? Number(r.q.amount) : Number(req.body?.amount);
    if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }
    const phone = String(req.body?.payer_phone || req.body?.phone || '').trim();
    if (!phone) { res.status(400).json({ success: false, error: 'Numéro payeur requis', error_code: 'PHONE_REQUIRED' }); return; }
    const merchantRef = `qr_${ref}_${Date.now()}`;
    const payin = await initiatePayin({
      amount, currency: r.currency, msisdn: phone, operator: method as DjomyOperator,
      reference: merchantRef, description: `Paiement ${r.name}`,
    });
    if (!payin.success || !payin.transactionId) {
      res.status(502).json({ success: false, error: payin.error || "Échec de l'initiation du paiement mobile money", error_code: 'DJOMY_INIT_FAILED' }); return;
    }
    // Ligne de SUIVI (aucun crédit) : provider_ref = transactionId Djomy, qr_reference en metadata.
    await supabaseAdmin.from('payment_transactions').insert({
      provider: 'djomy', provider_ref: payin.transactionId, user_id: r.owner,
      amount, currency: r.currency, status: 'pending',
      description: `QR ${method} — ${r.name}`,
      metadata: { qr_reference: ref, operator: method, merchant_ref: merchantRef },
    });
    res.json({ success: true, data: { reference: payin.transactionId, status: 'pending', amount, currency: r.currency, vendor_name: r.name, method } });
    return;
  }

  // ── Rail CARTE (Stripe) — INCHANGÉ ──
  const stripeKey = process.env.STRIPE_SECRET_KEY?.trim();
  if (!stripeKey) { res.status(503).json({ success: false, error: 'Paiement carte momentanément indisponible.', error_code: 'STRIPE_NOT_CONFIGURED' }); return; }

  const stripe = new Stripe(stripeKey, { apiVersion: '2023-10-16' as any });
  const paymentIntentId = req.body?.paymentIntentId ? String(req.body.paymentIntentId) : null;

  // ÉTAPE 2 — confirmation : Stripe a encaissé → crédit vendeur atomique (idempotent sur l'id Stripe).
  if (paymentIntentId) {
    const pi = await stripe.paymentIntents.retrieve(paymentIntentId);
    if (pi.metadata?.qr_reference !== ref) { res.status(400).json({ success: false, error: 'Paiement non lié à ce QR' }); return; }
    if (pi.status !== 'succeeded') { res.status(409).json({ success: false, error: 'Paiement non confirmé' }); return; }
    const amount = Number(pi.amount);
    const { data, error } = await supabaseAdmin.rpc('settle_qr_card_payment', {
      p_qr_reference: ref, p_amount: amount, p_currency: r.currency, p_provider_ref: pi.id,
    });
    if (error) { const e = mapErr(error.message); logger.warn(`[wallet-pay/public] settle ${error.message}`); res.status(e.code).json({ success: false, error: e.error }); return; }
    if (r.q.kind === 'dynamic') await supabaseAdmin.from('vendor_payment_qr').update({ status: 'used' }).eq('reference', ref);
    res.json({ success: true, data: { settled: true, amount, currency: r.currency, vendor_name: r.name, ...(data as object) } });
    return;
  }

  // ÉTAPE 1 — création du PaymentIntent (montant en DEVISE VENDEUR ; le QR encode le token seul).
  const amount = r.q.kind === 'dynamic' ? Number(r.q.amount) : Number(req.body?.amount);
  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }
  const pi = await stripe.paymentIntents.create({
    amount: Math.round(amount),
    currency: r.currency.toLowerCase(),
    automatic_payment_methods: { enabled: true },
    metadata: { qr_reference: ref, currency: r.currency, kind: r.q.kind },
  });
  res.json({ success: true, data: { clientSecret: pi.client_secret, paymentIntentId: pi.id, amount, currency: r.currency, vendor_name: r.name } });
});

// GET /public/qr/:token/status?ref=<djomyTxId> — poll PUBLIC (OM/MoMo). N'expose QUE le statut
// simplifié (pending|paid|failed), jamais le montant/bénéficiaire/données du payeur.
router.get('/public/qr/:token/status', paymentRateLimit, async (req: Request, res: Response): Promise<void> => {
  const providerRef = String(req.query?.ref || '').trim();
  if (!providerRef) { res.status(400).json({ success: false, error: 'ref requise' }); return; }
  const { data: pt } = await supabaseAdmin.from('payment_transactions')
    .select('status').eq('provider', 'djomy').eq('provider_ref', providerRef).maybeSingle();
  const map: Record<string, string> = { completed: 'paid', pending: 'pending', failed: 'failed' };
  const status = pt ? (map[String((pt as any).status)] || 'pending') : 'pending';
  res.json({ success: true, data: { status } });
});

// ── Config frais QR wallet (GET agents/PDG, PUT PDG) ──
async function isPdg(userId: string): Promise<boolean> {
  const { data } = await supabaseAdmin.from('pdg_management').select('id').eq('user_id', userId).eq('is_active', true).maybeSingle();
  if (data) return true;
  const { data: prof } = await supabaseAdmin.from('profiles').select('role').eq('id', userId).maybeSingle();
  return ['pdg', 'admin', 'ceo'].includes(((prof as any)?.role || '').toLowerCase());
}

router.get('/config', verifyJWT, async (_req: AuthenticatedRequest, res: Response): Promise<void> => {
  const { data, error } = await supabaseAdmin.rpc('wallet_pay_active_config');
  if (error) { res.status(500).json({ success: false, error: 'Config indisponible' }); return; }
  res.json({ success: true, data });
});

router.put('/config', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  if (!(await isPdg(req.user!.id))) { res.status(403).json({ success: false, error: 'PDG uniquement' }); return; }
  const { data, error } = await supabaseAdmin.rpc('wallet_pay_config_update', { p_changes: req.body || {} });
  if (error) { res.status(400).json({ success: false, error: error.message }); return; }
  res.json({ success: true, data });
});

export default router;
