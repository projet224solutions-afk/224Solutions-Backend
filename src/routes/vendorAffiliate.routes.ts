/**
 * 🤝 AFFILIATION VENDEUR (type Amazon Associates) — Phase 2 backend.
 *
 *   POST /api/affiliate/track-click      → enregistre l'attribution (clic, fenêtre 30j, anti-auto)
 *   GET  /api/affiliate/product/:id      → infos programme (activé ? taux ?) + ref du user courant
 *   GET  /api/affiliate/my-commissions   → tableau de bord affilié
 *   GET  /api/affiliate/vendor           → tableau de bord vendeur
 *
 * Helpers exportés (appelés par orders.routes) :
 *   recordAffiliateConversions  → à la commande : crée les commissions `pending` attribuées
 *   confirmAffiliateCommissions → à la libération escrow : confirme + paie (RPC atomique)
 *   cancelAffiliateCommissions  → au remboursement/retour : annule
 */

import { Router, Request, Response } from 'express';
import { z } from 'zod';
import { verifyJWT, optionalJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

// ── Helpers (réutilisés par orders.routes) ─────────────────────────────────

/** Résout un code `ref` (public_id de l'affilié) → user_id. */
async function resolveAffiliateUserId(ref: string): Promise<string | null> {
  if (!ref) return null;
  const { data } = await supabaseAdmin.from('profiles').select('id').eq('public_id', ref).maybeSingle();
  return data?.id || null;
}

/**
 * À la création d'une commande NUMÉRIQUE : si le produit numérique est affilié ET qu'une
 * attribution valide existe (clic < 30j pour cet acheteur), crée une commission `pending`.
 * (L'affiliation ne concerne QUE les produits numériques — voir digital_products.affiliate_*.)
 * Best-effort, idempotent (UNIQUE order+product+affilié). Ne bloque jamais la commande.
 */
export async function recordAffiliateConversions(orderId: string, buyerUserId: string): Promise<void> {
  try {
    const { data: order } = await supabaseAdmin
      .from('orders')
      .select('id, vendor_id, total_amount, metadata')
      .eq('id', orderId).maybeSingle();
    if (!order?.vendor_id) return;

    const meta = (order.metadata && typeof order.metadata === 'object' ? order.metadata : {}) as any;
    if (meta.item_type !== 'digital_product') return; // affiliation = produits numériques uniquement
    const productId = meta.digital_product_id;
    if (!productId) return;

    const { data: product } = await supabaseAdmin
      .from('digital_products')
      .select('affiliate_enabled, affiliate_commission_rate, vendor_id')
      .eq('id', productId).maybeSingle();
    if (!product?.affiliate_enabled || !(Number(product.affiliate_commission_rate) > 0)) return;

    const { data: vendor } = await supabaseAdmin.from('vendors').select('user_id').eq('id', order.vendor_id).maybeSingle();
    const vendorUserId = vendor?.user_id || null;

    // Attribution last-click valide pour cet acheteur + produit (fenêtre 30j).
    const { data: click } = await supabaseAdmin
      .from('affiliate_clicks')
      .select('affiliate_user_id')
      .eq('buyer_user_id', buyerUserId)
      .eq('product_id', productId)
      .gt('expires_at', new Date().toISOString())
      .order('clicked_at', { ascending: false })
      .limit(1).maybeSingle();
    const affiliateUserId = click?.affiliate_user_id;
    if (!affiliateUserId) return;
    if (affiliateUserId === buyerUserId || affiliateUserId === vendorUserId) return; // anti-auto

    const saleAmount = Number(order.total_amount)
      || (Number(meta.unit_price) || 0) * (Number(meta.quantity) || 1);
    const rate = Number(product.affiliate_commission_rate) || 0;
    const commission = Math.round(saleAmount * (rate / 100));
    if (commission <= 0) return;

    await supabaseAdmin.from('affiliate_commissions').insert({
      order_id: orderId, product_id: productId, affiliate_user_id: affiliateUserId,
      vendor_id: order.vendor_id, sale_amount: saleAmount, commission_rate: rate,
      commission_amount: commission, currency: meta.currency || 'GNF', status: 'pending',
    }).then(() => {}, () => {}); // ON CONFLICT (unique) → ignore
  } catch (e: any) {
    logger.warn(`[affiliate] recordConversions ${orderId}: ${e?.message}`);
  }
}

/** À la libération escrow : confirme + paie les commissions (RPC atomique). Best-effort. */
export async function confirmAffiliateCommissions(orderId: string): Promise<void> {
  await supabaseAdmin.rpc('confirm_affiliate_commissions', { p_order_id: orderId })
    .then(() => {}, (e) => logger.warn(`[affiliate] confirm ${orderId}: ${e?.message}`));
}

/** Au remboursement/retour : annule les commissions pending. Best-effort. */
export async function cancelAffiliateCommissions(orderId: string): Promise<void> {
  await supabaseAdmin.rpc('cancel_affiliate_commissions', { p_order_id: orderId })
    .then(() => {}, (e) => logger.warn(`[affiliate] cancel ${orderId}: ${e?.message}`));
}

// ── Endpoints ──────────────────────────────────────────────────────────────

/** POST /api/affiliate/track-click — enregistre l'attribution (acheteur connecté requis). */
router.post('/track-click', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const parsed = z.object({ product_id: z.string().uuid(), ref: z.string().min(2).max(64) }).safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: 'Paramètres invalides' }); return; }
    const buyerUserId = req.user!.id;
    const { product_id, ref } = parsed.data;

    const { data: product } = await supabaseAdmin
      .from('digital_products').select('id, affiliate_enabled, vendor_id').eq('id', product_id).maybeSingle();
    if (!product?.affiliate_enabled) { res.json({ success: true, attributed: false }); return; }

    const affiliateUserId = await resolveAffiliateUserId(ref);
    if (!affiliateUserId || affiliateUserId === buyerUserId) { res.json({ success: true, attributed: false }); return; }
    // anti-auto : l'affilié ne peut pas être le propriétaire de la boutique
    const { data: vendor } = await supabaseAdmin.from('vendors').select('user_id').eq('id', product.vendor_id).maybeSingle();
    if (vendor?.user_id === affiliateUserId) { res.json({ success: true, attributed: false }); return; }

    await supabaseAdmin.from('affiliate_clicks').insert({
      product_id, affiliate_user_id: affiliateUserId, buyer_user_id: buyerUserId,
    });
    res.json({ success: true, attributed: true });
  } catch (e: any) {
    logger.warn(`[affiliate/track-click] ${e?.message}`);
    res.json({ success: true, attributed: false }); // non bloquant
  }
});

/** GET /api/affiliate/product/:id — programme du produit + lien de l'utilisateur courant. */
router.get('/product/:id', optionalJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { data: product } = await supabaseAdmin
      .from('digital_products').select('id, affiliate_enabled, affiliate_commission_rate, vendor_id')
      .eq('id', req.params.id).maybeSingle();
    if (!product) { res.status(404).json({ success: false, error: 'Produit introuvable' }); return; }

    let ref: string | null = null;
    let isOwner = false;
    if (req.user?.id) {
      const { data: prof } = await supabaseAdmin.from('profiles').select('public_id').eq('id', req.user.id).maybeSingle();
      ref = prof?.public_id || null;
      const { data: vendor } = await supabaseAdmin.from('vendors').select('user_id').eq('id', product.vendor_id).maybeSingle();
      isOwner = vendor?.user_id === req.user.id;
    }
    res.json({
      success: true,
      enabled: !!product.affiliate_enabled,
      commission_rate: Number(product.affiliate_commission_rate) || 0,
      ref: isOwner ? null : ref, // le vendeur ne s'affilie pas à lui-même
      can_affiliate: !!product.affiliate_enabled && !isOwner && !!ref,
    });
  } catch (e: any) {
    logger.error(`[affiliate/product] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** GET /api/affiliate/my-commissions — tableau de bord affilié. */
router.get('/my-commissions', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const uid = req.user!.id;
    const [commsRes, clicksRes] = await Promise.all([
      supabaseAdmin.from('affiliate_commissions')
        .select('id, order_id, product_id, sale_amount, commission_amount, currency, status, created_at, confirmed_at')
        .eq('affiliate_user_id', uid).order('created_at', { ascending: false }).limit(200),
      supabaseAdmin.from('affiliate_clicks').select('id', { count: 'exact', head: true }).eq('affiliate_user_id', uid),
    ]);
    const comms = commsRes.data || [];
    const sum = (st: string) => comms.filter(c => c.status === st).reduce((s, c) => s + Number(c.commission_amount || 0), 0);
    res.json({
      success: true,
      clicks: clicksRes.count || 0,
      conversions: comms.length,
      pending: sum('pending'),
      confirmed: sum('confirmed'),
      commissions: comms,
    });
  } catch (e: any) {
    logger.error(`[affiliate/my-commissions] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** GET /api/affiliate/vendor — tableau de bord vendeur (commissions de sa boutique, enrichi). */
router.get('/vendor', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { data: vendor } = await supabaseAdmin.from('vendors').select('id').eq('user_id', req.user!.id).maybeSingle();
    if (!vendor) {
      res.json({ success: true, commissions: [], pending: 0, confirmed: 0, cancelled: 0, affiliates: 0, products_enabled: 0 });
      return;
    }
    const [commsRes, prodRes] = await Promise.all([
      supabaseAdmin.from('affiliate_commissions')
        .select('id, order_id, product_id, affiliate_user_id, sale_amount, commission_amount, commission_rate, currency, status, created_at, confirmed_at')
        .eq('vendor_id', vendor.id).order('created_at', { ascending: false }).limit(300),
      supabaseAdmin.from('digital_products').select('id', { count: 'exact', head: true })
        .eq('vendor_id', vendor.id).eq('affiliate_enabled', true),
    ]);
    const comms = commsRes.data || [];

    // Enrichissement : nom produit numérique + identifiant public de l'affilié (lisible).
    const productIds = [...new Set(comms.map(c => c.product_id).filter(Boolean))];
    const affiliateIds = [...new Set(comms.map(c => c.affiliate_user_id).filter(Boolean))];
    const [prodNames, affNames] = await Promise.all([
      productIds.length
        ? supabaseAdmin.from('digital_products').select('id, title').in('id', productIds)
        : Promise.resolve({ data: [] as any[] }),
      affiliateIds.length
        ? supabaseAdmin.from('profiles').select('id, public_id, full_name').in('id', affiliateIds)
        : Promise.resolve({ data: [] as any[] }),
    ]);
    const pMap = new Map((prodNames.data || []).map((p: any) => [p.id, p.title]));
    const aMap = new Map((affNames.data || []).map((a: any) => [a.id, a.public_id || a.full_name]));
    const enriched = comms.map(c => ({
      ...c,
      product_name: pMap.get(c.product_id) || '—',
      affiliate_ref: aMap.get(c.affiliate_user_id) || '—',
    }));

    const sum = (st: string) => comms.filter(c => c.status === st).reduce((s, c) => s + Number(c.commission_amount || 0), 0);
    res.json({
      success: true,
      commissions: enriched,
      pending: sum('pending'),
      confirmed: sum('confirmed'),
      cancelled: sum('cancelled'),
      affiliates: affiliateIds.length,
      products_enabled: prodRes.count || 0,
    });
  } catch (e: any) {
    logger.error(`[affiliate/vendor] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

export default router;
