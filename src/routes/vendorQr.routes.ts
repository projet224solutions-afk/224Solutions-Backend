/**
 * QR de paiement PERMANENT par vendeur (BLOC 1 du chantier QR).
 * Front-door vers le circuit payment_links existant : le token opaque résout le VENDEUR,
 * puis la page /p/<token> crée un paiement standard. Le vendeur est résolu par req.user.id.
 */
import { Router, Request, Response } from 'express';
import crypto from 'node:crypto';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { paymentRateLimit } from '../middlewares/routeRateLimiter.js';

const router = Router();

async function getVendorId(userId: string): Promise<string | null> {
  const { data } = await supabaseAdmin.from('vendors').select('id').eq('user_id', userId).maybeSingle();
  return (data as { id?: string } | null)?.id ?? null;
}

// Référence STATIQUE canonique du vendeur = celle du circuit wallet-pay (vendor_payment_qr).
// SOURCE UNIQUE du token de paiement — aucun second token propriétaire. Get-or-create.
async function getOrCreateStaticRef(vendorId: string): Promise<string | null> {
  const { data: existing } = await supabaseAdmin.from('vendor_payment_qr')
    .select('reference').eq('vendor_id', vendorId).eq('kind', 'static').eq('status', 'active').maybeSingle();
  if (existing) return (existing as { reference: string }).reference;
  const reference = crypto.randomBytes(24).toString('base64url');
  const { data, error } = await supabaseAdmin.from('vendor_payment_qr')
    .insert({ vendor_id: vendorId, kind: 'static', reference }).select('reference').single();
  if (error) { logger.error(`[vendor-qr] insert static failed: ${error.message}`); return null; }
  return (data as { reference: string }).reference;
}

// GET /api/v2/vendor-qr/me — token QR permanent du vendeur (= référence wallet-pay statique,
// créée au 1er appel, stable ensuite) + profil boutique pour l'affichage/PDF.
router.get('/me', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const vid = await getVendorId(req.user!.id);
  if (!vid) { res.status(403).json({ success: false, error: 'Compte vendeur introuvable' }); return; }
  const token = await getOrCreateStaticRef(vid);
  if (!token) { res.status(500).json({ success: false, error: 'QR indisponible' }); return; }
  const { data: v } = await supabaseAdmin.from('vendors')
    .select('business_name, city, logo_url, vendor_code').eq('id', vid).maybeSingle();
  const info = (v ?? {}) as { business_name?: string; city?: string; logo_url?: string; vendor_code?: string };
  res.json({ success: true, data: { token, business_name: info.business_name, city: info.city, logo: info.logo_url, vendor_code: info.vendor_code } });
});

// POST /api/v2/vendor-qr/me/regenerate — expire l'ancienne référence (autocollant inerte) + nouvelle.
router.post('/me/regenerate', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const vid = await getVendorId(req.user!.id);
  if (!vid) { res.status(403).json({ success: false, error: 'Compte vendeur introuvable' }); return; }
  await supabaseAdmin.from('vendor_payment_qr')
    .update({ status: 'expired' }).eq('vendor_id', vid).eq('kind', 'static').eq('status', 'active');
  const reference = crypto.randomBytes(24).toString('base64url');
  const { data, error } = await supabaseAdmin.from('vendor_payment_qr')
    .insert({ vendor_id: vid, kind: 'static', reference }).select('reference').single();
  if (error) { res.status(500).json({ success: false, error: 'Échec de la régénération' }); return; }
  logger.info(`[vendor-qr] ${req.user!.id} a régénéré son QR (vendor ${vid})`);
  res.json({ success: true, data: { token: (data as { reference: string }).reference } });
});

// GET /api/v2/vendor-qr/resolve/:token — PUBLIC (page de scan, aucun compte requis). Rate-limité.
// Résout une référence wallet-pay → contexte boutique PUBLIC UNIQUEMENT (nom/ville/logo/devise/frais).
// Renvoie { status: 'active'|'revoked'|'unknown', + contexte si actif }. Aucune donnée sensible.
router.get('/resolve/:token', paymentRateLimit, async (req: Request, res: Response): Promise<void> => {
  const token = String(req.params.token || '');
  if (!token || token.length < 8) { res.json({ success: true, data: { status: 'unknown' } }); return; }
  const { data: qr } = await supabaseAdmin.from('vendor_payment_qr')
    .select('vendor_id, kind, amount, status, expires_at').eq('reference', token).maybeSingle();
  if (!qr) { res.json({ success: true, data: { status: 'unknown' } }); return; }
  const q = qr as { vendor_id: string; kind: string; amount: number | null; status: string; expires_at: string | null };
  if (q.status !== 'active' || (q.expires_at && new Date(q.expires_at).getTime() < Date.now())) {
    res.json({ success: true, data: { status: 'revoked' } }); return;
  }
  const { data: v } = await supabaseAdmin.from('vendors')
    .select('business_name, city, logo_url, user_id').eq('id', q.vendor_id).maybeSingle();
  const vv = (v ?? {}) as { business_name?: string; city?: string; logo_url?: string; user_id?: string };
  const { data: wallets } = await supabaseAdmin.from('wallets').select('currency').eq('user_id', vv.user_id ?? '');
  const curs = (wallets || []).map((w: { currency?: string }) => String(w.currency || 'GNF'));
  const currency = curs.includes('GNF') ? 'GNF' : (curs[0] || 'GNF');
  const { data: cfg } = await supabaseAdmin.from('wallet_pay_config')
    .select('qr_wallet_client_fee_percent').eq('is_active', true).maybeSingle();
  const feePercent = Number((cfg as { qr_wallet_client_fee_percent?: number } | null)?.qr_wallet_client_fee_percent ?? 0);
  res.json({ success: true, data: {
    status: 'active', kind: q.kind, amount: q.amount ?? null,
    name: (vv.business_name && vv.business_name.trim()) || 'Boutique',
    city: vv.city || null, logo: vv.logo_url || null, currency, fee_percent: feePercent,
  } });
});

// GET /api/v2/vendor-qr/pay-target/:code — PUBLIC. Résout un code (agent_code ou public_id) →
// destinataire du paiement (nom + devise), pour la page de scan /p/:code. Aucune donnée sensible.
router.get('/pay-target/:code', paymentRateLimit, async (req: Request, res: Response): Promise<void> => {
  const code = String(req.params.code || '').trim();
  if (!/^[A-Za-z0-9-]{3,40}$/.test(code)) { res.json({ success: true, data: { found: false } }); return; }

  let name: string | null = null;
  let userId: string | null = null;

  const { data: agent } = await supabaseAdmin.from('agents_management')
    .select('user_id, name').eq('agent_code', code.toUpperCase()).maybeSingle();
  if (agent) { name = (agent as any).name; userId = (agent as any).user_id; }

  if (!userId) {
    const { data: prof } = await supabaseAdmin.from('profiles')
      .select('id, first_name, last_name, public_id')
      .or(`public_id.eq.${code},custom_id.eq.${code}`).maybeSingle();
    if (prof) {
      const p = prof as any;
      name = [p.first_name, p.last_name].filter(Boolean).join(' ').trim() || p.public_id || code;
      userId = p.id;
    }
  }

  if (!userId) { res.json({ success: true, data: { found: false } }); return; }

  // Nom de la BOUTIQUE en priorité (pas le nom du propriétaire) + logo + ville.
  const { data: vendor } = await supabaseAdmin.from('vendors')
    .select('business_name, logo_url, city').eq('user_id', userId).maybeSingle();
  const v = (vendor ?? {}) as { business_name?: string; logo_url?: string; city?: string };
  const displayName = (v.business_name && v.business_name.trim()) || name || code;

  const { data: wallets } = await supabaseAdmin.from('wallets')
    .select('currency').eq('user_id', userId);
  const curs = (wallets || []).map((w: any) => String(w.currency || 'GNF'));
  const currency = curs.includes('GNF') ? 'GNF' : (curs[0] || 'GNF');

  res.json({ success: true, data: {
    found: true, code, name: displayName, owner_name: name,
    logo: v.logo_url || null, city: v.city || null, currency,
  } });
});

export default router;
