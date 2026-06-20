/**
 * 🌍 COUNTRY PRICING ROUTES — /api/v2/country-pricing
 *
 * - Client : voit UNIQUEMENT la grille de SON pays verrouillé (jamais un autre pays).
 * - Admin/PDG : gère la grille (prix par pays), active/désactive un pays, change le pays
 *   d'un utilisateur (motif obligatoire + journal). Tout passe par les RPC atomiques SQL.
 *
 * Aucune écriture de prix/identité côté client : 100 % serveur (règle « tout en backend »).
 */

import { Router, Response } from 'express';
import { verifyJWT, requireRole } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import {
  getUserCountry, getCountryServicePrices, getSubscriptionPrice,
  formatPriceLabel, invalidateCountryPriceCache,
} from '../services/subscriptionPricing.service.js';

const router = Router();
const ADMIN = requireRole(['admin', 'pdg']);

// ──────────────────────── CLIENT ────────────────────────

/** GET /my-country → pays + devise de l'utilisateur (depuis profiles.country_code). */
router.get('/my-country', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const cc = await getUserCountry(req.user!.id);
    if (!cc) return res.json({ success: true, country_code: null });
    const { data } = await supabaseAdmin.from('countries')
      .select('country_code, country_name, currency_code, currency_symbol, flag_emoji, payment_methods')
      .eq('country_code', cc).maybeSingle();
    return res.json({ success: true, country: data, country_code: cc });
  } catch (e: any) {
    logger.error('GET /my-country', { error: e?.message });
    return res.status(500).json({ success: false, error: 'Erreur pays' });
  }
});

/** GET /prices?service_type=vendor → grille de SON pays uniquement (avec libellés). */
router.get('/prices', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const serviceType = String(req.query.service_type || 'vendor');
    const cc = await getUserCountry(req.user!.id);
    if (!cc) return res.json({ success: true, country_code: null, prices: [] });
    const prices = await getCountryServicePrices(cc, serviceType);
    return res.json({
      success: true, country_code: cc,
      prices: prices.map((p) => ({ ...p, label: formatPriceLabel(p) })),
    });
  } catch (e: any) {
    logger.error('GET /prices', { error: e?.message });
    return res.status(500).json({ success: false, error: 'Erreur prix' });
  }
});

/** GET /price?service_type=vendor&plan=pro&cycle=monthly → prix d'un plan (son pays). */
router.get('/price', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const serviceType = String(req.query.service_type || 'vendor');
    const plan = String(req.query.plan || '');
    const cycle = String(req.query.cycle || 'monthly');
    if (!plan) return res.status(400).json({ success: false, error: 'plan requis' });
    const price = await getSubscriptionPrice(req.user!.id, serviceType, plan, cycle);
    if (!price) return res.json({ success: true, found: false });
    return res.json({ success: true, found: true, price, label: formatPriceLabel(price) });
  } catch (e: any) {
    logger.error('GET /price', { error: e?.message });
    return res.status(500).json({ success: false, error: 'Erreur prix' });
  }
});

// ──────────────────────── ADMIN / PDG ────────────────────────

/** GET /admin/countries → tous les pays (admin). */
router.get('/admin/countries', verifyJWT, ADMIN, async (_req: AuthenticatedRequest, res: Response) => {
  const { data, error } = await supabaseAdmin.from('countries').select('*').order('country_name');
  if (error) return res.status(500).json({ success: false, error: error.message });
  return res.json({ success: true, countries: data });
});

/** GET /admin/prices?country_code=GN&service_type=vendor → grille complète (admin). */
router.get('/admin/prices', verifyJWT, ADMIN, async (req: AuthenticatedRequest, res: Response) => {
  let q = supabaseAdmin.from('subscription_prices').select('*');
  if (req.query.country_code) q = q.eq('country_code', String(req.query.country_code));
  if (req.query.service_type) q = q.eq('service_type', String(req.query.service_type));
  const { data, error } = await q.order('country_code').order('service_type').order('plan_code');
  if (error) return res.status(500).json({ success: false, error: error.message });
  return res.json({ success: true, prices: data });
});

/**
 * GET /admin/catalog?country_code=XX → catalogue RÉEL des plans (vendeur + services + driver)
 * joint au prix de ZONE-devise du pays. Liste TOUS les plans existants (même sans prix encore),
 * pour que la grille soit toujours complète et liée aux vrais abonnements.
 */
router.get('/admin/catalog', verifyJWT, ADMIN, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const countryCode = String(req.query.country_code || '');
    if (!countryCode) return res.status(400).json({ success: false, error: 'country_code requis' });

    const { data: country } = await supabaseAdmin.from('countries')
      .select('currency_code, currency_symbol').eq('country_code', countryCode).maybeSingle();
    const currency = (country as any)?.currency_code as string | undefined;
    if (!currency) return res.status(404).json({ success: false, error: 'Pays introuvable' });

    const [vendorPlans, servicePlans, serviceTypes, driverCfg, zonePrices] = await Promise.all([
      supabaseAdmin.from('plans').select('name, display_name, monthly_price_gnf, max_products, max_images_per_product, analytics_access, priority_support, featured_products, display_order'),
      supabaseAdmin.from('service_plans').select('name, display_name, monthly_price_gnf, service_type_id, is_active, max_products, max_bookings_per_month, analytics_access, priority_listing, display_order'),
      supabaseAdmin.from('service_types').select('id, code, name'),
      supabaseAdmin.from('driver_subscription_config').select('subscription_type, price, is_active'),
      supabaseAdmin.from('subscription_prices')
        .select('service_type, plan_code, price, commission_rate, billing_cycle, country_code')
        .eq('currency_code', currency),
    ]);

    const stById = new Map((serviceTypes.data || []).map((s: any) => [s.id, s]));
    // Prix de zone (country_code NULL) + override pays — clé service:plan:cycle
    const zoneMap = new Map<string, any>();
    for (const z of (zonePrices.data || []) as any[]) if (z.country_code == null) zoneMap.set(`${z.service_type}:${z.plan_code}:${z.billing_cycle}`, z);
    for (const z of (zonePrices.data || []) as any[]) if (z.country_code === countryCode) zoneMap.set(`${z.service_type}:${z.plan_code}:${z.billing_cycle}`, z);

    const zoneFor = (st: string, pc: string) => zoneMap.get(`${st}:${pc}:monthly`) || null;
    const items: any[] = [];

    const lim = (v: any) => (v === null || v === undefined ? null : Number(v)); // null = illimité

    // Vendeur
    for (const p of (vendorPlans.data || []) as any[]) {
      const z = zoneFor('vendor', p.name);
      const features: string[] = [];
      if (p.analytics_access) features.push('Analytics');
      if (p.priority_support) features.push('Support Pro');
      if (p.featured_products) features.push('Vedette');
      items.push({ group: 'vendor', service_type: 'vendor', service_name: 'Vendeur (boutique)',
        plan_code: p.name, plan_display: p.display_name || p.name, gnf_price: p.monthly_price_gnf ?? 0,
        max_products: lim(p.max_products), max_secondary: lim(p.max_images_per_product), secondary_label: 'Images/Produit',
        features, display_order: p.display_order ?? 0,
        zone_price: z ? Number(z.price) : null, zone_commission: z ? Number(z.commission_rate) : null });
    }
    // Services de PROXIMITÉ uniquement. Les codes « boutique/digital » (ecommerce, dropshipping,
    // digital_*) sont EXCLUS : le vendeur (boutique ET numérique) est tarifé via la table `plans`
    // (onglet Vendeur), pas via ces service_types. (Même exclusion que PDGServiceSubscriptions.)
    const EXCLUDED_SERVICE_CODES = new Set(['ecommerce', 'dropshipping', 'digital_livre', 'digital_logiciel']);
    for (const sp of (servicePlans.data || []) as any[]) {
      if (sp.is_active === false) continue;
      const st: any = stById.get(sp.service_type_id);
      if (!st || EXCLUDED_SERVICE_CODES.has(st.code)) continue;
      const z = zoneFor(st.code, sp.name);
      const features: string[] = [];
      if (sp.analytics_access) features.push('Analytics');
      if (sp.priority_listing) features.push('Vedette');
      items.push({ group: 'services', service_type: st.code, service_name: st.name,
        plan_code: sp.name, plan_display: sp.display_name || sp.name, gnf_price: sp.monthly_price_gnf ?? 0,
        max_products: lim(sp.max_products), max_secondary: lim(sp.max_bookings_per_month), secondary_label: 'Réservations/mois',
        features, display_order: sp.display_order ?? 0,
        zone_price: z ? Number(z.price) : null, zone_commission: z ? Number(z.commission_rate) : null });
    }
    // Driver
    for (const d of (driverCfg.data || []) as any[]) {
      if (d.is_active === false) continue;
      const z = zoneFor('driver', d.subscription_type);
      items.push({ group: 'driver', service_type: 'driver', service_name: 'Driver (taxi/livreur)',
        plan_code: d.subscription_type, plan_display: d.subscription_type, gnf_price: d.price ?? 0,
        max_products: null, max_secondary: null, secondary_label: '', features: [], display_order: 0,
        zone_price: z ? Number(z.price) : null, zone_commission: z ? Number(z.commission_rate) : null });
    }

    return res.json({ success: true, country_code: countryCode, currency,
      currency_symbol: (country as any)?.currency_symbol || currency, items });
  } catch (e: any) {
    logger.error('GET /admin/catalog', { error: e?.message });
    return res.status(500).json({ success: false, error: 'Erreur catalogue' });
  }
});

/**
 * POST /admin/prices → poser/modifier le prix de ZONE (devise du pays), partagé par tous les
 * pays de cette devise. Upsert MANUEL (select → update/insert) → robuste, indépendant de l'état
 * des index/RPC. La route est déjà gardée admin (ADMIN) et utilise service_role.
 */
router.post('/admin/prices', verifyJWT, ADMIN, async (req: AuthenticatedRequest, res: Response) => {
  const { country_code, service_type, plan_code, price, commission_rate, cycle, is_active } = req.body || {};
  if (!country_code || !service_type || !plan_code || price === undefined || price === null) {
    return res.status(400).json({ success: false, error: 'country_code, service_type, plan_code, price requis' });
  }
  const priceNum = Number(price);
  if (isNaN(priceNum) || priceNum < 0) return res.status(400).json({ success: false, error: 'Prix invalide' });
  const billing = cycle || 'monthly';

  // Devise de la zone (depuis le pays).
  const { data: country } = await supabaseAdmin.from('countries')
    .select('currency_code').eq('country_code', country_code).maybeSingle();
  const currency = (country as any)?.currency_code as string | undefined;
  if (!currency) return res.status(404).json({ success: false, error: 'Pays introuvable' });

  // Ligne de zone existante ?
  const { data: existing, error: selErr } = await supabaseAdmin.from('subscription_prices')
    .select('id').is('country_code', null)
    .eq('currency_code', currency).eq('service_type', service_type)
    .eq('plan_code', plan_code).eq('billing_cycle', billing).maybeSingle();
  if (selErr) return res.status(400).json({ success: false, error: selErr.message });

  const row: any = {
    country_code: null, currency_code: currency, service_type, plan_code,
    price: priceNum, billing_cycle: billing, is_active: is_active ?? true, updated_at: new Date().toISOString(),
  };
  if (commission_rate !== undefined && commission_rate !== null && commission_rate !== '') {
    row.commission_rate = Number(commission_rate);
  }

  let error;
  if (existing?.id) {
    ({ error } = await supabaseAdmin.from('subscription_prices').update(row).eq('id', existing.id));
  } else {
    ({ error } = await supabaseAdmin.from('subscription_prices').insert({ ...row, commission_rate: row.commission_rate ?? 0 }));
  }
  if (error) return res.status(400).json({ success: false, error: error.message });

  await invalidateCountryPriceCache(country_code, service_type);
  return res.json({ success: true, currency_code: currency, price: priceNum, scope: 'zone' });
});

/** POST /admin/countries/:code/active → activer/désactiver un pays (RPC atomique). */
router.post('/admin/countries/:code/active', verifyJWT, ADMIN, async (req: AuthenticatedRequest, res: Response) => {
  const { is_active } = req.body || {};
  const { data, error } = await supabaseAdmin.rpc('admin_set_country_active', {
    p_country_code: req.params.code, p_is_active: !!is_active,
  });
  if (error) return res.status(400).json({ success: false, error: error.message });
  await invalidateCountryPriceCache(req.params.code);
  return res.json({ success: true, result: data });
});

/** POST /admin/seed-country → (re)générer la grille d'un pays depuis le catalogue GN (FX-suggéré). */
router.post('/admin/seed-country', verifyJWT, ADMIN, async (req: AuthenticatedRequest, res: Response) => {
  const { country_code, overwrite } = req.body || {};
  if (!country_code) return res.status(400).json({ success: false, error: 'country_code requis' });
  const { data, error } = await supabaseAdmin.rpc('admin_seed_country_prices', {
    p_country_code: country_code, p_overwrite: !!overwrite,
  });
  if (error) return res.status(400).json({ success: false, error: error.message });
  await invalidateCountryPriceCache(country_code);
  return res.json({ success: true, result: data });
});

/** POST /admin/user-country → changer le pays d'un utilisateur (motif OBLIGATOIRE + log). */
router.post('/admin/user-country', verifyJWT, ADMIN, async (req: AuthenticatedRequest, res: Response) => {
  const { user_id, new_country, reason } = req.body || {};
  if (!user_id || !new_country || !reason || String(reason).trim().length < 3) {
    return res.status(400).json({ success: false, error: 'user_id, new_country, reason (≥3 car.) requis' });
  }
  const { data, error } = await supabaseAdmin.rpc('admin_change_user_country', {
    p_user_id: user_id, p_new_country: new_country, p_reason: reason,
  });
  if (error) return res.status(400).json({ success: false, error: error.message });
  return res.json({ success: true, result: data });
});

export default router;
