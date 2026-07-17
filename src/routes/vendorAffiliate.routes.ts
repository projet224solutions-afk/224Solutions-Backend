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

    // 🛡️ BLOC 3 — plafond de commissions EN ATTENTE par affilié (config PDG) :
    // au-delà, pas de nouvelle commission (silencieux + alerte sécurité).
    const { data: cfg } = await supabaseAdmin.from('affiliate_config')
      .select('max_pending_per_affiliate').eq('id', true).maybeSingle();
    const maxPending = Number((cfg as any)?.max_pending_per_affiliate || 0);
    if (maxPending > 0) {
      const { data: pendings } = await supabaseAdmin.from('affiliate_commissions')
        .select('commission_amount').eq('affiliate_user_id', affiliateUserId).eq('status', 'pending');
      const pendingSum = (pendings || []).reduce((s: number, r: any) => s + Number(r.commission_amount || 0), 0);
      if (pendingSum >= maxPending) {
        logger.warn(`[affiliate] plafond pending atteint pour ${affiliateUserId} (${pendingSum} ≥ ${maxPending}) — commission non créée`);
        void Promise.resolve(supabaseAdmin.from('financial_security_alerts').insert({
          alert_type: 'AFFILIATE_PENDING_CAP', severity: 'medium',
          details: { affiliate_user_id: affiliateUserId, pending_sum: pendingSum, cap: maxPending, order_id: orderId },
        })).catch(() => {});
        return;
      }
    }

    const saleAmount = Number(order.total_amount)
      || (Number(meta.unit_price) || 0) * (Number(meta.quantity) || 1);

    // 🪜 BLOC 5 — paliers de commission (optionnel vendeur) : le taux monte avec
    // les ventes du MOIS de cet affilié sur CE produit (palier le plus haut atteint).
    let rate = Number(product.affiliate_commission_rate) || 0;
    const { data: tiers } = await supabaseAdmin.from('affiliate_commission_tiers')
      .select('min_monthly_sales, rate').eq('product_id', productId)
      .order('min_monthly_sales', { ascending: false });
    if (tiers && tiers.length) {
      const monthStart = new Date(); monthStart.setDate(1); monthStart.setHours(0, 0, 0, 0);
      const { count: monthlySales } = await supabaseAdmin.from('affiliate_commissions')
        .select('id', { count: 'exact', head: true })
        .eq('affiliate_user_id', affiliateUserId).eq('product_id', productId)
        .neq('status', 'cancelled').gte('created_at', monthStart.toISOString());
      const tier = (tiers as any[]).find(t => Number(t.min_monthly_sales) <= (monthlySales || 0));
      if (tier && Number(tier.rate) > 0) rate = Number(tier.rate);
    }

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

/**
 * 💸 BLOC 0 — activation côté COMPTE (client OU pro : UN SEUL système).
 * POST /api/affiliate/activate { accept_terms: true } → consentement horodaté.
 * Idempotent : déjà activé → succès sans écraser le consentement d'origine.
 */
router.post('/activate', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    if (req.body?.accept_terms !== true) {
      res.status(400).json({ success: false, error: 'Le consentement aux règles du programme est requis.', error_code: 'CONSENT_REQUIRED' });
      return;
    }
    const { data: prof } = await supabaseAdmin.from('profiles')
      .select('affiliate_enabled, affiliate_consent_at, public_id').eq('id', req.user!.id).maybeSingle();
    if (!(prof as any)?.affiliate_enabled) {
      const { error } = await supabaseAdmin.from('profiles')
        .update({ affiliate_enabled: true, affiliate_consent_at: new Date().toISOString() } as any)
        .eq('id', req.user!.id);
      if (error) { res.status(500).json({ success: false, error: "Activation impossible" }); return; }
    }
    res.json({ success: true, data: { enabled: true, ref: (prof as any)?.public_id || null } });
  } catch (e: any) {
    logger.error(`[affiliate/activate] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** Désactivation (les commissions en attente suivent leur cycle normal). */
router.post('/deactivate', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const { error } = await supabaseAdmin.from('profiles')
    .update({ affiliate_enabled: false } as any).eq('id', req.user!.id);
  if (error) { res.status(500).json({ success: false, error: 'Désactivation impossible' }); return; }
  res.json({ success: true, data: { enabled: false } });
});

/** État affilié du compte courant (porte d'entrée des surfaces). */
router.get('/me', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const { data: prof } = await supabaseAdmin.from('profiles')
    .select('affiliate_enabled, affiliate_consent_at, public_id').eq('id', req.user!.id).maybeSingle();
  res.json({ success: true, data: {
    enabled: !!(prof as any)?.affiliate_enabled,
    consent_at: (prof as any)?.affiliate_consent_at || null,
    ref: (prof as any)?.public_id || null,
  } });
});

/**
 * 🛒 BLOC 1 — LA MARKETPLACE DES AFFILIÉS : tous les produits affiliables
 * (opt-in vendeurs) avec taux, paliers et gain estimé/vente.
 * Filtres : ?category=…&min_rate=…&sort=rate|price
 */
router.get('/marketplace', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    let q = supabaseAdmin.from('digital_products')
      .select('id, title, price, currency, images, category, short_description, affiliate_commission_rate, vendor_id')
      .eq('affiliate_enabled', true).eq('status', 'published');
    const category = String(req.query.category || '').trim();
    if (category) q = q.eq('category', category);
    const minRate = Number(req.query.min_rate || 0);
    if (minRate > 0) q = q.gte('affiliate_commission_rate', minRate);
    q = String(req.query.sort) === 'price'
      ? q.order('price', { ascending: false })
      : q.order('affiliate_commission_rate', { ascending: false });
    const { data: products, error } = await q.limit(100);
    if (error) throw error;

    const rows = (products || []) as any[];
    const ids = rows.map(p => p.id);
    const vendorIds = [...new Set(rows.map(p => p.vendor_id).filter(Boolean))];
    const [tiersRes, vendorsRes] = await Promise.all([
      ids.length ? supabaseAdmin.from('affiliate_commission_tiers')
        .select('product_id, min_monthly_sales, rate').in('product_id', ids)
        .order('min_monthly_sales', { ascending: true }) : Promise.resolve({ data: [] as any[] }),
      vendorIds.length ? supabaseAdmin.from('vendors').select('id, business_name').in('id', vendorIds)
        : Promise.resolve({ data: [] as any[] }),
    ]);
    const tiersByProduct = new Map<string, any[]>();
    for (const t of (tiersRes.data || []) as any[]) {
      const arr = tiersByProduct.get(t.product_id) || []; arr.push(t); tiersByProduct.set(t.product_id, arr);
    }
    const vName = new Map(((vendorsRes.data || []) as any[]).map(v => [v.id, v.business_name]));

    res.json({ success: true, data: rows.map(p => ({
      id: p.id, title: p.title, price: Number(p.price) || 0, currency: p.currency || 'GNF',
      image: (p.images && p.images[0]) || null, category: p.category || null,
      short_description: p.short_description || null,
      vendor_name: vName.get(p.vendor_id) || null,
      commission_rate: Number(p.affiliate_commission_rate) || 0,
      estimated_gain: Math.round((Number(p.price) || 0) * ((Number(p.affiliate_commission_rate) || 0) / 100)),
      tiers: tiersByProduct.get(p.id) || [],
    })) });
  } catch (e: any) {
    logger.error(`[affiliate/marketplace] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * 📊 BLOC 2 — LA MESURE côté affilié : clics, conversions, taux, EPC,
 * par produit et série 30 j.
 */
router.get('/my-stats', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const uid = req.user!.id;
    const since = new Date(Date.now() - 30 * 86400e3).toISOString();
    const [clicksRes, commsRes] = await Promise.all([
      supabaseAdmin.from('affiliate_product_clicks')
        .select('product_id, clicked_at').eq('affiliate_user_id', uid).gte('clicked_at', since).limit(10000),
      supabaseAdmin.from('affiliate_commissions')
        .select('product_id, commission_amount, sale_amount, status, paid_at, created_at')
        .eq('affiliate_user_id', uid).limit(2000),
    ]);
    const clicks = (clicksRes.data || []) as any[];
    const comms = (commsRes.data || []) as any[];
    const confirmedTotal = comms.filter(c => c.status === 'confirmed')
      .reduce((s, c) => s + Number(c.commission_amount || 0), 0);
    const conversions = comms.filter(c => c.status !== 'cancelled').length;

    const byProduct = new Map<string, { clicks: number; conversions: number; earned: number }>();
    for (const cl of clicks) {
      const b = byProduct.get(cl.product_id) || { clicks: 0, conversions: 0, earned: 0 };
      b.clicks++; byProduct.set(cl.product_id, b);
    }
    for (const cm of comms) {
      if (cm.status === 'cancelled') continue;
      const b = byProduct.get(cm.product_id) || { clicks: 0, conversions: 0, earned: 0 };
      b.conversions++; if (cm.status === 'confirmed') b.earned += Number(cm.commission_amount || 0);
      byProduct.set(cm.product_id, b);
    }
    const pIds = [...byProduct.keys()];
    const { data: pNames } = pIds.length
      ? await supabaseAdmin.from('digital_products').select('id, title').in('id', pIds)
      : { data: [] as any[] };
    const nameMap = new Map(((pNames || []) as any[]).map(p => [p.id, p.title]));

    const day = (d: string) => d.slice(0, 10);
    const series: Record<string, { clicks: number; earned: number }> = {};
    for (const cl of clicks) { const k = day(cl.clicked_at); series[k] = series[k] || { clicks: 0, earned: 0 }; series[k].clicks++; }
    for (const cm of comms) {
      if (cm.status !== 'confirmed' || !cm.created_at || cm.created_at < since) continue;
      const k = day(cm.created_at); series[k] = series[k] || { clicks: 0, earned: 0 };
      series[k].earned += Number(cm.commission_amount || 0);
    }

    res.json({ success: true, data: {
      clicks_30d: clicks.length,
      conversions,
      conversion_rate: clicks.length ? conversions / clicks.length : 0,
      epc: clicks.length ? Math.round(confirmedTotal / clicks.length) : 0,
      pending: comms.filter(c => c.status === 'pending').reduce((s, c) => s + Number(c.commission_amount || 0), 0),
      confirmed_unpaid: comms.filter(c => c.status === 'confirmed' && !c.paid_at).reduce((s, c) => s + Number(c.commission_amount || 0), 0),
      paid: comms.filter(c => c.paid_at).reduce((s, c) => s + Number(c.commission_amount || 0), 0),
      cancelled: comms.filter(c => c.status === 'cancelled').reduce((s, c) => s + Number(c.commission_amount || 0), 0),
      by_product: [...byProduct.entries()].map(([id, b]) => ({
        product_id: id, title: nameMap.get(id) || '—', ...b,
        epc: b.clicks ? Math.round(b.earned / b.clicks) : 0,
      })).sort((a, b) => b.earned - a.earned),
      series_30d: Object.entries(series).sort(([a], [b]) => a.localeCompare(b))
        .map(([date, v]) => ({ date, ...v })),
      commissions: comms.sort((a, b) => String(b.created_at).localeCompare(String(a.created_at))).slice(0, 100),
    } });
  } catch (e: any) {
    logger.error(`[affiliate/my-stats] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** 📊 BLOC 2 — côté vendeur : affiliés classés + CA affiliation vs direct (30 j). */
router.get('/vendor-stats', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { data: vendor } = await supabaseAdmin.from('vendors').select('id').eq('user_id', req.user!.id).maybeSingle();
    if (!vendor) { res.json({ success: true, data: { affiliates: [], ca_affiliate_30d: 0, ca_direct_30d: 0 } }); return; }
    const since = new Date(Date.now() - 30 * 86400e3).toISOString();
    const [commsRes, ordersRes] = await Promise.all([
      supabaseAdmin.from('affiliate_commissions')
        .select('affiliate_user_id, sale_amount, commission_amount, status, created_at')
        .eq('vendor_id', vendor.id).gte('created_at', since).limit(3000),
      (supabaseAdmin.from('orders') as any)
        .select('total_amount, metadata, created_at')
        .eq('vendor_id', vendor.id).gte('created_at', since).limit(5000),
    ]);
    const comms = ((commsRes.data || []) as any[]).filter(c => c.status !== 'cancelled');
    const caAffiliate = comms.reduce((s, c) => s + Number(c.sale_amount || 0), 0);
    const caDigitalTotal = ((ordersRes.data || []) as any[])
      .filter(o => o.metadata?.item_type === 'digital_product')
      .reduce((s, o) => s + Number(o.total_amount || 0), 0);

    const byAff = new Map<string, { sales: number; ca: number; commissions: number }>();
    for (const cm of comms) {
      const b = byAff.get(cm.affiliate_user_id) || { sales: 0, ca: 0, commissions: 0 };
      b.sales++; b.ca += Number(cm.sale_amount || 0); b.commissions += Number(cm.commission_amount || 0);
      byAff.set(cm.affiliate_user_id, b);
    }
    const affIds = [...byAff.keys()];
    const { data: profs } = affIds.length
      ? await supabaseAdmin.from('profiles').select('id, public_id, full_name').in('id', affIds)
      : { data: [] as any[] };
    const refMap = new Map(((profs || []) as any[]).map(p => [p.id, p.public_id || p.full_name || '—']));

    res.json({ success: true, data: {
      ca_affiliate_30d: caAffiliate,
      ca_direct_30d: Math.max(0, caDigitalTotal - caAffiliate),
      affiliates: [...byAff.entries()].map(([id, b]) => ({ affiliate_ref: refMap.get(id) || '—', ...b }))
        .sort((a, b) => b.ca - a.ca).slice(0, 50),
    } });
  } catch (e: any) {
    logger.error(`[affiliate/vendor-stats] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

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
    let isActivated = false;
    if (req.user?.id) {
      const { data: prof } = await supabaseAdmin.from('profiles')
        .select('public_id, affiliate_enabled').eq('id', req.user.id).maybeSingle();
      ref = prof?.public_id || null;
      isActivated = !!(prof as any)?.affiliate_enabled;
      const { data: vendor } = await supabaseAdmin.from('vendors').select('user_id').eq('id', product.vendor_id).maybeSingle();
      isOwner = vendor?.user_id === req.user.id;
    }
    res.json({
      success: true,
      enabled: !!product.affiliate_enabled,
      commission_rate: Number(product.affiliate_commission_rate) || 0,
      ref: isOwner ? null : ref, // le vendeur ne s'affilie pas à lui-même
      // 🛡️ BLOC 0 : obtenir un lien exige l'activation du programme (consentement).
      can_affiliate: !!product.affiliate_enabled && !isOwner && !!ref && isActivated,
      needs_activation: !!product.affiliate_enabled && !isOwner && !isActivated,
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
