/**
 * 💳 WALLET PAY — bouton « Payer » universel.
 * Canal QR wallet 224 : le client scanne le QR du vendeur → PIN → transfert atomique
 * (RPC pay_vendor_via_wallet qui APPELLE le transfert canonique). Le vendeur reçoit son prix plein.
 * Canaux OM/MoMo : délégués au flux payment_links existant (aucune logique de règlement ici).
 * PIN réutilisé via walletPin.service (aucun second mécanisme). Notif vendeur via notification.service.
 */
import { Router, Response } from 'express';
import crypto from 'crypto';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { paymentRateLimit, authRateLimit } from '../middlewares/routeRateLimiter.js';
import { verifyWalletPin, isPinSchemaAvailableForMoney } from '../services/walletPin.service.js';
import { createNotification } from '../services/notification.service.js';

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
  if (m.includes('WALLET_INTROUVABLE') || m.includes('VENDEUR_INTROUVABLE')) return { code: 404, error: 'Compte introuvable.' };
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
      .insert({ vendor_id: vendor.id, kind: 'static', reference }).select('reference, kind, amount').single();
    if (error) { res.status(500).json({ success: false, error: 'QR indisponible' }); return; }
    res.json({ success: true, data }); return;
  }

  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }
  const reference = crypto.randomBytes(24).toString('base64url');
  const { data, error } = await supabaseAdmin.from('vendor_payment_qr')
    .insert({ vendor_id: vendor.id, kind: 'dynamic', amount, reference, expires_at: new Date(Date.now() + 15 * 60 * 1000).toISOString() })
    .select('reference, kind, amount, expires_at').single();
  if (error) { res.status(500).json({ success: false, error: 'QR indisponible' }); return; }
  res.json({ success: true, data });
});

// ── Client : résoudre un QR scanné → écran de confirmation ──
router.get('/resolve', verifyJWT, authRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const ref = String(req.query?.ref || '');
  if (!ref) { res.status(400).json({ success: false, error: 'Référence manquante' }); return; }
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

// ── Client : payer (PIN wallet requis) ──
router.post('/pay', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const clientId = req.user!.id;
  const ref = String(req.body?.reference || '');
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
router.post('/om-momo', verifyJWT, paymentRateLimit, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const ref = String(req.body?.reference || '');
  const method = req.body?.payment_method === 'mtn_momo' ? 'mtn_momo' : 'orange_money';
  const { data: qr } = await supabaseAdmin.from('vendor_payment_qr').select('vendor_id, amount').eq('reference', ref).maybeSingle();
  if (!qr) { res.status(404).json({ success: false, error: 'QR invalide' }); return; }
  const amount = Number(qr && (qr as any).amount) || Number(req.body?.amount);
  if (!posInt(amount)) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }
  const { data: vendor } = await supabaseAdmin.from('vendors').select('id, business_name').eq('id', (qr as any).vendor_id).maybeSingle();
  // Le règlement OM/MoMo réutilise payment_links (pending_settlement). On renvoie le contexte au
  // front qui ouvre le flux payment_links existant (aucune logique de règlement dupliquée ici).
  res.json({ success: true, data: {
    delegate: 'payment_links', payment_method: method, amount,
    vendor_id: (vendor as any)?.id, vendor_name: (vendor as any)?.business_name || 'Vendeur',
  } });
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
