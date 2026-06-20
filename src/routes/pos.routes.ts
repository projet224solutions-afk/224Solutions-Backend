/**
 * 🏪 POS SYNC ROUTES - Phase 6 (P1 Optimized)
 * 
 * P1 Optimization:
 *   - Atomic RPC create_pos_sale_complete: 1 DB call per sale
 *   - Combines idempotence + insert sale + items + stock decrement
 *   - Reduces from 4 sequential calls to 1 per sale
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { posSyncRateLimit } from '../middlewares/routeRateLimiter.js';
import { z } from 'zod';
import Stripe from 'stripe';

const router = Router();

async function agentHasPosPermission(agentId: string): Promise<boolean> {
  try {
    const { data, error } = await supabaseAdmin.rpc('check_agent_permission' as any, {
      p_agent_id: agentId,
      p_permission_key: 'access_pos',
    });

    if (error) {
      logger.warn(`[POS] check_agent_permission failed: ${error.message}`);
      return false;
    }

    return Boolean(data);
  } catch (error: any) {
    logger.warn(`[POS] check_agent_permission exception: ${error?.message || 'unknown'}`);
    return false;
  }
}

async function resolvePosVendorId(userId: string, requestedVendorId?: string | null): Promise<string | null> {
  const { data: ownVendor } = await supabaseAdmin
    .from('vendors')
    .select('id')
    .eq('user_id', userId)
    .maybeSingle();

  if (ownVendor?.id) {
    if (!requestedVendorId || requestedVendorId === ownVendor.id) {
      return ownVendor.id;
    }
    return null;
  }

  // Agent VENDEUR (vendor_agents), pas agent PDG (agents_management).
  const { data: agent } = await supabaseAdmin
    .from('vendor_agents')
    .select('id, vendor_id, is_active')
    .eq('user_id', userId)
    .maybeSingle();

  if (!agent || !agent.is_active || !agent.vendor_id) {
    return null;
  }

  if (requestedVendorId && requestedVendorId !== agent.vendor_id) {
    return null;
  }

  const canAccessPos = await agentHasPosPermission(agent.id);
  if (!canAccessPos) {
    return null;
  }

  return agent.vendor_id;
}

async function getConfiguredStripeSecretKey(): Promise<string | null> {
  const envKey = process.env.STRIPE_SECRET_KEY?.trim();
  if (envKey) {
    return envKey;
  }

  try {
    const { data, error } = await supabaseAdmin
      .from('stripe_config')
      .select('stripe_secret_key')
      .limit(1)
      .maybeSingle();

    if (error) {
      logger.warn(`[POS Stripe] stripe_config inaccessible: ${error.message}`);
      return null;
    }

    const dbKey = data?.stripe_secret_key?.trim();
    if (dbKey) {
      logger.warn('[POS Stripe] STRIPE_SECRET_KEY absent du runtime, fallback stripe_config activé');
      return dbKey;
    }
  } catch (error: any) {
    logger.warn(`[POS Stripe] Fallback stripe_config échoué: ${error?.message || 'unknown'}`);
  }

  return null;
}

// ==================== VALIDATION SCHEMAS ====================

const PosSaleItemSchema = z.object({
  product_id: z.string().uuid(),
  product_name: z.string().max(200),
  quantity: z.number().int().min(1).max(9999),
  unit_price: z.number().min(0),
  discount: z.number().min(0).default(0),
});

const PosSaleSchema = z.object({
  local_sale_id: z.string().min(1, 'local_sale_id requis').max(100),
  items: z.array(PosSaleItemSchema).min(1).max(100),
  payment_method: z.enum(['cash', 'mobile_money', 'card', 'credit']),
  total_amount: z.number().min(0),
  discount_total: z.number().min(0).default(0),
  customer_name: z.string().max(200).nullish(),
  customer_phone: z.string().max(20).nullish(),
  marketing_contact: z.string().trim().max(200).nullish(),
  notes: z.string().max(500).nullish(),
  sold_at: z.string().datetime({ message: 'sold_at doit être ISO 8601' }),
});

const BatchSyncSchema = z.object({
  sales: z.array(PosSaleSchema).min(1, 'Au moins une vente').max(50, 'Maximum 50 ventes par lot'),
});

const PosMarketingContactSchema = z.object({
  contact: z.string().trim().min(3).max(200),
  customer_name: z.string().trim().max(200).nullish(),
  order_total: z.number().min(0).nullish(),
  sold_at: z.string().datetime({ message: 'sold_at doit être ISO 8601' }).nullish(),
});

function normalizeMarketingContact(contact: string):
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
    throw new Error('Le contact doit être un email valide ou un numéro de téléphone valide.');
  }

  const phone = trimmed.startsWith('+') ? `+${digitsOnly}` : digitsOnly;
  return {
    contactType: 'phone',
    normalized: digitsOnly,
    email: null,
    phone,
  };
}

async function upsertPosMarketingContact(params: {
  vendorId: string;
  contact: string;
  customerName?: string | null;
  orderTotal?: number | null;
  soldAt?: string | null;
}) {
  const normalizedContact = normalizeMarketingContact(params.contact);
  const soldAt = params.soldAt || new Date().toISOString();
  const orderTotal = Number(params.orderTotal || 0);

  const { data: existing, error: existingError } = await supabaseAdmin
    .from('vendor_marketing_contacts')
    .select('id, total_orders, total_spent, source_type, email, phone, full_name')
    .eq('vendor_id', params.vendorId)
    .eq('normalized_contact', normalizedContact.normalized)
    .maybeSingle();

  if (existingError) throw existingError;

  if (existing?.id) {
    const mergedSourceType = existing.source_type === 'both'
      ? 'both'
      : existing.source_type === 'physical'
        ? 'physical'
        : 'both';

    const { error: updateError } = await supabaseAdmin
      .from('vendor_marketing_contacts')
      .update({
        contact_type: normalizedContact.contactType,
        email: normalizedContact.email || existing.email,
        phone: normalizedContact.phone || existing.phone,
        full_name: params.customerName || existing.full_name,
        source_type: mergedSourceType,
        linked_via: 'pos_order',
        last_purchase_at: soldAt,
        total_orders: Number(existing.total_orders || 0) + 1,
        total_spent: Number(existing.total_spent || 0) + orderTotal,
        is_active: true,
        updated_at: new Date().toISOString(),
      })
      .eq('id', existing.id);

    if (updateError) throw updateError;

    return { id: existing.id, status: 'updated' as const };
  }

  const { data: created, error: insertError } = await supabaseAdmin
    .from('vendor_marketing_contacts')
    .insert({
      vendor_id: params.vendorId,
      contact_type: normalizedContact.contactType,
      normalized_contact: normalizedContact.normalized,
      email: normalizedContact.email,
      phone: normalizedContact.phone,
      full_name: params.customerName || null,
      source_type: 'physical',
      linked_via: 'pos_order',
      last_purchase_at: soldAt,
      total_orders: 1,
      total_spent: orderTotal,
      is_active: true,
    })
    .select('id')
    .single();

  if (insertError) throw insertError;

  return { id: created.id, status: 'created' as const };
}

// ==================== CONCURRENCY CONTROL ====================

const CONCURRENCY_LIMIT = 5;

async function processWithConcurrency<T, R>(
  items: T[],
  fn: (item: T) => Promise<R>,
  limit: number
): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let nextIndex = 0;

  async function worker() {
    while (nextIndex < items.length) {
      const idx = nextIndex++;
      results[idx] = await fn(items[idx]);
    }
  }

  const workers = Array.from(
    { length: Math.min(limit, items.length) },
    () => worker()
  );
  await Promise.all(workers);
  return results;
}

// ==================== ROUTES ====================

/**
 * POST /api/pos/sync
 * P1 OPTIMIZED: Uses atomic RPC create_pos_sale_complete (1 DB call per sale)
 * + controlled concurrency (max 5 parallel)
 */
router.post('/sync', verifyJWT, posSyncRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;

    const requestedVendorId = (req.headers['x-vendor-id'] as string | undefined)?.trim() || null;
    const vendorId = await resolvePosVendorId(userId, requestedVendorId);

    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const validation = BatchSyncSchema.safeParse(req.body);
    if (!validation.success) {
      res.status(400).json({
        success: false,
        error: 'Données invalides',
        details: validation.error.errors.map(e => ({
          field: e.path.join('.'),
          message: e.message,
        })),
      });
      return;
    }

    const { sales } = validation.data;

    // Process sales with controlled concurrency
    const processSale = async (sale: typeof sales[number]) => {
      try {
        const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc('create_pos_sale_complete', {
          p_vendor_id: vendorId,
          p_local_sale_id: sale.local_sale_id,
          p_items: sale.items,
          p_payment_method: sale.payment_method,
          p_total_amount: sale.total_amount,
          p_discount_total: sale.discount_total,
          p_customer_name: sale.customer_name || null,
          p_customer_phone: sale.customer_phone || null,
          p_notes: sale.notes || null,
          p_sold_at: sale.sold_at,
        });

        if (rpcError) {
          logger.error(`POS RPC error for ${sale.local_sale_id}: ${rpcError.message}`);
          return {
            local_sale_id: sale.local_sale_id,
            status: 'error' as const,
            error: rpcError.message,
          };
        }

        const result = rpcResult as {
          status: 'created' | 'duplicate' | 'error';
          sale_id?: string;
          server_total?: number;
          stock_synced?: boolean;
          stock_error?: string;
          error?: string;
        };

        if (result.status === 'error') {
          logger.error(`POS sale error for ${sale.local_sale_id}: ${result.error}`);
          return {
            local_sale_id: sale.local_sale_id,
            status: 'error' as const,
            error: result.error,
          };
        }

        if (result.status === 'duplicate') {
          if (sale.marketing_contact?.trim()) {
            await upsertPosMarketingContact({
              vendorId,
              contact: sale.marketing_contact,
              customerName: sale.customer_name || null,
              orderTotal: sale.total_amount,
              soldAt: sale.sold_at,
            });
          }

          return {
            local_sale_id: sale.local_sale_id,
            status: 'duplicate' as const,
            sale_id: result.sale_id,
          };
        }

        // Log total mismatch warning (non-blocking)
        if (result.server_total && Math.abs(result.server_total - sale.total_amount) > sale.total_amount * 0.01) {
          logger.warn(`POS total mismatch: local=${sale.total_amount}, server=${result.server_total}, sale=${sale.local_sale_id}`);
        }

        if (!result.stock_synced) {
          logger.warn(`POS stock sync failed: sale=${sale.local_sale_id}: ${result.stock_error}`);
        }

        if (sale.marketing_contact?.trim()) {
          await upsertPosMarketingContact({
            vendorId,
            contact: sale.marketing_contact,
            customerName: sale.customer_name || null,
            orderTotal: sale.total_amount,
            soldAt: sale.sold_at,
          });
        }

        return {
          local_sale_id: sale.local_sale_id,
          status: 'created' as const,
          sale_id: result.sale_id,
          stock_synced: result.stock_synced ?? true,
        };
      } catch (saleError: any) {
        logger.error(`POS sync error for ${sale.local_sale_id}: ${saleError.message}`);
        return {
          local_sale_id: sale.local_sale_id,
          status: 'error' as const,
          error: saleError.message,
        };
      }
    };

    const results = await processWithConcurrency(sales, processSale, CONCURRENCY_LIMIT);

    const created = results.filter(r => r.status === 'created').length;
    const duplicates = results.filter(r => r.status === 'duplicate').length;
    const errors = results.filter(r => r.status === 'error').length;
    const stockPending = results.filter(r => (r as any).stock_synced === false).length;

    logger.info(`POS sync: vendor=${vendorId}, created=${created}, duplicates=${duplicates}, errors=${errors}, stock_pending=${stockPending}`);

    res.json({
      success: errors === 0,
      data: {
        results,
        summary: { total: sales.length, created, duplicates, errors, stock_pending: stockPending },
      },
    });
  } catch (error: any) {
    logger.error(`POS sync error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur de synchronisation POS' });
  }
});
/**
 * POST /api/pos/order
 * Création ATOMIQUE d'une commande POS en ligne (mobile money / crédit / carte)
 * → orders(source='pos') + order_items + décrément stock (trigger) + TAXE server-side,
 *   le tout dans une seule transaction (RPC create_pos_order_complete).
 * Le cash passe par /sync (pos_sales) ; cet endpoint couvre les paiements qui ont
 * besoin d'un order_id (passerelle ChapChapPay) ou d'un suivi de crédit.
 */
const PosOrderItemSchema = z.object({
  product_id: z.string().uuid(),
  quantity: z.number().int().min(1).max(9999),
  unit_price: z.number().min(0),
  discount: z.number().min(0).default(0),
});

const PosOrderSchema = z.object({
  order_number: z.string().min(1).max(100),
  customer_id: z.string().uuid().nullish(),
  items: z.array(PosOrderItemSchema).min(1).max(100),
  payment_method: z.enum(['mobile_money', 'card', 'credit', 'cash']),
  payment_status: z.enum(['pending', 'paid', 'failed', 'refunded']).default('pending'),
  status: z.enum(['pending', 'confirmed', 'processing', 'shipped', 'delivered', 'cancelled']).default('processing'),
  discount_total: z.number().min(0).default(0),
  notes: z.string().max(500).nullish(),
  currency: z.string().max(8).default('GNF'),
  shipping_address: z.record(z.any()).nullish(),
  // Vente à crédit (utilisé uniquement si payment_method = 'credit')
  credit_customer_name: z.string().max(200).nullish(),
  credit_customer_phone: z.string().max(20).nullish(),
  credit_due_date: z.string().datetime({ message: 'credit_due_date doit être ISO 8601' }).nullish(),
  credit_notes: z.string().max(500).nullish(),
  credit_items: z.array(z.record(z.any())).max(100).nullish(),
});

router.post('/order', verifyJWT, posSyncRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const requestedVendorId = (req.headers['x-vendor-id'] as string | undefined)?.trim() || null;
    const vendorId = await resolvePosVendorId(userId, requestedVendorId);

    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const validation = PosOrderSchema.safeParse(req.body);
    if (!validation.success) {
      res.status(400).json({
        success: false,
        error: 'Données invalides',
        details: validation.error.errors.map(e => ({ field: e.path.join('.'), message: e.message })),
      });
      return;
    }

    const order = validation.data;

    const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc('create_pos_order_complete' as any, {
      p_vendor_id: vendorId,
      p_customer_id: order.customer_id || null,
      p_order_number: order.order_number,
      p_items: order.items,
      p_payment_method: order.payment_method,
      p_payment_status: order.payment_status,
      p_status: order.status,
      p_discount_total: order.discount_total,
      p_notes: order.notes || null,
      p_currency: order.currency,
      ...(order.shipping_address ? { p_shipping_address: order.shipping_address } : {}),
      p_credit_customer_name: order.credit_customer_name || null,
      p_credit_customer_phone: order.credit_customer_phone || null,
      p_credit_due_date: order.credit_due_date || null,
      p_credit_notes: order.credit_notes || null,
      p_credit_items: order.credit_items || null,
    });

    if (rpcError) {
      logger.error(`POS order RPC error (${order.order_number}): ${rpcError.message}`);
      res.status(500).json({ success: false, error: 'Erreur de création de la commande POS' });
      return;
    }

    const result = rpcResult as {
      status: 'created' | 'error';
      order_id?: string;
      order_number?: string;
      subtotal?: number;
      tax_amount?: number;
      total?: number;
      error?: string;
    };

    if (result.status === 'error') {
      logger.error(`POS order error (${order.order_number}): ${result.error}`);
      res.status(409).json({ success: false, error: result.error || 'Échec de création de la commande POS' });
      return;
    }

    logger.info(`POS order created: vendor=${vendorId}, order=${result.order_id}, total=${result.total}`);

    res.json({
      success: true,
      data: {
        order_id: result.order_id,
        order_number: result.order_number,
        subtotal: result.subtotal,
        tax_amount: result.tax_amount,
        total: result.total,
      },
    });
  } catch (error: any) {
    logger.error(`POS order error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur de création de la commande POS' });
  }
});

/**
 * GET /api/pos/sales
 */
router.get('/sales', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const requestedVendorId = (req.headers['x-vendor-id'] as string | undefined)?.trim() || null;
    const vendorId = await resolvePosVendorId(userId, requestedVendorId);

    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const limit = Math.min(parseInt(req.query.limit as string) || 20, 100);
    const offset = parseInt(req.query.offset as string) || 0;

    const { data, error, count } = await supabaseAdmin
      .from('pos_sales')
      .select('*, pos_sale_items(*)', { count: 'exact' })
      .eq('vendor_id', vendorId)
      .order('sold_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (error) throw error;

    res.json({ success: true, data: data || [], meta: { limit, offset, total: count || 0 } });
  } catch (error: any) {
    logger.error(`POS sales list error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * GET /api/pos/reconciliation
 */
router.get('/reconciliation', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const requestedVendorId = (req.headers['x-vendor-id'] as string | undefined)?.trim() || null;
    const vendorId = await resolvePosVendorId(userId, requestedVendorId);

    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const { data, error } = await supabaseAdmin
      .from('pos_stock_reconciliation')
      .select('*, product:products(id, name, sku)')
      .eq('vendor_id', vendorId)
      .eq('status', 'pending')
      .order('created_at', { ascending: false });

    if (error) throw error;

    res.json({ success: true, data: data || [] });
  } catch (error: any) {
    logger.error(`POS reconciliation error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * POST /api/pos/marketing-contact
 * Collecter un contact marketing POS (email ou téléphone) pour les campagnes vendeur
 */
router.post('/marketing-contact', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const requestedVendorId = (req.headers['x-vendor-id'] as string | undefined)?.trim() || null;
    const vendorId = await resolvePosVendorId(userId, requestedVendorId);

    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const parsed = PosMarketingContactSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({
        success: false,
        error: 'Contact marketing invalide',
        details: parsed.error.flatten().fieldErrors,
      });
      return;
    }

    const result = await upsertPosMarketingContact({
      vendorId,
      contact: parsed.data.contact,
      customerName: parsed.data.customer_name || null,
      orderTotal: parsed.data.order_total,
      soldAt: parsed.data.sold_at || null,
    });

    res.status(result.status === 'created' ? 201 : 200).json({ success: true, data: result });
  } catch (error: any) {
    logger.error(`POS marketing contact error: ${error.message}`);
    res.status(500).json({ success: false, error: error?.message || 'Erreur collecte contact marketing POS' });
  }
});

export default router;

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/pos/stripe-payment
// Crée un Payment Intent Stripe pour le POS avec commission marketplace
//
// LOGIQUE CALCUL (critique — erreur = perte vendeur):
//   commissionAmount = Math.round(amount × commissionRate / 100)  ← arrondi entier GNF
//   totalAmount      = amount + commissionAmount                   ← facturé au CLIENT
//   sellerNetAmount  = amount                                      ← reversé au VENDEUR
//
// ⚠️  Ne jamais changer cette logique sans validation PDG
// ─────────────────────────────────────────────────────────────────────────────

const PosStripePaymentSchema = z.object({
  amount: z.number().positive('Le montant doit être positif'),
  currency: z.string().min(2).max(5).default('GNF'),
  orderId: z.string().min(1).max(200),
  sellerId: z.string().min(1, 'sellerId requis'),
  description: z.string().max(500).optional(),
});

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Récupère le taux de commission depuis pdg_settings (clé principale + alias)
// Fallback: 2.5% si non configuré
async function getPosCommissionRate(): Promise<number> {
  const DEFAULT_RATE = 2.5;
  const candidateKeys = ['commission_achats', 'purchase_commission_percentage'];
  try {
    for (const key of candidateKeys) {
      const { data } = await supabaseAdmin
        .from('pdg_settings')
        .select('setting_value')
        .eq('setting_key', key)
        .maybeSingle();

      if (!data) continue;

      const raw = data.setting_value;
      const rate = typeof raw === 'object' && raw !== null && 'value' in (raw as any)
        ? Number((raw as any).value)
        : Number(raw);
      if (!isNaN(rate) && rate >= 0 && rate <= 100) return rate;
    }

    return DEFAULT_RATE;
  } catch {
    return DEFAULT_RATE;
  }
}

// Résout un sellerId (UUID OU public_id/custom_id) → UUID Supabase
async function resolveSellerUuid(rawSellerId: string): Promise<string> {
  if (UUID_REGEX.test(rawSellerId)) return rawSellerId;
  const normalized = rawSellerId.trim().toUpperCase();
  const { data, error } = await supabaseAdmin
    .from('profiles')
    .select('id')
    .or(`public_id.eq.${normalized},custom_id.eq.${normalized}`)
    .maybeSingle();
  if (error || !data) throw new Error(`Vendeur introuvable avec l'identifiant: ${rawSellerId}`);
  return data.id;
}

router.post('/stripe-payment', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  const buyerId = req.user!.id;

  // ── 1. Validation des entrées ──────────────────────────────────────────────
  const parsed = PosStripePaymentSchema.safeParse(req.body);
  if (!parsed.success) {
    res.status(400).json({
      success: false,
      error: 'Paramètres invalides',
      details: parsed.error.flatten().fieldErrors,
    });
    return;
  }

  const { amount, currency, orderId, sellerId: rawSellerId, description } = parsed.data;

  // ── 2. Stripe configuré ? ─────────────────────────────────────────────────
  const stripeKey = await getConfiguredStripeSecretKey();
  if (!stripeKey) {
    logger.error('[POS Stripe] STRIPE_SECRET_KEY manquant dans le runtime et stripe_config');
    res.status(503).json({ success: false, error: 'Paiement par carte non disponible (Stripe non configuré)' });
    return;
  }

  try {
    // ── 3. Résoudre le vendeur ────────────────────────────────────────────────
    const sellerId = await resolveSellerUuid(rawSellerId);

    // ── 4. Taux de commission ─────────────────────────────────────────────────
    const commissionRate = await getPosCommissionRate();

    // ── 5. CALCUL FINANCIER (colonne vertébrale — ne pas modifier sans audit) --
    // GNF est une devise sans décimales → on arrondit toujours à l'entier
    const commissionAmount = Math.round(amount * (commissionRate / 100));
    const totalAmount = amount + commissionAmount; // facturé au CLIENT
    const sellerNetAmount = amount;                   // reversé au VENDEUR

    logger.info('[POS Stripe] Calcul commission', {
      buyerId,
      sellerId,
      orderId,
      productAmount: amount,
      commissionRate: `${commissionRate}%`,
      commissionAmount,
      totalAmount,
      sellerNetAmount,
    });

    // ── 6. Créer le Payment Intent Stripe ────────────────────────────────────
    const stripe = new Stripe(stripeKey, { apiVersion: '2023-10-16' as any });

    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(totalAmount), // Stripe reçoit le total (GNF = entier)
      currency: currency.toLowerCase(),
      automatic_payment_methods: { enabled: true },
      metadata: {
        order_id: orderId,
        buyer_id: buyerId,
        seller_id: sellerId,
        product_amount: amount.toString(),
        commission_rate: commissionRate.toString(),
        commission_amount: commissionAmount.toString(),
        total_amount: totalAmount.toString(),
        seller_net_amount: sellerNetAmount.toString(),
        source: 'pos',
        description: description || 'Paiement POS 224Solutions',
      },
    });

    // ── 7. Enregistrer en base (non-bloquant — le webhook confirme) ───────────
    const { data: transaction, error: insertError } = await supabaseAdmin
      .from('stripe_transactions')
      .insert({
        stripe_payment_intent_id: paymentIntent.id,
        buyer_id: buyerId,
        seller_id: sellerId,
        amount: totalAmount,        // total facturé client
        currency: currency.toUpperCase(),
        commission_rate: commissionRate,
        commission_amount: commissionAmount,
        seller_net_amount: sellerNetAmount,    // net reversé vendeur
        status: 'PENDING',
        order_id: orderId || null,
        payment_method: 'card',
        metadata: {
          description: description || 'Paiement POS',
          source: 'pos',
          created_by: buyerId,
          product_amount: amount,
          total_amount: totalAmount,
        },
      })
      .select('id')
      .single();

    if (insertError) {
      // Logguer mais ne pas bloquer — le webhook peut recréer l'entrée
      logger.warn('[POS Stripe] Erreur enregistrement stripe_transactions', { error: insertError.message, intentId: paymentIntent.id });
    } else {
      logger.info('[POS Stripe] Transaction enregistrée', { transactionId: transaction?.id, intentId: paymentIntent.id });
    }

    // ── 8. Réponse ────────────────────────────────────────────────────────────
    res.json({
      success: true,
      clientSecret: paymentIntent.client_secret,
      paymentIntentId: paymentIntent.id,
      transactionId: transaction?.id ?? null,
      // Données de commissionnement pour affichage UI
      commissionRate,
      commissionAmount,
      sellerNetAmount,
      productAmount: amount,
      totalAmount,
    });
  } catch (err: any) {
    logger.error('[POS Stripe] Erreur création paiement', { error: err.message, buyerId, orderId });
    // Ne jamais exposer les détails Stripe en clair (OWASP A3)
    const isValidationError = err.message?.includes('introuvable') || err.message?.includes('invalide');
    res.status(isValidationError ? 400 : 500).json({
      success: false,
      error: isValidationError ? err.message : 'Erreur lors de la création du paiement. Veuillez réessayer.',
    });
  }
});
