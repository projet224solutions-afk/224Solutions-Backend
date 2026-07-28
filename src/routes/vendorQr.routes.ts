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
import { truncateRef } from '../utils/qrPayment.js';
import { maskCivilName, isEnumBlocked, recordMiss, recordHit } from '../utils/payTargetGuard.js';

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
// destinataire du paiement (nom SELON le type + devise), pour la page de scan /p/:code.
//
// 🔒 Anti-annuaire : les `public_id` sont SÉQUENTIELS. On n'expose donc JAMAIS le nom civil complet
// d'un particulier (→ « Prénom I. »), jamais d'email/téléphone/public_id/soldes. La réponse
// « non trouvé » est à FORME et TEMPS constants (pas d'oracle de format) et un balayage bloque l'IP.
const PAY_TARGET_FLOOR_MS = 160; // plancher de temps uniforme (miss ≈ hit, pas d'oracle)

function clientIp(req: Request): string {
  return String(req.ip || (req.socket && req.socket.remoteAddress) || 'unknown');
}
async function padTo(startedAt: number, floorMs: number): Promise<void> {
  const elapsed = Date.now() - startedAt;
  if (elapsed < floorMs) await new Promise((r) => setTimeout(r, floorMs - elapsed));
}
async function defaultCurrencyForUser(userId: string): Promise<string> {
  // UNE seule devise (jamais la liste des wallets détenus).
  const { data: wallets } = await supabaseAdmin.from('wallets').select('currency').eq('user_id', userId);
  const curs = (wallets || []).map((w: { currency?: string }) => String(w.currency || 'GNF'));
  return curs.includes('GNF') ? 'GNF' : (curs[0] || 'GNF');
}

router.get('/pay-target/:code', paymentRateLimit, async (req: Request, res: Response): Promise<void> => {
  const startedAt = Date.now();
  const ip = clientIp(req);
  const rawCode = String(req.params.code || '').trim();

  const respondNotFound = async (): Promise<void> => {
    recordMiss(ip, Date.now());
    logger.info(`[pay-target] miss ip=${ip} code=${truncateRef(rawCode)}`);
    await padTo(startedAt, PAY_TARGET_FLOOR_MS);
    res.json({ success: true, data: { found: false } });
  };

  // Balayage détecté → blocage temporaire de l'IP (même forme/temps qu'un « non trouvé »).
  if (isEnumBlocked(ip, startedAt)) {
    logger.warn(`[pay-target] IP bloquée (balayage suspecté) ip=${ip}`);
    await padTo(startedAt, PAY_TARGET_FLOOR_MS);
    res.status(429).json({ success: false, error: 'Trop de tentatives. Réessayez plus tard.' });
    return;
  }
  if (!/^[A-Za-z0-9-]{3,40}$/.test(rawCode)) { await respondNotFound(); return; }

  // Résolution : agent_code (fonction publique) puis public_id/custom_id (profil).
  let userId: string | null = null;
  let agentName: string | null = null;
  let firstName = ''; let lastName = '';

  const { data: agent } = await supabaseAdmin.from('agents_management')
    .select('user_id, name').eq('agent_code', rawCode.toUpperCase()).maybeSingle();
  if (agent) { agentName = (agent as { name?: string }).name || null; userId = (agent as { user_id?: string }).user_id || null; }

  if (!userId) {
    const { data: prof } = await supabaseAdmin.from('profiles')
      .select('id, first_name, last_name')
      .or(`public_id.eq.${rawCode},custom_id.eq.${rawCode}`).maybeSingle();
    if (prof) {
      const p = prof as { id: string; first_name?: string; last_name?: string };
      userId = p.id; firstName = p.first_name || ''; lastName = p.last_name || '';
    }
  }

  if (!userId) { await respondNotFound(); return; }

  const { data: vendor } = await supabaseAdmin.from('vendors')
    .select('business_name, logo_url, city').eq('user_id', userId).maybeSingle();
  const v = (vendor ?? {}) as { business_name?: string; logo_url?: string; city?: string };
  const currency = await defaultCurrencyForUser(userId);

  recordHit(ip, Date.now());
  logger.info(`[pay-target] hit ip=${ip} code=${truncateRef(rawCode)}`);
  await padTo(startedAt, PAY_TARGET_FLOOR_MS);

  if (v.business_name && v.business_name.trim()) {
    // VITRINE : boutique existante → nom + logo + ville en clair (donnée publique).
    res.json({ success: true, data: { found: true, kind: 'vendor', name: v.business_name.trim(), logo: v.logo_url || null, city: v.city || null, currency } });
    return;
  }
  if (agentName) {
    // AGENT : nom de fonction publique en clair.
    res.json({ success: true, data: { found: true, kind: 'agent', name: agentName, logo: null, city: null, currency } });
    return;
  }
  // PARTICULIER : nom MASQUÉ « Prénom I. » — vérifier le bénéficiaire sans constituer d'annuaire.
  res.json({ success: true, data: { found: true, kind: 'user', name: maskCivilName(firstName, lastName), logo: null, city: null, currency } });
});

export default router;
