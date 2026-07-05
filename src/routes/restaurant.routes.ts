/**
 * 🍽️ SERVICE RESTAURANT — routes backend (Phase 1 : paiement atomique).
 *
 * - POST /order              → commande client. PRIX VALIDÉ CÔTÉ SERVEUR (jamais le client),
 *                              paiement atomique via RPC process_restaurant_order (idempotent).
 * - POST /order/:id/accept   → le restaurateur accepte (pending → preparing).
 * - POST /order/:id/status   → le restaurateur change le statut (preparing/ready/delivered/completed).
 * - POST /order/:id/cancel   → refus restaurateur OU annulation : remboursement atomique (RPC).
 *
 * Le restaurateur (professional_services.user_id) est vérifié pour les actions de gestion.
 * Temps réel : l'insert déclenche déjà le Supabase Realtime écouté par le Kanban restaurateur.
 */

import { Router, Response } from 'express';
import { randomUUID } from 'crypto';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { createAuthUserWithPhone } from '../services/authPhone.service.js';
import { logger } from '../config/logger.js';

const router = Router();

const DIGITAL_METHODS = ['orange_money', 'mobile_money', 'card'];

// ── MARKETPLACE : liste publique des restaurants (calcul service-role car tier d'abonnement et
//    commandes du jour sont en RLS, invisibles au visiteur). Renvoie des champs PUBLICS uniquement
//    (jamais le détail des abonnements). Ordre spec : promo → ouvert → plan → note → commandes. ──
const DAYS = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
const PLAN_TIER: Record<string, number> = { premium: 4, pro: 3, basic: 2, free: 1, gratuit: 1, gratuite: 1 };
const POPULAR_TODAY = 5;
const NEW_DAYS = 14;

function mkIsOpen(opening: any): boolean {
  if (!opening || typeof opening !== 'object') return true;
  const now = new Date();
  const h = opening[DAYS[now.getDay()]];
  if (!h || h.closed) return false;
  const hm = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`;
  return (!h.open || hm >= h.open) && (!h.close || hm <= h.close);
}
function mkPromoLabel(p: any): string {
  if (p.promo_type === 'percentage') return `-${p.value}%`;
  if (p.promo_type === 'free_delivery') return 'Livraison offerte';
  return '2 = 1';
}

router.get('/marketplace', async (_req, res: Response) => {
  try {
    const { data: st } = await supabaseAdmin.from('service_types').select('id').eq('code', 'restaurant').maybeSingle();
    if (!st?.id) { res.json({ success: true, restaurants: [] }); return; }

    const { data: svc } = await supabaseAdmin.from('professional_services')
      .select('id, user_id, business_name, logo_url, cover_image_url, rating, total_reviews, city, neighborhood, description, opening_hours, metadata, created_at, latitude, longitude')
      .eq('service_type_id', st.id).neq('status', 'suspended').limit(300);
    const services = svc || [];
    const ids = services.map((s) => s.id);
    const owners = [...new Set(services.map((s) => s.user_id).filter(Boolean))];
    if (ids.length === 0) { res.json({ success: true, restaurants: [] }); return; }

    const todayStart = new Date(); todayStart.setHours(0, 0, 0, 0);
    const [{ data: promos }, { data: items }, { data: subs }, { data: todayOrders }] = await Promise.all([
      supabaseAdmin.from('restaurant_promotions').select('professional_service_id, promo_type, value, start_time, end_time').in('professional_service_id', ids).eq('is_active', true),
      supabaseAdmin.from('restaurant_menu_items').select('professional_service_id, price, dietary_tags').in('professional_service_id', ids).eq('is_available', true),
      supabaseAdmin.from('service_subscriptions').select('user_id, current_period_end, service_plans:plan_id(name, priority_listing)').in('user_id', owners.length ? owners : ['—']).eq('status', 'active'),
      supabaseAdmin.from('restaurant_orders').select('professional_service_id, status').in('professional_service_id', ids).gte('created_at', todayStart.toISOString()),
    ]);

    const nowHM = `${String(new Date().getHours()).padStart(2, '0')}:${String(new Date().getMinutes()).padStart(2, '0')}`;
    const inWindow = (p: any) => (!p.start_time || nowHM >= p.start_time) && (!p.end_time || nowHM <= p.end_time);
    const promoByResto = new Map<string, any>(); const freeDeliv = new Set<string>();
    for (const p of promos || []) {
      if (!inWindow(p)) continue;
      if (p.promo_type === 'free_delivery') freeDeliv.add(p.professional_service_id);
      const cur = promoByResto.get(p.professional_service_id);
      if (!cur || (p.promo_type === 'percentage' && (cur.promo_type !== 'percentage' || p.value > cur.value))) promoByResto.set(p.professional_service_id, p);
    }
    const agg = new Map<string, { min: number | null; tags: Set<string>; count: number }>();
    for (const it of items || []) {
      const a = agg.get(it.professional_service_id) || { min: null, tags: new Set<string>(), count: 0 };
      a.count += 1; const pr = Number(it.price) || 0;
      if (pr > 0 && (a.min === null || pr < a.min)) a.min = pr;
      for (const tg of (it.dietary_tags || [])) a.tags.add(String(tg).toLowerCase());
      agg.set(it.professional_service_id, a);
    }
    const tierByOwner = new Map<string, number>();
    for (const s of subs || []) {
      if (s.current_period_end && new Date(s.current_period_end) < new Date()) continue;
      const name = String((s as any).service_plans?.name || '').toLowerCase();
      const tier = PLAN_TIER[name] ?? ((s as any).service_plans?.priority_listing ? 3 : 1);
      tierByOwner.set(s.user_id, Math.max(tierByOwner.get(s.user_id) || 0, tier));
    }
    const todayByResto = new Map<string, number>();
    for (const o of todayOrders || []) { if (o.status !== 'cancelled') todayByResto.set(o.professional_service_id, (todayByResto.get(o.professional_service_id) || 0) + 1); }

    const list = services.map((s) => {
      const a = agg.get(s.id); const promo = promoByResto.get(s.id); const meta = (s.metadata || {}) as any;
      const ordersToday = todayByResto.get(s.id) || 0;
      const createdAt = s.created_at ? new Date(s.created_at) : null;
      return {
        id: s.id, name: s.business_name || 'Restaurant', logo_url: s.logo_url,
        cover_image_url: s.cover_image_url || s.logo_url, cuisine: meta.cuisine || null,
        rating: Number(s.rating) || 0, total_reviews: Number(s.total_reviews) || 0,
        city: s.city, neighborhood: s.neighborhood, description: s.description,
        lat: s.latitude != null ? Number(s.latitude) : null, lng: s.longitude != null ? Number(s.longitude) : null,
        isOpen: mkIsOpen(s.opening_hours),
        isNew: !!createdAt && (Date.now() - createdAt.getTime()) < NEW_DAYS * 86400000,
        isPopular: ordersToday >= POPULAR_TODAY, ordersToday,
        planTier: tierByOwner.get(s.user_id) || 0,
        minPrice: a?.min ?? null, menuCount: a?.count ?? 0, dietaryTags: a ? [...a.tags] : [],
        promoLabel: promo ? mkPromoLabel(promo) : null, hasPromo: !!promo,
        freeDelivery: freeDeliv.has(s.id) || Number(meta.delivery_fee) === 0,
        deliveryFee: Number(meta.delivery_fee) || 0, etaBaseMinutes: Number(meta.delivery_eta_minutes) || 20,
      };
    });
    list.sort((x, y) =>
      Number(y.hasPromo) - Number(x.hasPromo) || Number(y.isOpen) - Number(x.isOpen) ||
      y.planTier - x.planTier || y.rating - x.rating || y.ordersToday - x.ordersToday);

    // Livreurs disponibles (en ligne) → facteur d'attente de l'ETA (calculé dans la page).
    let availableDrivers = 0;
    try {
      const { count } = await supabaseAdmin.from('drivers').select('*', { count: 'exact', head: true }).eq('is_online', true);
      availableDrivers = count || 0;
    } catch { /* table absente → 0 */ }

    res.json({ success: true, restaurants: list, availableDrivers });
  } catch (e: any) {
    logger.error(`[restaurant/marketplace] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur de chargement' });
  }
});

/** Valide les plats + calcule le montant CÔTÉ SERVEUR (jamais le client) + applique la promo active. */
/**
 * Calcule le prix CÔTÉ SERVEUR (jamais le client) : plats au prix DB + OPTIONS au prix DB (variants)
 * + meilleure PROMO active (percentage / bogo / free_delivery). Sécurité : le client n'envoie que des
 * identifiants (menu_item_id, group_id, option_id) ; tous les montants viennent de la base.
 */
// Tarif de livraison plateforme par km (au-delà du forfait de base du restaurant).
const DELIVERY_PRICE_PER_KM = 2000; // GNF/km

/** Distance à vol d'oiseau (km) entre deux points GPS (Haversine). */
function haversineKm(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371, toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1), dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

async function priceOrder(serviceId: string, items: any[], orderType?: string, clientLat?: number, clientLng?: number):
  Promise<{ ok: true; total: number; finalAmount: number; validated: any[]; promoDiscount: number; freeDelivery: boolean; deliveryFee: number; deliveryFeePaidBy: 'client' | 'restaurant' } | { ok: false; code: number; error: string }> {
  const ids = [...new Set(items.map((i: any) => String(i.menu_item_id)).filter(Boolean))];
  if (ids.length === 0) return { ok: false, code: 400, error: 'menu_item_id requis sur chaque item' };
  const { data: menu } = await supabaseAdmin.from('restaurant_menu_items')
    .select('id, name, price, is_available, professional_service_id, variants, stock_quantity').in('id', ids).eq('professional_service_id', serviceId);
  const byId = new Map((menu || []).map((m: any) => [m.id, m]));
  let total = 0; const validated: any[] = [];
  for (const it of items) {
    const m = byId.get(String(it.menu_item_id));
    if (!m) return { ok: false, code: 400, error: `Plat introuvable : ${it.menu_item_id}` };
    if (m.is_available === false) return { ok: false, code: 409, error: `Plat épuisé : ${m.name}` };
    const qty = Math.max(1, Math.min(50, Number(it.quantity) || 1));
    // STOCK : si suivi, refuser si pas assez de portions restantes.
    if (m.stock_quantity != null && Number(m.stock_quantity) < qty) {
      return { ok: false, code: 409, error: `Stock insuffisant pour ${m.name} (${m.stock_quantity} restant${Number(m.stock_quantity) > 1 ? 's' : ''})` };
    }

    // OPTIONS / suppléments : prix lu depuis variants.groups[].options[] (autoritaire serveur).
    const groups = Array.isArray(m.variants?.groups) ? m.variants.groups : [];
    const sel = Array.isArray(it.options) ? it.options : [];
    let optTotal = 0; const chosen: any[] = [];
    for (const s of sel) {
      const g = groups.find((g: any) => String(g.id) === String(s.group_id));
      const o = g?.options?.find((o: any) => String(o.id) === String(s.option_id));
      if (o) { const price = Number(o.price) || 0; optTotal += price; chosen.push({ group_id: g.id, group_name: g.name, option_id: o.id, name: o.name, price }); }
    }
    const lineUnit = Number(m.price) + optTotal;
    total += lineUnit * qty;
    validated.push({ menu_item_id: m.id, name: m.name, unit_price: Number(m.price), options_price: optTotal, options: chosen, quantity: qty });
  }
  if (total <= 0) return { ok: false, code: 400, error: 'Montant invalide' };

  // PROMO : meilleure réduction monétaire parmi les promos actives dans leur fenêtre horaire.
  let promoDiscount = 0; let freeDelivery = false;
  try {
    const { data: promos } = await supabaseAdmin.from('restaurant_promotions')
      .select('promo_type, value, start_time, end_time').eq('professional_service_id', serviceId).eq('is_active', true);
    const nowHM = new Date().toTimeString().slice(0, 8);
    const inWindow = (p: any) => (!p.start_time || nowHM >= p.start_time) && (!p.end_time || nowHM <= p.end_time);
    for (const p of (promos || []).filter(inWindow)) {
      if (p.promo_type === 'percentage') {
        promoDiscount = Math.max(promoDiscount, Math.round(total * (Number(p.value) || 0) / 100));
      } else if (p.promo_type === 'bogo') {
        // 2 achetés = 1 offert : par ligne, floor(qty/2) unités offertes (au prix du plat).
        const d = validated.reduce((s, it) => s + Math.floor(it.quantity / 2) * it.unit_price, 0);
        promoDiscount = Math.max(promoDiscount, d);
      } else if (p.promo_type === 'free_delivery') {
        // Livraison offerte si le montant atteint le seuil (value). Pas de frais modélisés → flag seulement.
        if (total >= (Number(p.value) || 0)) freeDelivery = true;
      }
    }
  } catch { /* pas de promo */ }

  // FRAIS DE LIVRAISON (modèle Uber/Meituan) — uniquement pour les commandes en livraison.
  // frais = forfait de base du resto + (prix/km × distance resto→client). Repli sur le base seul
  // si la position du client est inconnue. Si livraison offerte (promo), le RESTO absorbe les frais.
  let deliveryFee = 0;
  let deliveryFeePaidBy: 'client' | 'restaurant' = 'client';
  if (orderType === 'delivery') {
    try {
      const { data: svc } = await supabaseAdmin.from('professional_services')
        .select('latitude, longitude, metadata').eq('id', serviceId).maybeSingle();
      const base = Math.max(0, Number((svc?.metadata as any)?.delivery_fee) || 0);
      let distKm = 0;
      if (svc?.latitude && svc?.longitude && Number.isFinite(clientLat) && Number.isFinite(clientLng)) {
        distKm = haversineKm(Number(svc.latitude), Number(svc.longitude), Number(clientLat), Number(clientLng));
      }
      deliveryFee = Math.round(base + DELIVERY_PRICE_PER_KM * distKm);
      if (freeDelivery) deliveryFeePaidBy = 'restaurant'; // le client ne paie pas, le resto absorbe
    } catch { /* repli : aucun frais */ }
  }

  return { ok: true, total, finalAmount: Math.max(0, total - promoDiscount), validated, promoDiscount, freeDelivery, deliveryFee, deliveryFeePaidBy };
}

function mapErr(msg: string): { code: number; error: string } {
  if (/SOLDE_INSUFFISANT|insufficient|solde/i.test(msg)) return { code: 402, error: 'Solde insuffisant' };
  if (/RESTAURANT_INTROUVABLE/.test(msg)) return { code: 404, error: 'Restaurant introuvable' };
  if (/AUTO_COMMANDE/.test(msg)) return { code: 400, error: 'Vous ne pouvez pas commander dans votre propre restaurant' };
  if (/ANNULATION_IMPOSSIBLE/.test(msg)) return { code: 409, error: 'Cette commande ne peut plus être annulée' };
  if (/COMMANDE_INTROUVABLE/.test(msg)) return { code: 404, error: 'Commande introuvable' };
  if (/MONTANT_INVALIDE|TYPE_INVALIDE|IDEMPOTENCY/.test(msg)) return { code: 400, error: 'Requête invalide' };
  return { code: 400, error: msg };
}

/** Vérifie que l'utilisateur est le restaurateur propriétaire de la commande. */
async function loadOrderWithOwner(orderId: string): Promise<{ order: any; ownerId: string | null } | null> {
  const { data: order } = await supabaseAdmin.from('restaurant_orders').select('*').eq('id', orderId).maybeSingle();
  if (!order) return null;
  const { data: svc } = await supabaseAdmin.from('professional_services').select('user_id').eq('id', order.professional_service_id).maybeSingle();
  return { order, ownerId: svc?.user_id ?? null };
}

/**
 * Pont LIVRAISON : crée (idempotent) une `deliveries` pour une commande restaurant EN LIVRAISON,
 * afin que le système livreur existant (dispatch + GPS Ably + carte ClientDeliveryTracking) s'applique.
 * Non bloquant : si la table n'est pas encore migrée, on log et on continue.
 */
async function ensureRestaurantDelivery(order: any): Promise<void> {
  try {
    if (!order || order.order_type !== 'delivery') return;
    const { data: existing } = await supabaseAdmin.from('deliveries').select('id').eq('restaurant_order_id', order.id).maybeSingle();
    if (existing) return;
    const { data: svc } = await supabaseAdmin.from('professional_services')
      .select('business_name, phone, address, latitude, longitude').eq('id', order.professional_service_id).maybeSingle();
    // Contact client : depuis la commande, sinon depuis le profil (commandes wallet où la RPC ne stocke
    // pas le nom). Le livreur DOIT pouvoir joindre le client.
    let custName = order.customer_name || null;
    let custPhone = order.customer_phone || null;
    if ((!custName || !custPhone) && order.customer_user_id) {
      const { data: prof } = await supabaseAdmin.from('profiles')
        .select('full_name, first_name, last_name, phone').eq('id', order.customer_user_id).maybeSingle();
      const p = prof as any;
      custName = custName || p?.full_name || [p?.first_name, p?.last_name].filter(Boolean).join(' ').trim() || null;
      custPhone = custPhone || p?.phone || null;
    }
    const pickup_address = {
      name: svc?.business_name || 'Restaurant', phone: svc?.phone || null,
      address: svc?.address || null, lat: svc?.latitude ?? null, lng: svc?.longitude ?? null,
    };
    const delivery_address = {
      text: order.delivery_address || null, name: custName, phone: custPhone,
    };
    // Colonnes dénormalisées : indispensables pour que le livreur (courante/historique) et le CLIENT
    // (via client_id) voient la course dans le système livreur existant.
    const { error } = await supabaseAdmin.from('deliveries').insert({
      restaurant_order_id: order.id, status: 'pending', pickup_address, delivery_address, delivery_fee: 0,
      client_id: order.customer_user_id ?? null,
      vendor_name: svc?.business_name || 'Restaurant',
      customer_name: custName || 'Client',
      customer_phone: custPhone,
      package_type: 'restaurant',
    });
    if (error) { logger.warn(`[restaurant] création livraison ${order.id} : ${error.message}`); return; }
    logger.info(`[restaurant] livraison créée pour la commande ${order.id} (dispatch livreur)`);
  } catch (e: any) {
    logger.warn(`[restaurant] ensureRestaurantDelivery ${order?.id}: ${e?.message}`);
  }
}

/** POST /api/v2/restaurant/order — commande + paiement atomique (prix validé serveur). */
router.post('/order', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const b = req.body ?? {};
    const serviceId = String(b.professional_service_id || '');
    const orderType = String(b.order_type || '');
    const items = Array.isArray(b.items) ? b.items : [];
    if (!serviceId || items.length === 0) { res.status(400).json({ success: false, error: 'professional_service_id et items requis' }); return; }
    if (!['delivery', 'pickup', 'table', 'dine_in', 'takeaway'].includes(orderType)) { res.status(400).json({ success: false, error: 'order_type invalide' }); return; }

    // ── PRIX VALIDÉ CÔTÉ SERVEUR (plats + options + promos + frais de livraison), jamais le client. ──
    const clientLat = b.client_lat != null ? Number(b.client_lat) : undefined;
    const clientLng = b.client_lng != null ? Number(b.client_lng) : undefined;
    const priced = await priceOrder(serviceId, items, orderType, clientLat, clientLng);
    if (priced.ok === false) { res.status(priced.code).json({ success: false, error: priced.error }); return; }
    const { total, validated, promoDiscount, deliveryFee, deliveryFeePaidBy } = priced;
    const finalAmount = priced.finalAmount;
    if (finalAmount <= 0) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }

    const idem = String(b.idempotency_key || `resto:${userId}:${randomUUID()}`).slice(0, 120);
    const { data, error } = await supabaseAdmin.rpc('process_restaurant_order', {
      p_client_id: userId,
      p_professional_service_id: serviceId,
      p_amount: finalAmount,
      p_items: validated,
      p_order_type: orderType,
      p_table_number: b.table_number != null ? Number(b.table_number) : null,
      p_delivery_address: b.delivery_address || null,
      p_special_note: b.special_note || null,
      p_idempotency_key: idem,
      p_delivery_fee: deliveryFee,
      p_delivery_paid_by: deliveryFeePaidBy,
    });
    if (error) { const m = mapErr(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    // Décrémente le stock des plats vendus (suivis). Non bloquant : déjà validé par priceOrder.
    await supabaseAdmin.rpc('consume_menu_stock', { p_items: validated }).then(() => {}, () => {});
    res.json({ success: true, ...(data as object), subtotal: total, promo_discount: promoDiscount, delivery_fee: deliveryFee, charged: finalAmount + (deliveryFeePaidBy === 'client' ? deliveryFee : 0) });
  } catch (e: any) {
    logger.error(`[restaurant/order] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la commande' });
  }
});

/** POST /api/v2/restaurant/order/:id/accept — le restaurateur accepte (pending → preparing). */
router.post('/order/:id/accept', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const ctx = await loadOrderWithOwner(req.params.id);
    if (!ctx) { res.status(404).json({ success: false, error: 'Commande introuvable' }); return; }
    if (ctx.ownerId !== req.user!.id) { res.status(403).json({ success: false, error: 'Action réservée au restaurant' }); return; }
    if (ctx.order.status !== 'pending') { res.status(409).json({ success: false, error: 'Commande déjà traitée' }); return; }
    const prep = Number(req.body?.estimated_prep_minutes) || null;
    const { error } = await supabaseAdmin.from('restaurant_orders')
      .update({ status: 'preparing', accepted_at: new Date().toISOString(), started_preparing_at: new Date().toISOString(), estimated_prep_minutes: prep, updated_at: new Date().toISOString() })
      .eq('id', req.params.id);
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    // Commande en livraison acceptée → on crée la livraison pour le dispatch livreur (non bloquant).
    if (ctx.order.order_type === 'delivery') void ensureRestaurantDelivery(ctx.order);
    res.json({ success: true });
  } catch (e: any) {
    logger.error(`[restaurant/accept] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/** POST /api/v2/restaurant/order/:id/status — restaurateur : preparing → ready → delivered/completed. */
router.post('/order/:id/status', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const status = String(req.body?.status || '');
    if (!['preparing', 'ready', 'delivered', 'completed'].includes(status)) { res.status(400).json({ success: false, error: 'Statut invalide' }); return; }
    const ctx = await loadOrderWithOwner(req.params.id);
    if (!ctx) { res.status(404).json({ success: false, error: 'Commande introuvable' }); return; }
    if (ctx.ownerId !== req.user!.id) { res.status(403).json({ success: false, error: 'Action réservée au restaurant' }); return; }
    const patch: Record<string, any> = { status, updated_at: new Date().toISOString() };
    if (status === 'ready') patch.ready_at = new Date().toISOString();
    if (status === 'completed' || status === 'delivered') patch.completed_at = new Date().toISOString();
    const { error } = await supabaseAdmin.from('restaurant_orders').update(patch).eq('id', req.params.id);
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (e: any) {
    logger.error(`[restaurant/status] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/** POST /api/v2/restaurant/order/:id/cancel — refus restaurateur OU annulation client → remboursement atomique. */
router.post('/order/:id/cancel', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const ctx = await loadOrderWithOwner(req.params.id);
    if (!ctx) { res.status(404).json({ success: false, error: 'Commande introuvable' }); return; }
    const isOwner = ctx.ownerId === req.user!.id;
    const isClient = ctx.order.customer_user_id === req.user!.id;
    if (!isOwner && !isClient) { res.status(403).json({ success: false, error: 'Non autorisé' }); return; }
    const reason = String(req.body?.reason || (isOwner ? 'refus_restaurant' : 'annulation_client')).slice(0, 200);
    const { data, error } = await supabaseAdmin.rpc('cancel_restaurant_order', { p_order_id: req.params.id, p_reason: reason });
    if (error) { const m = mapErr(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[restaurant/cancel] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'annulation' });
  }
});

/**
 * POST /api/v2/restaurant/order/pay-mobile — commande EN PERSONNE (espèces / Orange Money / Mobile
 * Money / carte réglés au comptoir, à la table ou à la livraison). PUBLIC (pas de compte requis).
 * AUCUN paiement en ligne ni mouvement de wallet : commande en attente, encaissée en personne.
 * PRIX TOUJOURS VALIDÉ CÔTÉ SERVEUR (priceOrder). Contact client stocké (le livreur en a besoin).
 */
const IN_PERSON_METHODS = [...DIGITAL_METHODS, 'cash'];
router.post('/order/pay-mobile', async (req, res: Response) => {
  try {
    const b = req.body ?? {};
    const serviceId = String(b.professional_service_id || '');
    const method = String(b.payment_method || '');
    const items = Array.isArray(b.items) ? b.items : [];
    if (!serviceId || items.length === 0 || !IN_PERSON_METHODS.includes(method)) {
      res.status(400).json({ success: false, error: 'service, items et mode de paiement valides requis' });
      return;
    }

    // table_number est TEXTE (peut valoir « 2 », « A2 », « Terrasse-1 ») → on NE coerce PAS en nombre.
    const tableNum = b.table_number != null && String(b.table_number).trim() !== '' ? String(b.table_number).trim() : null;
    const otype = tableNum != null ? 'dine_in' : (['delivery', 'takeaway'].includes(b.order_type) ? b.order_type : 'takeaway');
    const customerName = String(b.customer_name || '').trim() || null;
    const customerPhone = String(b.customer_phone || '').trim() || null;

    // Validation par mode : la livraison exige adresse + contact (le livreur doit joindre le client).
    if (otype === 'delivery') {
      if (!String(b.delivery_address || '').trim()) { res.status(400).json({ success: false, error: 'Adresse de livraison requise' }); return; }
      if (!customerName || !customerPhone) { res.status(400).json({ success: false, error: 'Nom et téléphone requis pour la livraison' }); return; }
    } else if (otype === 'takeaway' && !customerName) {
      res.status(400).json({ success: false, error: 'Nom requis pour le retrait' }); return;
    }

    const priced = await priceOrder(serviceId, items);
    if (priced.ok === false) { res.status(priced.code).json({ success: false, error: priced.error }); return; }

    const orderNumber = tableNum != null
      ? `T${tableNum}-${Date.now().toString(36).slice(-4).toUpperCase()}`
      : `R-${Date.now().toString(36).toUpperCase()}`;

    const { data: order, error: oErr } = await supabaseAdmin.from('restaurant_orders').insert({
      professional_service_id: serviceId, order_number: orderNumber,
      order_type: otype,
      table_number: tableNum, source: tableNum != null ? 'qr_code' : 'online',
      delivery_address: otype === 'delivery' ? (b.delivery_address || null) : null,
      customer_name: customerName, customer_phone: customerPhone,
      customer_user_id: b.customer_user_id || null,
      items: priced.validated, subtotal: priced.total, tax: 0, total: priced.finalAmount,
      notes: b.special_note || null, status: 'pending', payment_status: 'pending', payment_method: method,
    }).select('id').maybeSingle();
    if (oErr || !order) { res.status(500).json({ success: false, error: 'Création de la commande impossible' }); return; }

    // Décrémente le stock des plats vendus (suivis). Non bloquant.
    await supabaseAdmin.rpc('consume_menu_stock', { p_items: priced.validated }).then(() => {}, () => {});

    res.json({ success: true, order_id: order.id, status: 'pending', amount: priced.finalAmount });
  } catch (e: any) {
    logger.error(`[restaurant/pay-mobile] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la commande' });
  }
});

// ============================================================================
// AGENTS DU RESTAURANT — le restaurateur (propriétaire du service) crée/gère ses agents
// et leurs permissions PAR MODULE. Toutes les routes vérifient la PROPRIÉTÉ du service.
// ============================================================================

const RESTAURANT_AGENT_PERMISSIONS = [
  'manage_orders', 'access_pos', 'manage_menu', 'manage_tables',
  'manage_reservations', 'manage_promotions', 'view_analytics', 'manage_settings', 'manage_media',
];

/** Le user courant est-il propriétaire de ce service ? */
async function isServiceOwner(serviceId: string, userId: string): Promise<boolean> {
  if (!serviceId) return false;
  const { data } = await supabaseAdmin.from('professional_services').select('user_id').eq('id', serviceId).maybeSingle();
  return !!data && data.user_id === userId;
}

/** Ne conserve que les clés de permissions connues, en booléen. */
function sanitizePermissions(input: any): Record<string, boolean> {
  const out: Record<string, boolean> = {};
  for (const k of RESTAURANT_AGENT_PERMISSIONS) out[k] = input?.[k] === true;
  return out;
}

/** GET /api/v2/restaurant/agents?service_id= — liste les agents du restaurant (propriétaire). */
router.get('/agents', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const serviceId = String(req.query.service_id || '');
    if (!(await isServiceOwner(serviceId, req.user!.id))) { res.status(403).json({ success: false, error: 'Service non autorisé' }); return; }
    const { data, error } = await supabaseAdmin.from('restaurant_agents')
      .select('id, name, email, phone, permissions, is_active, created_at')
      .eq('professional_service_id', serviceId).order('created_at', { ascending: false });
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true, data: data || [] });
  } catch (e: any) { logger.error(`[restaurant/agents GET] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

/** POST /api/v2/restaurant/agents — crée un agent (compte auth + ligne restaurant_agents). */
router.post('/agents', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const b = req.body ?? {};
    const serviceId = String(b.professional_service_id || '');
    if (!(await isServiceOwner(serviceId, req.user!.id))) { res.status(403).json({ success: false, error: 'Service non autorisé' }); return; }

    const name = String(b.name || '').trim();
    const email = String(b.email || '').trim().toLowerCase();
    const phone = String(b.phone || '').trim();
    const password = String(b.password || '');
    if (!name || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { res.status(400).json({ success: false, error: 'Nom et email valides requis' }); return; }
    if (password.length < 8) { res.status(400).json({ success: false, error: 'Mot de passe : 8 caractères minimum' }); return; }
    const permissions = sanitizePermissions(b.permissions);

    // Dédup email (agent existant OU compte auth existant).
    const { data: existing } = await supabaseAdmin.from('restaurant_agents').select('id').eq('email', email).maybeSingle();
    if (existing) { res.status(409).json({ success: false, error: 'Cet email est déjà agent' }); return; }
    const { data: authList } = await supabaseAdmin.auth.admin.listUsers();
    if (authList?.users?.some((u: any) => u.email === email)) { res.status(409).json({ success: false, error: 'Cet email a déjà un compte' }); return; }

    // 1) Compte auth — téléphone = identifiant (login email OU téléphone). Dégrade si doublon.
    const authCreate = await createAuthUserWithPhone({
      email, password, phone, countryCode: b.country_code,
      user_metadata: { full_name: name, phone, role: 'restaurant_agent' },
    });
    if (authCreate.error || !authCreate.user) { res.status(500).json({ success: false, error: authCreate.error?.message || 'Création compte échouée' }); return; }
    const authData = { user: authCreate.user };
    const phoneLoginAvailable = authCreate.phoneLoginAvailable;

    // 2) Ligne agent ; rollback du compte si échec.
    const { data: agentRow, error: agentError } = await supabaseAdmin.from('restaurant_agents').insert({
      professional_service_id: serviceId, user_id: authData.user.id, name, email, phone,
      agent_code: `RAG${Date.now().toString(36).toUpperCase()}${Math.random().toString(36).slice(2, 6).toUpperCase()}`,
      permissions, is_active: true,
    }).select('id').single();
    if (agentError) {
      await supabaseAdmin.auth.admin.deleteUser(authData.user.id);
      res.status(500).json({ success: false, error: agentError.message }); return;
    }

    // 3) Profil (best-effort).
    await supabaseAdmin.from('profiles').upsert({
      id: authData.user.id, email, first_name: name.split(' ')[0] || name,
      last_name: name.split(' ').slice(1).join(' ') || '', phone, role: 'restaurant_agent',
    }).then(() => {}, () => {});

    logger.info(`[restaurant/agents] agent ${agentRow.id} créé pour service ${serviceId} (phone_login=${phoneLoginAvailable})`);
    res.json({
      success: true,
      data: { id: agentRow.id, email, phone_login_available: phoneLoginAvailable },
      ...(phoneLoginAvailable ? {} : { message: 'Ce numéro est déjà lié à un autre compte — connexion par email uniquement.' }),
    });
  } catch (e: any) { logger.error(`[restaurant/agents POST] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

/** PATCH /api/v2/restaurant/agents/:id — met à jour permissions / statut (propriétaire). */
router.patch('/agents/:id', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const b = req.body ?? {};
    const { data: agent } = await supabaseAdmin.from('restaurant_agents').select('id, professional_service_id').eq('id', req.params.id).maybeSingle();
    if (!agent || !(await isServiceOwner(agent.professional_service_id, req.user!.id))) { res.status(403).json({ success: false, error: 'Agent non autorisé' }); return; }
    const patch: any = { updated_at: new Date().toISOString() };
    if (b.permissions !== undefined) patch.permissions = sanitizePermissions(b.permissions);
    if (b.is_active !== undefined) patch.is_active = b.is_active === true;
    if (typeof b.name === 'string') patch.name = b.name.trim();
    if (typeof b.phone === 'string') patch.phone = b.phone.trim();
    const { error } = await supabaseAdmin.from('restaurant_agents').update(patch).eq('id', req.params.id);
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (e: any) { logger.error(`[restaurant/agents PATCH] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

/** DELETE /api/v2/restaurant/agents/:id — supprime l'agent + son compte auth (propriétaire). */
router.delete('/agents/:id', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: agent } = await supabaseAdmin.from('restaurant_agents').select('id, professional_service_id, user_id').eq('id', req.params.id).maybeSingle();
    if (!agent || !(await isServiceOwner(agent.professional_service_id, req.user!.id))) { res.status(403).json({ success: false, error: 'Agent non autorisé' }); return; }
    await supabaseAdmin.from('restaurant_agents').delete().eq('id', req.params.id);
    if (agent.user_id) await supabaseAdmin.auth.admin.deleteUser(agent.user_id).catch(() => {});
    res.json({ success: true });
  } catch (e: any) { logger.error(`[restaurant/agents DELETE] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

export default router;
