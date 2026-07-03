/**
 * 📦 ORDERS ROUTES - Phase 6 (P0 Optimized)
 * 
 * P0 Optimization:
 *   - create_order_core RPC: 1 DB call instead of 4+N sequential calls
 *   - increment_stock_batch RPC: batch stock restore for cancellations
 *   - Redis cache for vendor lookups (TTL 5min)
 *   - Performance timing on POST /api/orders
 * 
 * Security preserved:
 *   - Zod validation
 *   - Idempotency guard
 *   - Anti-self-purchase
 *   - Rate limiting
 *   - Escrow systématique (inside create_order_core)
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { idempotencyGuard } from '../middlewares/idempotency.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { orderCreateRateLimit, orderManageRateLimit } from '../middlewares/routeRateLimiter.js';
import { cache } from '../config/redis.js';
import { loadServiceAccount, getPrivateBucketName, generateSignedUrl } from '../services/gcs.service.js';

// Preuve de livraison stockée sur GCS privé : le chemin est préfixé « gcs: » pour
// distinguer GCS (bucket privé, URL signée) de Supabase (héritage). URL signée 1h.
function signDeliveryProofUrl(storedPath: string | null): string | null {
  if (!storedPath) return null;
  if (storedPath.startsWith('gcs:')) {
    const sa = loadServiceAccount();
    if (!sa) return null;
    return generateSignedUrl(sa, getPrivateBucketName(), storedPath.slice(4), { method: 'GET', expiresInSeconds: 3600 });
  }
  return null; // chemins Supabase gérés séparément (createSignedUrl asynchrone)
}
import { createNotification, createNotifications } from '../services/notification.service.js';
import { buildOrderFinancialSummary } from '../services/marketplacePricing.service.js';
import { triggerAffiliateCommission } from '../services/commission.service.js';
import { recordAffiliateConversions, confirmAffiliateCommissions, cancelAffiliateCommissions } from './vendorAffiliate.routes.js';
import { z } from 'zod';

const router = Router();

// ==================== DEVISE DYNAMIQUE ====================

const COUNTRY_CURRENCY_MAP: Record<string, string> = {
  GN: 'GNF', CI: 'XOF', SN: 'XOF', ML: 'XOF', BF: 'XOF',
  NE: 'XOF', TG: 'XOF', BJ: 'XOF', CM: 'XAF', GA: 'XAF',
  CG: 'XAF', TD: 'XAF', CF: 'XAF', GQ: 'XAF', FR: 'EUR',
  US: 'USD', GB: 'GBP', MA: 'MAD', DZ: 'DZD', TN: 'TND',
  NG: 'NGN', GH: 'GHS', KE: 'KES', ZA: 'ZAR',
};
const DEFAULT_CURRENCY = 'GNF';

function resolveVendorCurrency(countryCode?: string | null): string {
  if (!countryCode) return DEFAULT_CURRENCY;
  return COUNTRY_CURRENCY_MAP[countryCode.toUpperCase()] || DEFAULT_CURRENCY;
}

// ==================== CACHED VENDOR LOOKUP ====================

/**
 * Resolve vendor with Redis cache (TTL 5min).
 * Eliminates repeated DB lookups on hot paths.
 */
async function getCachedVendor(vendorId: string): Promise<{
  id: string;
  business_name: string;
  user_id: string;
  country: string | null;
} | null> {
  const cacheKey = `vendor:${vendorId}`;

  // Try cache first
  const cached = await cache.get<{ id: string; business_name: string; user_id: string; country: string | null }>(cacheKey);
  if (cached) return cached;

  // Fallback to DB
  const { data: vendor } = await supabaseAdmin
    .from('vendors')
    .select('id, business_name, user_id, country')
    .eq('id', vendorId)
    .eq('is_active', true)
    .single();

  if (vendor) {
    await cache.set(cacheKey, vendor, 300); // 5min TTL
  }

  return vendor;
}

// ==================== VALIDATION SCHEMAS ====================

const OrderItemSchema = z.object({
  product_id: z.string().uuid('product_id invalide'),
  quantity: z.number().int().min(1, 'Quantité minimum 1').max(9999, 'Quantité trop élevée'),
  variant_id: z.string().uuid().nullish(),
});

const CreateOrderSchema = z.object({
  items: z.array(OrderItemSchema).min(1, 'Au moins un article requis').max(50, 'Maximum 50 articles'),
  vendor_id: z.string().uuid('vendor_id invalide'),
  shipping_address: z.object({
    full_name: z.string().trim().min(2).max(200),
    phone: z.string().trim().min(6).max(20),
    address_line: z.string().trim().min(5).max(500),
    city: z.string().trim().min(2).max(100),
    country: z.string().trim().min(2).max(100),
    postal_code: z.string().max(20).nullish(),
    notes: z.string().max(500).nullish(),
  }),
  payment_method: z.enum(['card', 'mobile_money', 'wallet', 'cash']),
  payment_intent_id: z.string().max(500).nullish(),
  payment_confirmed: z.boolean().nullish(),
  charged_amount: z.number().nonnegative().nullish(),
  order_metadata: z.record(z.string(), z.unknown()).nullish(),
  coupon_code: z.string().max(50).nullish(),
});

const CreateDigitalOrderSchema = z.object({
  vendor_id: z.string().uuid('vendor_id invalide'),
  product_id: z.string().uuid('product_id invalide'),
  product_name: z.string().trim().min(1).max(300),
  quantity: z.number().int().min(1).max(9999).default(1),
  unit_price: z.number().nonnegative(),
  total_amount: z.number().nonnegative(),
  currency: z.string().trim().min(3).max(10).default(DEFAULT_CURRENCY),
  payment_method: z.enum(['card', 'mobile_money', 'wallet', 'cash']),
  payment_intent_id: z.string().max(500).nullish(),
  purchase_record_id: z.string().uuid().nullish(),
  pricing_type: z.enum(['one_time', 'subscription', 'pay_what_you_want']).nullish(),
  subscription_interval: z.enum(['monthly', 'yearly', 'lifetime']).nullish(),
});

const ORDER_LIST_SELECT = `
  id,
  order_number,
  status,
  payment_status,
  payment_method,
  subtotal,
  total_amount,
  shipping_address,
  metadata,
  created_at,
  updated_at,
  vendor_id,
  payment_intent_id,
  vendors(business_name),
  order_items(
    product_id,
    quantity,
    unit_price,
    total_price,
    variant_id,
    products(name)
  )
`;

async function attachEscrowToOrders<T extends { id: string }>(orders: T[]) {
  if (!orders.length) {
    return orders.map(order => ({ ...order, escrow: null }));
  }

  const { data: escrows, error } = await supabaseAdmin
    .from('escrow_transactions')
    .select('id, order_id, status, amount, currency, auto_release_date, released_at, seller_confirmed_at')
    .in('order_id', orders.map(order => order.id))
    .order('created_at', { ascending: false });

  if (error) {
    logger.warn(`Unable to load escrow data for orders: ${error.message}`);
    return orders.map(order => ({ ...order, escrow: null }));
  }

  const escrowByOrderId = new Map<string, any>();
  for (const escrow of escrows || []) {
    if (!escrowByOrderId.has(escrow.order_id)) {
      escrowByOrderId.set(escrow.order_id, escrow);
    }
  }

  return orders.map(order => ({
    ...order,
    escrow: escrowByOrderId.get(order.id) || null,
  }));
}

async function getCustomerIdByUserId(userId: string) {
  const { data: customer, error } = await supabaseAdmin
    .from('customers')
    .select('id')
    .eq('user_id', userId)
    .maybeSingle();

  if (error) {
    throw error;
  }

  return customer?.id ?? null;
}

async function getOrCreateCustomerId(userId: string) {
  const existingCustomerId = await getCustomerIdByUserId(userId);
  if (existingCustomerId) {
    return existingCustomerId;
  }

  const { data: createdCustomer, error } = await supabaseAdmin
    .from('customers')
    .insert({ user_id: userId })
    .select('id')
    .single();

  if (error) {
    throw error;
  }

  return createdCustomer.id;
}

async function canUserManageBuyerOrder(orderId: string, userId: string, customerId?: string | null) {
  const orderLookup = await supabaseAdmin
    .from('orders')
    .select('id, status, customer_id, vendor_id, metadata')
    .eq('id', orderId)
    .single();

  let order = orderLookup.data;
  const error = orderLookup.error;

  if (error) {
    logger.warn(`Buyer order lookup failed for ${orderId} with extended select: ${error.message}`);

    const fallbackResult = await supabaseAdmin
      .from('orders')
      .select('id, status, customer_id')
      .eq('id', orderId)
      .maybeSingle();

    if (fallbackResult.error) {
      throw fallbackResult.error;
    }

    order = fallbackResult.data
      ? {
        ...fallbackResult.data,
        vendor_id: null,
        metadata: null,
      }
      : null;
  }

  if (!order) {
    return { order: null, isBuyer: false };
  }

  let isBuyer = Boolean(customerId) && order.customer_id === customerId;

  if (!isBuyer && order.customer_id) {
    const { data: customerOwner } = await supabaseAdmin
      .from('customers')
      .select('user_id')
      .eq('id', order.customer_id)
      .maybeSingle();

    isBuyer = customerOwner?.user_id === userId;
  }

  if (!isBuyer) {
    const { data: escrow } = await supabaseAdmin
      .from('escrow_transactions')
      .select('buyer_id')
      .eq('order_id', orderId)
      .maybeSingle();

    isBuyer = escrow?.buyer_id === userId;
  }

  return { order, isBuyer };
}

function normalizeCampaignContact(contact: string):
  | { contactType: 'email'; normalized: string; email: string; phone: null }
  | { contactType: 'phone'; normalized: string; email: null; phone: string } {
  const trimmed = contact.trim();
  const lowered = trimmed.toLowerCase();
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

  if (emailRegex.test(lowered)) {
    return {
      contactType: 'email',
      normalized: lowered,
      email: lowered,
      phone: null,
    };
  }

  const digitsOnly = trimmed.replace(/\D/g, '');
  if (digitsOnly.length < 8 || digitsOnly.length > 15) {
    throw new Error('Contact marketing invalide');
  }

  return {
    contactType: 'phone',
    normalized: digitsOnly,
    email: null,
    phone: trimmed.startsWith('+') ? `+${digitsOnly}` : digitsOnly,
  };
}

async function getOrderContactProfile(userId: string) {
  const { data, error } = await supabaseAdmin
    .from('profiles')
    .select('email, phone, first_name, last_name')
    .eq('id', userId)
    .maybeSingle();

  if (error) {
    throw error;
  }

  return data || null;
}

function buildDigitalShippingAddress(params: {
  productName: string;
  profile: Awaited<ReturnType<typeof getOrderContactProfile>>;
}) {
  const fullName = [params.profile?.first_name, params.profile?.last_name].filter(Boolean).join(' ') || params.profile?.email || 'Client 224Solutions';

  return {
    full_name: fullName,
    phone: params.profile?.phone || 'Non fourni',
    address_line: `Livraison numérique: ${params.productName}`,
    city: 'En ligne',
    country: 'Digital',
    postal_code: null,
    notes: 'Accès numérique délivré automatiquement après paiement',
  };
}

async function upsertVendorMarketingContact(params: {
  vendorId: string;
  rawContact: string;
  fullName?: string | null;
  orderTotal: number;
  purchasedAt: string;
}) {
  const normalizedContact = normalizeCampaignContact(params.rawContact);

  const { data: existingContact, error: loadError } = await supabaseAdmin
    .from('vendor_marketing_contacts')
    .select('id, source_type, total_orders, total_spent')
    .eq('vendor_id', params.vendorId)
    .eq('normalized_contact', normalizedContact.normalized)
    .maybeSingle();

  if (loadError) {
    throw loadError;
  }

  const sharedPayload = {
    full_name: params.fullName || null,
    linked_via: 'marketplace_order',
    source_type: existingContact?.source_type === 'physical' ? 'both' : 'digital',
    last_purchase_at: params.purchasedAt,
    is_active: true,
    marketing_email_opt_in: true,
    marketing_sms_opt_in: true,
  };

  if (existingContact?.id) {
    const { error: updateError } = await supabaseAdmin
      .from('vendor_marketing_contacts')
      .update({
        ...sharedPayload,
        email: normalizedContact.email,
        phone: normalizedContact.phone,
        total_orders: Number(existingContact.total_orders || 0) + 1,
        total_spent: Number(existingContact.total_spent || 0) + Number(params.orderTotal || 0),
      })
      .eq('id', existingContact.id);

    if (updateError) {
      throw updateError;
    }

    return;
  }

  const { error: insertError } = await supabaseAdmin
    .from('vendor_marketing_contacts')
    .insert({
      vendor_id: params.vendorId,
      contact_type: normalizedContact.contactType,
      normalized_contact: normalizedContact.normalized,
      email: normalizedContact.email,
      phone: normalizedContact.phone,
      total_orders: 1,
      total_spent: Number(params.orderTotal || 0),
      ...sharedPayload,
    });

  if (insertError) {
    throw insertError;
  }
}

async function syncOrderMarketingContacts(params: {
  vendorId: string;
  userId: string;
  shippingAddress: {
    full_name: string;
    phone: string;
  };
  orderTotal: number;
}) {
  const profile = await getOrderContactProfile(params.userId);
  const purchasedAt = new Date().toISOString();
  const fullName = [profile?.first_name, profile?.last_name].filter(Boolean).join(' ') || params.shippingAddress.full_name;
  const contacts = [profile?.email, profile?.phone, params.shippingAddress.phone]
    .filter((value): value is string => Boolean(value && value.trim() && value !== 'Non fourni'));

  for (const contact of new Set(contacts)) {
    try {
      await upsertVendorMarketingContact({
        vendorId: params.vendorId,
        rawContact: contact,
        fullName,
        orderTotal: params.orderTotal,
        purchasedAt,
      });
    } catch (error: any) {
      logger.warn(`Unable to sync order marketing contact for vendor ${params.vendorId}: ${error?.message || 'unknown error'}`);
    }
  }
}

// ==================== ROUTES ====================

/**
 * POST /api/orders
 * 
 * P0 OPTIMIZED: Uses create_order_core RPC for atomic single-call order creation.
 * 
 * BEFORE (Phase 4): 4+N sequential DB calls (~135ms+ for 3 items)
 *   1. SELECT vendor
 *   2. SELECT products (stock validation)
 *   3. INSERT order
 *   4. INSERT order_items
 *   5..5+N. RPC decrement_product_stock × N items
 *   6. INSERT escrow
 * 
 * AFTER (Phase 6): 2 DB calls (~35ms for 3 items)
 *   1. SELECT vendor (cached in Redis, ~0ms hit)
 *   2. RPC create_order_core (atomic: validate + insert + decrement + escrow)
 * 
 * Estimated improvement:
 *   - Latency: 135ms → 35ms (-74%)
 *   - DB calls: 6+N → 2 (-80%)
 *   - Orders/sec: 10-25 → 40-80 per instance (+3x)
 */
// Ordre : idempotence AVANT rate-limit → un rejeu (même Idempotency-Key) renvoie la réponse
// stockée sans consommer de quota ; seules les créations réellement nouvelles comptent.
router.post('/', verifyJWT, idempotencyGuard, orderCreateRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  const startTime = Date.now();

  try {
    const userId = req.user!.id;
    const customerId = await getOrCreateCustomerId(userId);

    // 1. Validation Zod (no DB call)
    const validation = CreateOrderSchema.safeParse(req.body);
    if (!validation.success) {
      res.status(400).json({
        success: false,
        error: 'Données de commande invalides',
        details: validation.error.errors.map(e => ({
          field: e.path.join('.'),
          message: e.message,
        })),
      });
      return;
    }

    const {
      items,
      vendor_id,
      shipping_address,
      payment_method,
      payment_intent_id,
      payment_confirmed,
      charged_amount,
      order_metadata,
    } = validation.data;

    // 2. Vendor lookup (Redis cached, TTL 5min)
    const vendor = await getCachedVendor(vendor_id);

    if (!vendor) {
      res.status(404).json({ success: false, error: 'Vendeur introuvable ou inactif' });
      return;
    }

    // Anti-auto-achat
    if (vendor.user_id === userId) {
      res.status(400).json({ success: false, error: 'Vous ne pouvez pas commander dans votre propre boutique' });
      return;
    }

    // 3. Resolve currency (no DB call)
    let currency = resolveVendorCurrency(vendor.country);

    // 3bis. Paiement WALLET → calculer le montant à débiter (avec FX) côté backend et le passer à
    //       create_order_core. Ainsi DÉBIT WALLET + commande + escrow = UNE SEULE transaction
    //       atomique (Phase 6 du RPC). Avant : ces params n'étaient pas transmis → le débit se
    //       faisait hors commande (Edge Function escrow séparée, non atomique) = risque
    //       « argent prélevé mais commande pas créée ». buildOrderFinancialSummary recalcule tout
    //       depuis la DB (prix produits + devise wallet acheteur + taux FX) — jamais le frontend.
    let walletDebitParams: {
      p_buyer_user_id: string | null;
      p_wallet_debit_amount: number;
      p_buyer_wallet_currency: string | null;
      p_exchange_rate_used: number | null;
      p_buyer_fee_amount: number;
      p_seller_commission_amount: number | null;
    } = {
      // 🔴 p_buyer_user_id = IDENTITÉ de l'acheteur (auth.uid()), PAS un paramètre wallet. Doit être
      // renseigné pour TOUS les moyens de paiement, sinon escrow.payer_id/buyer_id restaient NULL
      // (carte/mobile money/COD) → confirm-delivery « Non autorisé » + refund crédite un mauvais id
      // → « Échec de la libération/du remboursement ». Les RLS escrow exigent payer_id = auth.uid().
      p_buyer_user_id: userId, p_wallet_debit_amount: 0, p_buyer_wallet_currency: null,
      p_exchange_rate_used: null, p_buyer_fee_amount: 0, p_seller_commission_amount: null,
    };
    let buyerFeePercentForLog = 0;

    // COMMISSION VENDEUR — calculée pour TOUS les moyens de paiement (wallet, carte, mobile money,
    // paiement à la livraison) → stockée sur l'escrow et prélevée au vendeur à la libération.
    // 🔴 AVANT : seulement pour 'wallet' → les commandes carte/Orange/MTN/COD étaient libérées SANS
    //    commission (commission_amount NULL = fuite). buildOrderFinancialSummary recalcule depuis la
    //    DB (prix + type produit + devise), jamais le frontend.
    const summary = await buildOrderFinancialSummary({
      buyerUserId: userId,
      vendorId: vendor_id,
      items: items.map(i => ({ productId: i.product_id, quantity: i.quantity })),
      productType: 'physical',
    });
    // Devise réelle du prix produit → cohérente avec le subtotal calculé par le RPC.
    currency = summary.sellerCurrency;
    walletDebitParams.p_seller_commission_amount = summary.platformFeeAmount;

    if (payment_method === 'wallet') {
      // COMMISSION ACHETEUR (purchase_fee_percent, gérée par le PDG) — prélevée EN PLUS sur
      // l'acheteur et gardée par la plateforme. Calculée ICI (backend, autoritaire) sur le
      // montant payé converti, dans la devise du wallet acheteur, puis débitée + créditée au PDG
      // atomiquement par create_order_core. Avant : seulement affichée par le frontend → jamais
      // prélevée pour les paiements wallet.
      const NO_DEC = new Set(['GNF', 'XOF', 'XAF', 'JPY', 'KRW', 'VND', 'CLP']);
      let buyerFeePercent = 0;
      try {
        const { data: feeSetting } = await supabaseAdmin
          .from('system_settings').select('setting_value').eq('setting_key', 'purchase_fee_percent').maybeSingle();
        buyerFeePercent = Math.max(0, Math.min(50, Number(feeSetting?.setting_value ?? 0)));
      } catch { buyerFeePercent = 0; }
      const rawFee = summary.totalPaidAmount * (buyerFeePercent / 100);
      const buyerFee = NO_DEC.has(summary.buyerCurrency.toUpperCase())
        ? Math.round(rawFee) : Math.round(rawFee * 100) / 100;
      buyerFeePercentForLog = buyerFeePercent;

      walletDebitParams = {
        p_buyer_user_id: userId,
        p_wallet_debit_amount: summary.totalPaidAmount,
        p_buyer_wallet_currency: summary.buyerCurrency,
        // ⚠️ p_exchange_rate_used = null VOLONTAIREMENT : le montant à débiter est calculé ICI côté
        // backend (buildOrderFinancialSummary, taux autoritaire). Le contrôle ±5% du RPC sert à
        // détecter un taux FRONTEND périmé — non pertinent ici, et il rejetait à tort les commandes
        // cross-devise car le RPC recalcule le taux AVEC marge (écart = marge ≈ 5% → faux rejet).
        // Les vraies gardes (existence du taux, fraîcheur BCRG < 24h, âge) restent actives.
        p_exchange_rate_used: null,
        p_buyer_fee_amount: buyerFee,
        // COMMISSION VENDEUR centralisée (PLATFORM_FEE_RATES par type) → stockée sur l'escrow,
        // utilisée telle quelle à la libération (au lieu du 2,5 % codé en dur du RPC de release).
        p_seller_commission_amount: summary.platformFeeAmount,
      };
    }

    // 4. Generate order number (no DB call)
    const orderNumber = `ORD-${Date.now().toString(36).toUpperCase()}-${Math.random().toString(36).slice(2, 6).toUpperCase()}`;

    // 5. SINGLE ATOMIC RPC: create_order_core
    //    Validates stock + creates order + items + decrements stock + creates escrow
    //    (+ débit wallet atomique si payment_method='wallet') — 1 transaction PostgreSQL.
    const { data: result, error: rpcError } = await supabaseAdmin.rpc('create_order_core', {
      p_order_number: orderNumber,
      p_customer_id: customerId,
      p_vendor_id: vendor_id,
      p_vendor_user_id: vendor.user_id,
      p_payment_method: payment_method,
      p_payment_intent_id: payment_intent_id || null,
      p_shipping_address: shipping_address,
      p_currency: currency,
      p_items: items.map(i => ({
        product_id: i.product_id,
        quantity: i.quantity,
        variant_id: i.variant_id || null,
      })),
      p_auto_release_days: 14, // fenêtre de retour/remboursement de 14 jours avant libération escrow au vendeur
      ...walletDebitParams,
    });

    if (rpcError) {
      // IDEMPOTENCE PAIEMENT : si une commande existe DÉJÀ pour ce payment_intent (webhook
      // paiement rejoué → violation de l'index unique uniq_orders_payment_intent), la transaction
      // create_order_core a été annulée (AUCUN double-débit). On renvoie la commande existante.
      const isDupPaymentIntent = !!payment_intent_id &&
        ((rpcError as any).code === '23505' || /uniq_orders_payment_intent|duplicate key/i.test(rpcError.message || ''));
      if (isDupPaymentIntent) {
        const { data: existing } = await supabaseAdmin
          .from('orders')
          .select('id, order_number, payment_status')
          .eq('payment_intent_id', payment_intent_id)
          .maybeSingle();
        if (existing) {
          logger.warn(`create_order_core: commande déjà créée pour payment_intent ${payment_intent_id} → renvoi idempotent (${existing.id})`);
          res.status(200).json({ success: true, data: { order_id: existing.id, order_number: (existing as any).order_number, idempotent_replay: true } });
          return;
        }
      }
      logger.error(`create_order_core RPC error: ${rpcError.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors de la création de la commande' });
      return;
    }

    // Check RPC result
    if (!result || !result.success) {
      const errorMsg = result?.error || 'Erreur inconnue';
      logger.warn(`Order creation rejected: ${errorMsg}`);
      res.status(409).json({ success: false, error: errorMsg });
      return;
    }

    const effectiveChargedAmount = typeof charged_amount === 'number' && charged_amount >= 0
      ? charged_amount
      : Number(result.total_amount || 0);

    // orders.payment_status only supports pending|paid|failed|refunded.
    // wallet → débité atomiquement dans create_order_core, donc 'paid'.
    // cash → 'pending' (paiement à la livraison). card/mobile → 'paid' seulement si confirmé.
    const finalPaymentStatus: 'pending' | 'paid' = payment_method === 'cash'
      ? 'pending'
      : payment_method === 'wallet'
        ? 'paid'
        : payment_confirmed
          ? 'paid'
          : 'pending';

    const mergedOrderMetadata = {
      ...(payment_method === 'cash'
        ? {
          payment_type: 'cash_on_delivery',
          is_cod: true,
        }
        : {}),
      ...(payment_intent_id ? { external_payment_id: payment_intent_id } : {}),
      ...(order_metadata || {}),
    };

    // ⚠️ create_order_core a DÉJÀ committé atomiquement : commande + items + stock + escrow +
    // débit wallet. Les étapes ci-dessous ne sont que de la FINALISATION (réconciliation montant/
    // metadata). Un échec ici ne doit JAMAIS renvoyer une erreur au client : sinon il croit que la
    // commande a échoué alors que l'argent EST débité et la commande EXISTE → best-effort (log).
    const { error: orderUpdateError } = await supabaseAdmin
      .from('orders')
      .update({
        total_amount: effectiveChargedAmount,
        payment_status: finalPaymentStatus,
        metadata: mergedOrderMetadata,
      })
      .eq('id', result.order_id);

    if (orderUpdateError) {
      logger.error(`order finalization non bloquant (commande ${result.order_id} déjà créée): ${orderUpdateError.message}`);
    }

    // 📊 REVENUS PDG — logger la commission acheteur dans revenus_pdg pour TOUTES les commandes wallet
    // (avant : seul ProductPaymentModal le faisait côté frontend → seules les commandes "reco"
    // apparaissaient dans le tableau de revenus du PDG ; Payment.tsx ne loggait rien). Désormais
    // centralisé ici → cohérent pour tous les chemins. best-effort (ne bloque jamais la commande).
    if (payment_method === 'wallet' && walletDebitParams.p_buyer_fee_amount > 0) {
      try {
        await supabaseAdmin.rpc('record_pdg_revenue', {
          p_source_type: 'frais_achat_commande',
          p_amount: walletDebitParams.p_buyer_fee_amount,
          p_percentage: buyerFeePercentForLog,
          p_transaction_id: result.order_id,
          p_user_id: userId,
          p_metadata: {
            order_id: result.order_id,
            order_number: orderNumber,
            vendor_id,
            currency: walletDebitParams.p_buyer_wallet_currency,
            source: 'create_order_core_backend',
          },
        });
      } catch (revErr: any) {
        logger.warn(`record_pdg_revenue non bloquant (commande ${result.order_id}): ${revErr?.message || revErr}`);
      }
    }

    // 💰 COMMISSION AGENT (affiliation) sur l'achat marketplace — best-effort, non bloquant.
    // RÈGLE MÉTIER : l'agent CRÉATEUR du service (= le VENDEUR, et son parent), PAS l'acheteur,
    // touche un % des FRAIS DE TRANSACTION (la commission acheteur, ex. 2 %), et NON du montant
    // brut. Ex : achat 100 000, frais 2 % = 2 000 ; sous-agent 15 % des frais = 300, agent principal
    // 5 % = 100 (total 400 = 20 % des frais ; plateforme garde 80 %). Base = buyer fee converti en
    // GNF (credit_agent_commission raisonne en GNF). Anti-doublon par order_id + plafonné. Commande PAYÉE.
    // ⚠️ Réserve : pas de reprise sur annulation/remboursement (même profil que record_pdg_revenue).
    if (finalPaymentStatus === 'paid') {
      try {
        const feeAmount = Number(walletDebitParams.p_buyer_fee_amount || 0); // frais de transaction (devise acheteur)
        const feeCur = String(walletDebitParams.p_buyer_wallet_currency || currency || 'GNF').toUpperCase();
        let gnfFee = feeAmount;
        if (feeCur !== 'GNF' && feeAmount > 0) {
          const { data: fx } = await supabaseAdmin
            .from('currency_exchange_rates')
            .select('rate')
            .eq('from_currency', feeCur)
            .eq('to_currency', 'GNF')
            .order('created_at', { ascending: false })
            .limit(1)
            .maybeSingle();
          // Pas de taux dispo → on n'invente pas (commission ignorée plutôt que fausse).
          gnfFee = fx?.rate ? feeAmount * Number(fx.rate) : 0;
        }
        if (gnfFee > 0 && vendor.user_id) {
          // ✅ Agent du CRÉATEUR (le vendeur), et non de l'acheteur.
          await triggerAffiliateCommission(vendor.user_id, Math.round(gnfFee), 'achat_produit', result.order_id);
        }
      } catch (commErr: any) {
        logger.warn(`commission agent achat non bloquante (commande ${result.order_id}): ${commErr?.message || commErr}`);
      }
    }

    // (Affiliation = produits NUMÉRIQUES uniquement → gérée dans l'endpoint /digital, pas ici.)

    let escrowStatus = result.escrow_status as string;
    const { error: escrowUpdateError } = await supabaseAdmin
      .from('escrow_transactions')
      .update({
        // ⚠️ L'escrow tient le MONTANT PRODUIT (dû au vendeur), PAS le montant chargé : ce dernier
        // inclut la commission acheteur déjà prélevée séparément → sinon le vendeur est sur-payé de
        // la commission acheteur (fuite). create_order_core a déjà mis amount = subtotal ; on le garde.
        amount: Number((result as any).subtotal ?? effectiveChargedAmount),
        status: payment_method === 'cash' ? 'pending' : result.escrow_status,
        metadata: {
          ...(payment_method === 'cash'
            ? {
              payment_type: 'cash_on_delivery',
              note: 'Paiement à la livraison - escrow virtuel',
            }
            : {}),
          ...(payment_intent_id ? { external_payment_id: payment_intent_id } : {}),
          ...(order_metadata || {}),
        },
      })
      .eq('order_id', result.order_id);

    if (escrowUpdateError) {
      logger.error(`escrow finalization non bloquant (order ${result.order_id}): ${escrowUpdateError.message}`);
    }

    if (payment_method === 'cash') {
      escrowStatus = 'pending';
    }

    try {
      await syncOrderMarketingContacts({
        vendorId: vendor_id,
        userId,
        shippingAddress: {
          full_name: shipping_address.full_name,
          phone: shipping_address.phone,
        },
        orderTotal: effectiveChargedAmount,
      });
    } catch (e: any) {
      logger.warn(`syncOrderMarketingContacts non bloquant: ${e?.message || e}`);
    }

    // 🔔 Notifier le vendeur — strictement non bloquant (un échec ne casse pas la commande).
    try {
      await createNotification({
        userId: vendor.user_id,
        type: 'order',
        title: 'Nouvelle commande reçue',
        message: `Commande ${result.order_number} de ${shipping_address.full_name} — ${effectiveChargedAmount} ${currency}`,
        metadata: {
          order_id: result.order_id,
          order_number: result.order_number,
          total_amount: effectiveChargedAmount,
          currency,
          customer_name: shipping_address.full_name,
        },
      });
    } catch (e: any) {
      logger.warn(`createNotification non bloquant: ${e?.message || e}`);
    }

    // Performance logging
    const duration = Date.now() - startTime;
    logger.info(`✅ Order created: ${result.order_id} (${orderNumber}), vendor=${vendor_id}, total=${effectiveChargedAmount} ${currency}, escrow=${escrowStatus}, duration=${duration}ms, db_calls=2`);

    res.status(201).json({
      success: true,
      data: {
        order: {
          id: result.order_id,
          order_number: result.order_number,
          status: 'pending',
          payment_status: finalPaymentStatus,
          payment_method,
          subtotal: result.subtotal,
          total_amount: effectiveChargedAmount,
          currency: result.currency,
          shipping_address,
        },
        items: result.items,
        escrow_status: escrowStatus,
      },
      _perf: { duration_ms: duration, db_calls: 2 },
    });
  } catch (error: any) {
    const duration = Date.now() - startTime;
    logger.error(`Order creation error (${duration}ms): ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la création de la commande' });
  }
});

router.post('/digital', verifyJWT, idempotencyGuard, orderCreateRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const customerId = await getOrCreateCustomerId(userId);

    const validation = CreateDigitalOrderSchema.safeParse(req.body);
    if (!validation.success) {
      res.status(400).json({
        success: false,
        error: 'Données de commande digitale invalides',
        details: validation.error.errors.map(e => ({
          field: e.path.join('.'),
          message: e.message,
        })),
      });
      return;
    }

    const {
      vendor_id,
      product_id,
      product_name,
      quantity,
      unit_price,
      total_amount,
      currency,
      payment_method,
      payment_intent_id,
      purchase_record_id,
      pricing_type,
      subscription_interval,
    } = validation.data;

    const vendor = await getCachedVendor(vendor_id);
    if (!vendor) {
      res.status(404).json({ success: false, error: 'Vendeur introuvable ou inactif' });
      return;
    }

    if (vendor.user_id === userId) {
      res.status(400).json({ success: false, error: 'Vous ne pouvez pas commander dans votre propre boutique' });
      return;
    }

    let existingOrder: any = null;

    if (purchase_record_id) {
      const { data } = await supabaseAdmin
        .from('orders')
        .select(ORDER_LIST_SELECT)
        .eq('customer_id', customerId)
        .eq('vendor_id', vendor_id)
        .eq('metadata->>purchase_record_id', purchase_record_id)
        .maybeSingle();
      existingOrder = data || null;
    }

    if (!existingOrder && payment_intent_id) {
      const { data } = await supabaseAdmin
        .from('orders')
        .select(ORDER_LIST_SELECT)
        .eq('customer_id', customerId)
        .eq('vendor_id', vendor_id)
        .eq('payment_intent_id', payment_intent_id)
        .maybeSingle();
      existingOrder = data || null;
    }

    if (existingOrder) {
      const [enrichedExistingOrder] = await attachEscrowToOrders([existingOrder]);
      res.json({ success: true, data: enrichedExistingOrder });
      return;
    }

    const profile = await getOrderContactProfile(userId);
    const shippingAddress = buildDigitalShippingAddress({ productName: product_name, profile });
    const orderNumber = `DGT-${Date.now().toString(36).toUpperCase()}-${Math.random().toString(36).slice(2, 6).toUpperCase()}`;
    const isCashOnDelivery = payment_method === 'cash';

    const { data: insertedOrder, error: insertError } = await supabaseAdmin
      .from('orders')
      .insert({
        order_number: orderNumber,
        customer_id: customerId,
        vendor_id,
        full_name: shippingAddress.full_name,
        payment_method,
        payment_status: payment_method === 'cash' ? 'pending' : 'paid',
        payment_intent_id: payment_intent_id || null,
        subtotal: total_amount,
        total_amount,
        shipping_amount: 0,
        tax_amount: 0,
        discount_amount: 0,
        status: isCashOnDelivery ? 'pending' : 'confirmed',
        source: 'online',
        shipping_address: shippingAddress,
        metadata: {
          source_flow: 'digital_marketplace',
          item_type: 'digital_product',
          digital_product_id: product_id,
          digital_product_name: product_name,
          purchase_record_id: purchase_record_id || null,
          pricing_type: pricing_type || 'one_time',
          subscription_interval: subscription_interval || null,
          quantity,
          unit_price,
          currency,
          ...(isCashOnDelivery
            ? {
              is_cod: true,
              payment_type: 'cash_on_delivery',
              digital_delivery_status: 'awaiting_payment',
            }
            : {
              digital_delivery_status: 'access_granted',
            }),
        },
      })
      .select(ORDER_LIST_SELECT)
      .single();

    if (insertError) {
      logger.error(`Digital order mirror creation error: ${insertError.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors de la création de la commande digitale' });
      return;
    }

    await syncOrderMarketingContacts({
      vendorId: vendor_id,
      userId,
      shippingAddress: {
        full_name: shippingAddress.full_name,
        phone: shippingAddress.phone,
      },
      orderTotal: total_amount,
    });

    // 🔔 Notifier le vendeur de la nouvelle commande numérique (bouton notifications).
    await createNotification({
      userId: vendor.user_id,
      type: 'order',
      title: 'Nouvelle commande reçue',
      message: `Commande ${orderNumber} — ${product_name} (${total_amount} ${currency})`,
      metadata: {
        order_id: insertedOrder?.id,
        order_number: orderNumber,
        total_amount,
        currency,
        item_type: 'digital_product',
        product_name,
      },
    });

    // 🤝 AFFILIATION (produits numériques) : crée la commission `pending` si une attribution
    // valide existe (clic < 30j). La confirmation/paiement se fait après la fenêtre de protection
    // acheteur (job affiliate.confirm-digital). Best-effort, non bloquant.
    if (insertedOrder?.id) {
      await recordAffiliateConversions(insertedOrder.id, userId);
    }

    const [enrichedOrder] = await attachEscrowToOrders([insertedOrder]);

    res.status(201).json({ success: true, data: enrichedOrder });
  } catch (error: any) {
    logger.error(`Digital order creation error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la création de la commande digitale' });
  }
});

/**
 * GET /api/orders/:orderId
 */
router.get('/:orderId([0-9a-fA-F-]{36})', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { orderId } = req.params;
    const customerId = await getCustomerIdByUserId(userId);

    const { data: order, error } = await supabaseAdmin
      .from('orders')
      .select('*, order_items(*)')
      .eq('id', orderId)
      .single();

    if (error || !order) {
      res.status(404).json({ success: false, error: 'Commande non trouvée' });
      return;
    }

    const isCustomer = customerId !== null && order.customer_id === customerId;
    let isVendor = false;
    if (!isCustomer) {
      const { data: vendor } = await supabaseAdmin
        .from('vendors').select('id').eq('user_id', userId).eq('id', order.vendor_id).maybeSingle();
      isVendor = !!vendor;
    }

    if (!isCustomer && !isVendor) {
      res.status(403).json({ success: false, error: 'Accès non autorisé à cette commande' });
      return;
    }

    const { data: escrow } = await supabaseAdmin
      .from('escrow_transactions')
      .select('id, status, auto_release_date, released_at, seller_confirmed_at')
      .eq('order_id', orderId)
      .maybeSingle();

    res.json({ success: true, data: { ...order, escrow: escrow || null } });
  } catch (error: any) {
    logger.error(`Error fetching order ${req.params.orderId}: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * POST /api/orders/:orderId/cancel
 * P0 OPTIMIZED: Uses increment_stock_batch instead of per-product loop
 */
router.post('/:orderId([0-9a-fA-F-]{36})/cancel', verifyJWT, orderManageRateLimit, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { orderId } = req.params;
    const { reason } = req.body || {};
    const customerId = await getOrCreateCustomerId(userId);

    if (!reason || typeof reason !== 'string' || reason.trim().length < 3) {
      res.status(400).json({ success: false, error: 'Raison d\'annulation requise (min 3 caractères)' });
      return;
    }

    const { order, isBuyer } = await canUserManageBuyerOrder(orderId, userId, customerId);

    if (!order) {
      res.status(404).json({ success: false, error: 'Commande non trouvée' });
      return;
    }

    if (!isBuyer) {
      res.status(403).json({ success: false, error: 'Accès non autorisé à cette commande' });
      return;
    }

    if (order.status !== 'pending') {
      res.status(400).json({
        success: false,
        error: `Impossible d'annuler une commande en statut "${order.status}"`,
        details: { allowed_statuses: ['pending'] },
      });
      return;
    }

    const { data: escrow, error: escrowLookupError } = await supabaseAdmin
      .from('escrow_transactions')
      .select('seller_confirmed_at')
      .eq('order_id', orderId)
      .maybeSingle();

    if (escrowLookupError) {
      throw escrowLookupError;
    }

    if (escrow?.seller_confirmed_at) {
      res.status(400).json({
        success: false,
        error: 'Le vendeur a confirmé cette commande, annulation impossible. Ouvrez un litige.',
      });
      return;
    }

    // Restauration du stock : gérée atomiquement par le trigger DB
    // restore_stock_on_order_cancel (au passage status → 'cancelled'),
    // pour couvrir aussi les annulations hors backend. Pas de restore ici
    // (sinon double restauration).

    // Rembourser l'acheteur ATOMIQUEMENT (recrédit wallet + escrow 'refunded') via RPC.
    // Corrige le bug : avant, l'escrow passait 'refunded' SANS recréditer l'acheteur débité.
    const { data: refundRes, error: refundErr } = await supabaseAdmin.rpc('refund_order_escrow', { p_order_id: orderId });
    if (refundErr || (refundRes && (refundRes as any).success === false)) {
      logger.error(`Refund escrow failed (order ${orderId}): ${refundErr?.message || (refundRes as any)?.error}`);
      res.status(500).json({ success: false, error: 'Échec du remboursement. Réessayez ou contactez le support.' });
      return;
    }

    // 🤝 Commande annulée/remboursée → annuler les commissions d'affiliation pending.
    await cancelAffiliateCommissions(orderId);

    // Update order
    const cancellationReason = reason.trim();
    const baseOrderUpdate = {
      status: 'cancelled',
      updated_at: new Date().toISOString(),
      metadata: {
        ...(order.metadata && typeof order.metadata === 'object' ? order.metadata : {}),
        cancellation_reason: cancellationReason,
      },
    };

    let { data: updated, error } = await supabaseAdmin
      .from('orders')
      .update({
        ...baseOrderUpdate,
        cancellation_reason: cancellationReason,
      })
      .eq('id', orderId)
      .select('*')
      .single();

    if (error && /cancellation_reason/i.test(error.message || '')) {
      ({ data: updated, error } = await supabaseAdmin
        .from('orders')
        .update(baseOrderUpdate)
        .eq('id', orderId)
        .select('*')
        .single());
    }

    if (error) throw error;

    logger.info(`Order ${orderId} cancelled by buyer ${userId}: ${reason}`);
    res.json({ success: true, data: updated });
  } catch (error: any) {
    logger.error(`Order cancellation error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'annulation' });
  }
});

/**
 * POST /api/orders/:orderId/confirm-cod-delivery
 * L'ACHETEUR confirme la réception d'une commande payée à la livraison (COD / cash).
 * → marque la commande 'delivered' + clôture l'escrow virtuel COD. Aucun mouvement wallet (espèces).
 */
router.post('/:orderId([0-9a-fA-F-]{36})/confirm-cod-delivery', verifyJWT, orderManageRateLimit, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { orderId } = req.params;
    const customerId = await getOrCreateCustomerId(userId);

    const { order, isBuyer } = await canUserManageBuyerOrder(orderId, userId, customerId);
    if (!order) {
      res.status(404).json({ success: false, error: 'Commande non trouvée' });
      return;
    }
    if (!isBuyer) {
      res.status(403).json({ success: false, error: 'Accès non autorisé à cette commande' });
      return;
    }

    // payment_method n'est pas renvoyé par canUserManageBuyerOrder → on le récupère.
    const { data: fullOrder } = await supabaseAdmin
      .from('orders')
      .select('id, status, payment_method, vendor_id, order_number, metadata')
      .eq('id', orderId)
      .single();

    if (!fullOrder) {
      res.status(404).json({ success: false, error: 'Commande non trouvée' });
      return;
    }
    if (fullOrder.payment_method !== 'cash') {
      res.status(400).json({ success: false, error: 'Cette commande n\'est pas un paiement à la livraison' });
      return;
    }
    if (fullOrder.status === 'cancelled') {
      res.status(400).json({ success: false, error: 'Commande annulée' });
      return;
    }
    if (fullOrder.status === 'delivered') {
      res.json({ success: true, data: fullOrder });
      return;
    }

    const nowIso = new Date().toISOString();

    // Clôturer l'escrow virtuel COD (le vendeur a reçu les espèces en main propre).
    await supabaseAdmin
      .from('escrow_transactions')
      .update({ status: 'released', released_at: nowIso, seller_confirmed_at: nowIso })
      .eq('order_id', orderId);

    const { data: updated, error } = await supabaseAdmin
      .from('orders')
      .update({
        status: 'delivered',
        updated_at: nowIso,
        metadata: {
          ...(fullOrder.metadata && typeof fullOrder.metadata === 'object' ? fullOrder.metadata : {}),
          delivered_at: nowIso,
          cod_confirmed_by_buyer: true,
        },
      })
      .eq('id', orderId)
      .select('*')
      .single();

    if (error) throw error;

    // 🔔 Notifier le vendeur — non bloquant.
    try {
      const { data: vendor } = await supabaseAdmin.from('vendors').select('user_id').eq('id', fullOrder.vendor_id).maybeSingle();
      if (vendor?.user_id) {
        await createNotification({
          userId: vendor.user_id,
          type: 'order',
          title: `Commande ${fullOrder.order_number || ''}`.trim(),
          message: 'L\'acheteur a confirmé la réception (paiement à la livraison).',
          metadata: { order_id: orderId, order_number: fullOrder.order_number, status: 'delivered' },
        });
      }
    } catch (e: any) {
      logger.warn(`COD confirm notification non bloquant: ${e?.message || e}`);
    }

    logger.info(`COD order ${orderId} confirmed delivered by buyer ${userId}`);
    res.json({ success: true, data: updated });
  } catch (error: any) {
    logger.error(`COD confirm error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la confirmation de livraison' });
  }
});

/**
 * POST /api/orders/:orderId/confirm-delivery
 * L'ACHETEUR confirme la réception d'une commande payée au WALLET/escrow.
 * → libère l'escrow vers le vendeur (net) + commission plateforme, ATOMIQUEMENT via le RPC
 *   confirm_delivery_and_release_escrow(p_escrow_id, p_customer_id). Corrige le maillon manquant :
 *   avant, seul le COD avait une confirmation, et le PATCH 'delivered' ne payait pas le vendeur.
 */
router.post('/:orderId([0-9a-fA-F-]{36})/confirm-delivery', verifyJWT, orderManageRateLimit, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { orderId } = req.params;
    const customerId = await getOrCreateCustomerId(userId);

    const { order, isBuyer } = await canUserManageBuyerOrder(orderId, userId, customerId);
    if (!order) { res.status(404).json({ success: false, error: 'Commande non trouvée' }); return; }
    if (!isBuyer) { res.status(403).json({ success: false, error: 'Accès non autorisé à cette commande' }); return; }

    const { data: fullOrder } = await supabaseAdmin
      .from('orders')
      .select('id, status, payment_method, vendor_id, order_number, metadata')
      .eq('id', orderId)
      .single();
    if (!fullOrder) { res.status(404).json({ success: false, error: 'Commande non trouvée' }); return; }
    if (fullOrder.payment_method === 'cash') {
      res.status(400).json({ success: false, error: 'Paiement à la livraison : utilisez la confirmation COD.' });
      return;
    }
    if (fullOrder.status === 'cancelled') {
      res.status(400).json({ success: false, error: 'Commande annulée' });
      return;
    }

    const { data: escrow } = await supabaseAdmin
      .from('escrow_transactions')
      .select('id, status')
      .eq('order_id', orderId)
      .maybeSingle();
    if (!escrow) { res.status(400).json({ success: false, error: 'Aucun escrow associé à cette commande' }); return; }

    // Idempotent : si déjà libéré/remboursé, on ne refait rien.
    if (!['held', 'pending'].includes(String(escrow.status))) {
      res.json({ success: true, data: fullOrder, already_released: true });
      return;
    }

    // Libération atomique vers le vendeur (crédit net + commission plateforme).
    const { error: relErr } = await supabaseAdmin.rpc('confirm_delivery_and_release_escrow', {
      p_escrow_id: escrow.id,
      p_customer_id: userId,
      p_notes: 'Réception confirmée par l\'acheteur',
    });
    if (relErr) {
      logger.error(`confirm-delivery release failed (order ${orderId}): ${relErr.message}`);
      res.status(500).json({ success: false, error: 'Échec de la libération des fonds. Réessayez ou contactez le support.' });
      return;
    }

    // 🤝 Escrow libéré → confirmer + payer les commissions d'affiliation de cette commande.
    await confirmAffiliateCommissions(orderId);

    const nowIso = new Date().toISOString();
    const { data: updated } = await supabaseAdmin
      .from('orders')
      .update({
        status: 'delivered',
        updated_at: nowIso,
        delivery_confirmed_at: nowIso, // ancre la rétention : purge de la preuve 7 j après
        metadata: {
          ...(fullOrder.metadata && typeof fullOrder.metadata === 'object' ? fullOrder.metadata : {}),
          delivered_at: nowIso,
          buyer_confirmed_delivery: true,
        },
      })
      .eq('id', orderId)
      .select('*')
      .single();

    // 🔔 Notifier le vendeur (non bloquant).
    try {
      const { data: vendor } = await supabaseAdmin.from('vendors').select('user_id').eq('id', fullOrder.vendor_id).maybeSingle();
      if (vendor?.user_id) {
        await createNotification({
          userId: vendor.user_id,
          type: 'order',
          title: `Commande ${fullOrder.order_number || ''}`.trim(),
          message: 'L\'acheteur a confirmé la réception. Les fonds ont été libérés sur votre wallet.',
          metadata: { order_id: orderId, order_number: fullOrder.order_number, status: 'delivered' },
        });
      }
    } catch (e: any) {
      logger.warn(`confirm-delivery notification non bloquant: ${e?.message || e}`);
    }

    logger.info(`Order ${orderId} delivery confirmed by buyer ${userId} → escrow released`);
    res.json({ success: true, data: updated, released: true });
  } catch (error: any) {
    logger.error(`confirm-delivery error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la confirmation de réception' });
  }
});

/**
 * POST /api/orders/:orderId/delivery-proof — le vendeur enregistre les chemins
 * (fichiers déjà uploadés dans le bucket privé delivery-proofs). Réservé au vendeur.
 */
router.post('/:orderId([0-9a-fA-F-]{36})/delivery-proof', verifyJWT, orderManageRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const orderId = req.params.orderId;
    const userId = req.user!.id;
    const { photo_path, video_path, storage } = req.body || {};
    if (!photo_path || typeof photo_path !== 'string') {
      res.status(400).json({ success: false, error: 'photo_path requis' }); return;
    }
    const { data: order } = await supabaseAdmin
      .from('orders').select('id, vendor_id').eq('id', orderId).maybeSingle();
    if (!order) { res.status(404).json({ success: false, error: 'Commande introuvable' }); return; }
    const { data: vendor } = await supabaseAdmin
      .from('vendors').select('id').eq('id', order.vendor_id).eq('user_id', userId).maybeSingle();
    if (!vendor) { res.status(403).json({ success: false, error: 'Action réservée au vendeur' }); return; }
    // Anti-IDOR : les chemins DOIVENT être scopés à cette commande.
    if (!photo_path.startsWith(`${orderId}/`) || (video_path && !String(video_path).startsWith(`${orderId}/`))) {
      res.status(400).json({ success: false, error: 'Chemin de preuve invalide' }); return;
    }
    // Preuve stockée sur GCS privé → marquer le chemin « gcs: » (sinon Supabase, héritage).
    const useGcs = storage === 'gcs';
    const storedPhoto = useGcs ? `gcs:${photo_path}` : photo_path;
    const storedVideo = video_path ? (useGcs ? `gcs:${video_path}` : video_path) : null;
    const { error } = await supabaseAdmin.from('orders').update({
      delivery_proof_photo_path: storedPhoto,
      delivery_proof_video_path: storedVideo,
      delivery_proof_uploaded_at: new Date().toISOString(),
    } as any).eq('id', orderId);
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    logger.info(`Delivery proof attached to order ${orderId} by vendor ${vendor.id}`);
    res.json({ success: true });
  } catch (e: any) {
    logger.error(`[delivery-proof] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

/**
 * GET /api/orders/:orderId/delivery-proof — URLs signées (1h) photo + vidéo.
 * Accessible au vendeur ET au client de la commande. Renvoie purged=true si purgée.
 */
router.get('/:orderId([0-9a-fA-F-]{36})/delivery-proof', verifyJWT, orderManageRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const orderId = req.params.orderId;
    const userId = req.user!.id;
    const { data: order } = await supabaseAdmin
      .from('orders')
      .select('id, vendor_id, customer_id, delivery_proof_photo_path, delivery_proof_video_path, delivery_proof_purged_at')
      .eq('id', orderId).maybeSingle();
    if (!order) { res.status(404).json({ success: false, error: 'Commande introuvable' }); return; }

    const o = order as any;
    const isCustomer = o.customer_id === userId;
    let isVendor = false;
    if (!isCustomer) {
      const { data: vendor } = await supabaseAdmin
        .from('vendors').select('id').eq('id', o.vendor_id).eq('user_id', userId).maybeSingle();
      isVendor = !!vendor;
    }
    if (!isCustomer && !isVendor) { res.status(403).json({ success: false, error: 'Accès refusé' }); return; }

    if (o.delivery_proof_purged_at) {
      res.json({ success: true, purged: true, photo_url: null, video_url: null }); return;
    }
    let photo_url: string | null = null, video_url: string | null = null;
    if (o.delivery_proof_photo_path) {
      if (String(o.delivery_proof_photo_path).startsWith('gcs:')) {
        photo_url = signDeliveryProofUrl(o.delivery_proof_photo_path);
      } else {
        const { data } = await supabaseAdmin.storage.from('delivery-proofs')
          .createSignedUrl(o.delivery_proof_photo_path, 3600);
        photo_url = data?.signedUrl || null;
      }
    }
    if (o.delivery_proof_video_path) {
      if (String(o.delivery_proof_video_path).startsWith('gcs:')) {
        video_url = signDeliveryProofUrl(o.delivery_proof_video_path);
      } else {
        const { data } = await supabaseAdmin.storage.from('delivery-proofs')
          .createSignedUrl(o.delivery_proof_video_path, 3600);
        video_url = data?.signedUrl || null;
      }
    }
    res.json({ success: true, purged: false, photo_url, video_url });
  } catch (e: any) {
    logger.error(`[delivery-proof GET] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

/**
 * POST /api/orders/:orderId/request-refund
 * Ouvre un litige de remboursement (remplace l'Edge Function 'request-refund' — pas de mouvement
 * d'argent ici, juste la création du litige + notification vendeur). L'argent ne bouge qu'à la
 * résolution/annulation (refund_order_escrow, qui convertit).
 */
router.post('/:orderId([0-9a-fA-F-]{36})/request-refund', verifyJWT, orderManageRateLimit, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { orderId } = req.params;
    const { reason, requested_amount, evidence_text } = req.body || {};
    if (!reason || typeof reason !== 'string') {
      res.status(400).json({ success: false, error: 'Motif requis' });
      return;
    }

    const customerId = await getOrCreateCustomerId(userId);
    const { order, isBuyer } = await canUserManageBuyerOrder(orderId, userId, customerId);
    if (!order) { res.status(404).json({ success: false, error: 'Commande non trouvée' }); return; }
    if (!isBuyer) { res.status(403).json({ success: false, error: 'Non autorisé pour cette commande' }); return; }

    const { data: escrow } = await supabaseAdmin
      .from('escrow_transactions')
      .select('id, amount, status')
      .eq('order_id', orderId)
      .maybeSingle();
    if (!escrow) { res.status(404).json({ success: false, error: 'Aucun escrow pour cette commande' }); return; }
    if (!['pending', 'held', 'released'].includes(String(escrow.status))) {
      res.status(400).json({ success: false, error: 'Cette commande ne peut plus être remboursée' });
      return;
    }

    // Litige déjà ouvert ? On lit `escrow_disputes` — LA table reliée à l'interface
    // PDG (PDGEscrowDisputes) ET à la résolution réelle (Edge resolve-dispute).
    const { data: existingRows } = await supabaseAdmin
      .from('escrow_disputes')
      .select('id, status')
      .eq('escrow_id', escrow.id)
      .neq('status', 'resolved')
      .limit(1);
    if (existingRows && existingRows.length > 0) {
      res.status(400).json({ success: false, error: 'Un litige est déjà en cours pour cette commande' });
      return;
    }

    // ⚠️ CORRECTIF : on crée le litige dans `escrow_disputes` (et NON `disputes`,
    // qui était une table orpheline jamais lue par le PDG → demande perdue +
    // contraintes CHECK incompatibles → "Erreur lors de la création du litige").
    // Ainsi : la demande apparaît côté PDG, qui peut la résoudre ("refund_to_buyer"
    // → escrow 'refunded' = remboursement réel). L'argent ne bouge qu'à la résolution.
    const { data: dispute, error: disputeErr } = await supabaseAdmin
      .from('escrow_disputes')
      .insert({
        escrow_id: escrow.id,
        initiator_user_id: userId,
        initiator_role: 'buyer',
        reason: `${reason}${evidence_text ? '\n\nDétails: ' + evidence_text : ''}`,
        status: 'open',
        metadata: {
          order_id: orderId,
          client_id: (order as any).customer_id,
          vendor_id: (order as any).vendor_id,
          request_type: 'full_refund',
          requested_amount: typeof requested_amount === 'number' && requested_amount > 0 ? requested_amount : escrow.amount,
          evidence_text: evidence_text || null,
        },
      })
      .select('id')
      .single();
    if (disputeErr || !dispute) {
      // Garde atomique : l'index unique partiel (uniq_open_escrow_dispute_per_escrow)
      // empêche 2 litiges non résolus sur le même escrow (double-clic / concurrence).
      if ((disputeErr as any)?.code === '23505') {
        res.status(400).json({ success: false, error: 'Un litige est déjà en cours pour cette commande' });
        return;
      }
      logger.error(`request-refund escrow_dispute creation failed (order ${orderId}): ${disputeErr?.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors de la création du litige' });
      return;
    }

    // 1er message du fil = la raison détaillée du CLIENT (lié au litige escrow_disputes).
    // Best-effort : ne bloque pas si la colonne escrow_dispute_id n'est pas encore en place.
    try {
      await supabaseAdmin.from('dispute_messages').insert({
        escrow_dispute_id: dispute.id,
        sender_id: userId,
        sender_type: 'client',
        message: `${reason}${evidence_text ? '\n\n' + evidence_text : ''}`,
      });
    } catch (e: any) {
      logger.warn(`request-refund client message non bloquant: ${e?.message || e}`);
    }

    // Notifier SIMULTANÉMENT les 3 parties du litige : client (confirmation),
    // vendeur (donner sa version), PDG/admins (arbitrer). Non bloquant.
    try {
      const orderNo = (order as any).order_number || orderId.slice(0, 8);
      const meta = { order_id: orderId, escrow_dispute_id: dispute.id, escrow_id: escrow.id };
      const notifs: any[] = [
        {
          userId,
          type: 'dispute',
          title: 'Litige ouvert',
          message: `Votre demande de remboursement (commande ${orderNo}) a ouvert un litige. Le vendeur et notre équipe ont été notifiés ; vous serez informé de la décision.`,
          metadata: { ...meta, party: 'client' },
        },
      ];
      const { data: vendor } = await supabaseAdmin.from('vendors').select('user_id').eq('id', (order as any).vendor_id).maybeSingle();
      if (vendor?.user_id) {
        notifs.push({
          userId: vendor.user_id,
          type: 'dispute',
          title: 'Litige : remboursement demandé',
          message: `Le client conteste la commande ${orderNo} (motif : ${reason}). Donnez votre version des faits dans le litige.`,
          metadata: { ...meta, party: 'vendor' },
        });
      }
      // PDG / admins : tous notifiés en même temps
      const { data: admins } = await supabaseAdmin
        .from('profiles')
        .select('id')
        .in('role', ['admin', 'pdg', 'ceo']);
      for (const a of (admins || [])) {
        notifs.push({
          userId: (a as any).id,
          type: 'dispute',
          title: 'Nouveau litige à arbitrer',
          message: `Demande de remboursement — commande ${orderNo}. Motif : ${reason}.`,
          metadata: { ...meta, party: 'pdg' },
        });
      }
      await createNotifications(notifs);
    } catch (e: any) {
      logger.warn(`request-refund notification non bloquant: ${e?.message || e}`);
    }

    logger.info(`Refund dispute opened for order ${orderId} by buyer ${userId} (dispute ${dispute.id})`);
    res.json({ success: true, dispute_id: dispute.id, message: 'Demande de remboursement envoyée' });
  } catch (error: any) {
    logger.error(`request-refund error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la demande de remboursement' });
  }
});

/**
 * GET /api/orders/mine
 */
router.get('/mine', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const customerId = await getCustomerIdByUserId(userId);
    const limit = Math.min(parseInt(req.query.limit as string) || 20, 100);
    const offset = parseInt(req.query.offset as string) || 0;
    const status = req.query.status as string;

    if (!customerId) {
      res.json({ success: true, data: [], meta: { limit, offset, total: 0 } });
      return;
    }

    let query = supabaseAdmin
      .from('orders')
      .select(ORDER_LIST_SELECT, { count: 'exact' })
      .eq('customer_id', customerId)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (status) query = query.eq('status', status);

    const { data, error, count } = await query;
    if (error) throw error;

    const enrichedOrders = await attachEscrowToOrders(data || []);

    res.json({ success: true, data: enrichedOrders, meta: { limit, offset, total: count || 0 } });
  } catch (error: any) {
    logger.error(`Error fetching client orders: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * GET /api/orders/vendor
 */
router.get('/vendor', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { data: vendor } = await supabaseAdmin
      .from('vendors').select('id').eq('user_id', userId).maybeSingle();

    if (!vendor) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const limit = Math.min(parseInt(req.query.limit as string) || 20, 100);
    const offset = parseInt(req.query.offset as string) || 0;
    const status = req.query.status as string;

    let query = supabaseAdmin
      .from('orders')
      .select(ORDER_LIST_SELECT, { count: 'exact' })
      .eq('vendor_id', vendor.id)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (status) query = query.eq('status', status);

    const { data, error, count } = await query;
    if (error) throw error;

    const enrichedOrders = await attachEscrowToOrders(data || []);

    res.json({ success: true, data: enrichedOrders, meta: { limit, offset, total: count || 0 } });
  } catch (error: any) {
    logger.error(`Error fetching vendor orders: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * PATCH /api/orders/:orderId/status
 * P0 OPTIMIZED: Uses increment_stock_batch for vendor cancellations
 */
router.patch('/:orderId([0-9a-fA-F-]{36})/status', verifyJWT, orderManageRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { orderId } = req.params;

    const statusSchema = z.object({
      status: z.enum(['confirmed', 'preparing', 'ready', 'shipped', 'in_transit', 'delivered', 'cancelled']),
      tracking_number: z.string().max(100).nullish(),
      cancellation_reason: z.string().max(500).nullish(),
    });

    const validation = statusSchema.safeParse(req.body);
    if (!validation.success) {
      res.status(400).json({ success: false, error: 'Données invalides', details: validation.error.errors });
      return;
    }

    const requestedStatus = validation.data.status;
    const status = requestedStatus === 'shipped' ? 'in_transit' : requestedStatus;
    const { tracking_number, cancellation_reason } = validation.data;

    const { data: vendor } = await supabaseAdmin
      .from('vendors').select('id').eq('user_id', userId).maybeSingle();

    if (!vendor) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const { data: order } = await supabaseAdmin
      .from('orders')
      .select('id, status, vendor_id, customer_id, order_number')
      .eq('id', orderId)
      .eq('vendor_id', vendor.id)
      .single();

    if (!order) {
      res.status(404).json({ success: false, error: 'Commande non trouvée' });
      return;
    }

    const allowedTransitions: Record<string, string[]> = {
      pending: ['confirmed', 'cancelled'],
      confirmed: ['preparing', 'cancelled'],
      preparing: ['ready', 'cancelled'],
      ready: ['in_transit', 'cancelled'],
      shipped: ['delivered'],
      in_transit: ['delivered'],
      delivered: [],
      cancelled: [],
    };

    const allowed = allowedTransitions[order.status] || [];
    if (!allowed.includes(status)) {
      res.status(400).json({
        success: false,
        error: `Transition "${order.status}" → "${status}" non autorisée`,
        allowed_transitions: allowed,
      });
      return;
    }

    if (status === 'cancelled' && !cancellation_reason) {
      res.status(400).json({ success: false, error: 'Raison d\'annulation requise' });
      return;
    }

    const updates: Record<string, any> = { status, updated_at: new Date().toISOString() };
    // Note: tracking_number, cancellation_reason, seller_confirmed_at, delivered_at
    // don't exist on orders table — store in metadata instead
    if (tracking_number || cancellation_reason) {
      updates.metadata = {
        ...(tracking_number ? { tracking_number } : {}),
        ...(cancellation_reason ? { cancellation_reason } : {}),
      };
    }

    if (status === 'confirmed') {
      await supabaseAdmin
        .from('escrow_transactions')
        .update({
          seller_confirmed_at: new Date().toISOString(),
          auto_release_date: new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString(), // fenêtre retour 14j
        })
        .eq('order_id', orderId);
    }

    if (status === 'delivered') {
      updates.metadata = { ...(updates.metadata || {}), delivered_at: new Date().toISOString() };
    }

    if (status === 'cancelled') {
      // Restauration du stock gérée par le trigger DB restore_stock_on_order_cancel
      // (au passage status → 'cancelled'). Pas de restore ici (sinon double).
      // Remboursement acheteur ATOMIQUE (recrédit wallet + escrow 'refunded') — corrige la perte
      // d'argent acheteur quand le vendeur annule une commande payée au wallet.
      const { error: refundErr } = await supabaseAdmin.rpc('refund_order_escrow', { p_order_id: orderId });
      if (refundErr) {
        logger.error(`Refund escrow (vendor cancel) failed (order ${orderId}): ${refundErr.message}`);
      }
      // 🤝 Annuler les commissions d'affiliation pending de cette commande.
      await cancelAffiliateCommissions(orderId);
    }

    const { data: updated, error } = await supabaseAdmin
      .from('orders').update(updates).eq('id', orderId).select('*').single();

    if (error) throw error;

    // 🔔 Notifier le client du changement de statut (bouton notifications).
    if (order.customer_id) {
      const { data: customer } = await supabaseAdmin
        .from('customers')
        .select('user_id')
        .eq('id', order.customer_id)
        .maybeSingle();

      if (customer?.user_id) {
        const statusMessages: Record<string, string> = {
          confirmed: 'Votre commande a été confirmée par le vendeur',
          preparing: 'Votre commande est en cours de préparation',
          ready: 'Votre commande est prête',
          in_transit: 'Votre commande a été expédiée',
          delivered: 'Votre commande a été livrée',
          cancelled: 'Votre commande a été annulée',
        };
        await createNotification({
          userId: customer.user_id,
          type: 'order',
          title: `Commande ${order.order_number || ''}`.trim(),
          message: statusMessages[status] || `Statut de votre commande : ${status}`,
          metadata: { order_id: orderId, order_number: order.order_number, status },
        });
      }
    }

    logger.info(`Order ${orderId} status: ${order.status} → ${status} by vendor=${vendor.id}`);
    res.json({ success: true, data: updated });
  } catch (error: any) {
    logger.error(`Order status update error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * GET /api/orders/escrow/my-transactions
 * Transactions escrow de l'UTILISATEUR courant (vendeur = receiver_id, ou acheteur = payer_id).
 * Via service_role mais STRICTEMENT scopé à req.user.id → pas de fuite, pas de blocage RLS
 * (la RLS payer/receiver = auth.uid() masquait des lignes selon le contexte du JWT côté client).
 * Enrichi côté serveur (order + litige ouvert lié) en requêtes groupées = rapide (zéro N+1).
 * Remplace l'ancienne lecture client (cassée depuis que le hook pointait vers la route PDG).
 */
router.get('/escrow/my-transactions', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ success: false, error: 'Non authentifié' });

    const { data: txs, error } = await supabaseAdmin
      .from('escrow_transactions')
      .select('*')
      .or(`receiver_id.eq.${userId},payer_id.eq.${userId}`)
      .order('created_at', { ascending: false })
      .limit(500);
    if (error) throw error;

    const rows: any[] = txs || [];
    const ids = rows.map((t) => t.id);
    const orderIds = [...new Set(rows.map((t) => t.order_id).filter(Boolean))];

    const [ordersRes, disputesRes] = await Promise.all([
      orderIds.length
        ? supabaseAdmin.from('orders').select('id, order_number').in('id', orderIds)
        : Promise.resolve({ data: [] as any[] }),
      ids.length
        ? supabaseAdmin.from('escrow_disputes')
            .select('id, escrow_id, status, reason, initiator_role, created_at')
            .in('escrow_id', ids).neq('status', 'resolved')
        : Promise.resolve({ data: [] as any[] }),
    ]);
    const oById = new Map((ordersRes.data || []).map((o: any) => [o.id, o]));
    const dByEscrow = new Map((disputesRes.data || []).map((d: any) => [d.escrow_id, d]));

    const enriched = rows.map((t) => ({
      ...t,
      order: oById.get(t.order_id) || null,
      dispute: dByEscrow.get(t.id) || null,
    }));
    res.json({ success: true, data: enriched });
  } catch (error: any) {
    logger.error(`[escrow/my-transactions] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur chargement escrow' });
  }
});

/**
 * POST /api/orders/escrow/:escrowId/request-release
 * Le vendeur demande la libération des fonds bloqués. L'ancienne version (côté client)
 * ne faisait QUE journaliser l'action → NI le PDG NI le client n'étaient notifiés.
 * Ici : on journalise ET on notifie SIMULTANÉMENT le client (qui peut confirmer la
 * réception pour libérer) ET les PDG/admins (qui peuvent libérer). Scopé : seul le
 * vendeur destinataire de l'escrow peut déclencher.
 */
router.post('/escrow/:escrowId([0-9a-fA-F-]{36})/request-release', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ success: false, error: 'Non authentifié' });
    const { escrowId } = req.params;

    const { data: escrow, error: escErr } = await supabaseAdmin
      .from('escrow_transactions')
      .select('id, payer_id, receiver_id, order_id, amount, currency, status')
      .eq('id', escrowId)
      .maybeSingle();
    if (escErr) throw escErr;
    if (!escrow) return res.status(404).json({ success: false, error: 'Transaction escrow introuvable' });

    // Sécurité : seul le vendeur destinataire peut demander la libération.
    if (escrow.receiver_id !== userId) {
      return res.status(403).json({ success: false, error: 'Action réservée au vendeur de cette transaction' });
    }
    if (!['pending', 'held'].includes(escrow.status)) {
      return res.status(400).json({ success: false, error: `Libération impossible (statut: ${escrow.status})` });
    }

    // Anti-spam / idempotence : si une demande a déjà été faite il y a < 10 min, ne pas
    // re-notifier (évite le matraquage du client et du PDG par double-clic ou retry).
    try {
      const since = new Date(Date.now() - 10 * 60 * 1000).toISOString();
      const { data: recent } = await supabaseAdmin
        .from('escrow_logs')
        .select('id')
        .eq('escrow_id', escrowId)
        .eq('action', 'requested_release')
        .gte('created_at', since)
        .limit(1);
      if (recent && recent.length) {
        return res.json({ success: true, message: 'Demande déjà envoyée récemment', notified: 0, deduped: true });
      }
    } catch { /* la table de logs peut être absente : on continue */ }

    // Journalisation (best-effort, ne bloque pas la notification)
    try {
      await supabaseAdmin.rpc('log_escrow_action', {
        p_escrow_id: escrowId,
        p_action: 'requested_release',
        p_performed_by: userId,
        p_note: 'Demande de libération par le vendeur',
      });
    } catch (e: any) {
      logger.warn(`request-release log non bloquant: ${e?.message || e}`);
    }

    // Numéro de commande lisible
    let orderNo = escrow.order_id ? String(escrow.order_id).slice(0, 8) : escrowId.slice(0, 8);
    if (escrow.order_id) {
      const { data: ord } = await supabaseAdmin.from('orders').select('order_number').eq('id', escrow.order_id).maybeSingle();
      if (ord?.order_number) orderNo = ord.order_number;
    }

    const meta = { escrow_id: escrowId, order_id: escrow.order_id, kind: 'release_request' };
    const notifs: any[] = [];

    // 1) Le client (payeur) : il peut confirmer la réception pour libérer automatiquement.
    if (escrow.payer_id) {
      notifs.push({
        userId: escrow.payer_id,
        type: 'escrow',
        title: 'Le vendeur demande la libération',
        message: `Le vendeur a expédié la commande ${orderNo} et demande la libération des fonds. Confirmez la réception pour finaliser, ou ouvrez un litige si un problème subsiste.`,
        metadata: { ...meta, party: 'client' },
      });
    }

    // 2) Les PDG / admins : ils peuvent libérer les fonds.
    const { data: admins } = await supabaseAdmin
      .from('profiles')
      .select('id')
      .in('role', ['admin', 'pdg', 'ceo']);
    for (const a of (admins || [])) {
      notifs.push({
        userId: (a as any).id,
        type: 'escrow',
        title: 'Demande de libération escrow',
        message: `Le vendeur demande la libération des fonds — commande ${orderNo} (${Number(escrow.amount || 0).toLocaleString()} ${escrow.currency || 'GNF'}).`,
        metadata: { ...meta, party: 'pdg' },
      });
    }

    if (notifs.length) {
      try { await createNotifications(notifs); }
      catch (e: any) { logger.warn(`request-release notification non bloquant: ${e?.message || e}`); }
    }

    logger.info(`Escrow ${escrowId} release requested by vendor ${userId} → notified client+${(admins || []).length} admins`);
    res.json({ success: true, message: 'Demande de libération envoyée', notified: notifs.length });
  } catch (error: any) {
    logger.error(`[escrow/request-release] ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la demande de libération' });
  }
});

export default router;
