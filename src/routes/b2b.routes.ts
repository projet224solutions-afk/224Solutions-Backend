/**
 * 🤝 B2B ROUTES — Approvisionnement 224 (achats fournisseurs unifiés)
 *
 * Monté sur /api/b2b. Voir docs/APPROVISIONNEMENT_224.md (repo frontend).
 *
 * Bloc 1 — Liaison fournisseur par CONSENTEMENT :
 *   - GET  /suppliers/resolve-vendor?identifier=  → résout un VENDEUR plateforme
 *     (code 224 / téléphone / email / nom de boutique EXACT — 0 ou 1, anti-énumération)
 *   - POST /suppliers/:supplierRowId/link-request → envoie la demande de liaison
 *   - GET  /link-requests?box=received|sent       → demandes reçues / envoyées
 *   - POST /link-requests/:id/respond             → accepter / refuser (fournisseur)
 *
 * Toute écriture passe par une RPC atomique SECURITY DEFINER (service_role only).
 * Agent-aware : permission `manage_suppliers` requise pour un agent vendeur.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { ok, fail } from '../utils/apiResponse.js';
import { resolveVendorContext, vendorContextHasPermission } from '../services/vendorContext.service.js';
import { createNotification } from '../services/notification.service.js';
import { resolveExactUserId } from './profiles.routes.js';
import { buildOrderFinancialSummary, getBuyerCurrency, getInternalFxRate } from '../services/marketplacePricing.service.js';
import { z } from 'zod';
import { idempotencyGuard } from '../middlewares/idempotency.middleware.js';
import { isPinSchemaAvailableForMoney, getPinPolicy, getWalletPinState, verifyWalletPin } from '../services/walletPin.service.js';
// @ts-ignore — middleware JS sans types
import { createRedisLimiter } from '../middlewares/rateLimiter.js';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NO_DEC = new Set(['GNF', 'XOF', 'XAF', 'JPY', 'KRW', 'VND', 'CLP']);

function roundMoney(amount: number, currency: string): number {
  return NO_DEC.has(currency.toUpperCase()) ? Math.round(amount) : Math.round(amount * 100) / 100;
}

/** customers.id de l'utilisateur (créé au besoin) — même logique que orders.routes. */
async function getOrCreateCustomerId(userId: string): Promise<string> {
  const { data: existing } = await supabaseAdmin
    .from('customers').select('id').eq('user_id', userId).maybeSingle();
  if (existing?.id) return existing.id;
  const { data: created, error } = await supabaseAdmin
    .from('customers').insert({ user_id: userId }).select('id').single();
  if (error) throw error;
  return created.id;
}

/** Pourcentage de frais acheteur (règle PDG — system_settings.purchase_fee_percent). */
async function getBuyerFeePercent(): Promise<number> {
  try {
    const { data } = await supabaseAdmin
      .from('system_settings').select('setting_value')
      .eq('setting_key', 'purchase_fee_percent').maybeSingle();
    return Math.max(0, Math.min(50, Number(data?.setting_value ?? 0)));
  } catch {
    return 0;
  }
}

/** Anti-énumération : la résolution de vendeur est rate-limitée par IP. */
const resolveVendorLimiter = createRedisLimiter({
  max: 40,
  windowSeconds: 60,
  keyPrefix: 'b2b-resolve-vendor',
  label: 'b2b-resolve-vendor',
  message: 'Trop de recherches. Réessayez dans une minute.',
});

/** Contexte vendeur + permission fournisseurs (agent-aware). Répond 403 et renvoie null si refus. */
async function requireSupplierContext(req: AuthenticatedRequest, res: Response): Promise<string | null> {
  const ctx = await resolveVendorContext(req.user!.id);
  if (!ctx.vendorId) {
    fail(res, 403, 'Boutique non trouvée', 'VENDOR_NOT_FOUND');
    return null;
  }
  if (ctx.isAgent && !vendorContextHasPermission(ctx, 'manage_suppliers') && !vendorContextHasPermission(ctx, 'manage_inventory')) {
    fail(res, 403, 'Permission insuffisante (gestion fournisseurs requise)', 'PERMISSION_DENIED');
    return null;
  }
  return ctx.vendorId;
}

/** Profil public d'un vendeur (jamais de PII : pas d'email/téléphone). */
async function publicVendorCard(vendorId: string) {
  const { data } = await supabaseAdmin
    .from('vendors')
    .select('id, business_name, logo_url, public_id, rating, is_active, user_id, sale_type')
    .eq('id', vendorId)
    .maybeSingle();
  if (!data || data.is_active === false) return null;
  // 🏷️ Un DÉTAILLANT ne vend pas en gros → invisible comme FOURNISSEUR
  // (même réponse « aucune correspondance » — anti-énumération).
  if ((data as any).sale_type === 'detaillant') return null;
  return {
    vendor_id: data.id,
    business_name: data.business_name,
    logo_url: data.logo_url || null,
    public_id: (data as any).public_id || null,
    rating: (data as any).rating ?? null,
  };
}

/** Type de vente du vendeur (detaillant | detail_gros | gros). */
async function vendorSaleType(vendorId: string): Promise<string> {
  const { data, error } = await supabaseAdmin
    .from('vendors').select('sale_type').eq('id', vendorId).maybeSingle();
  if (error) throw error;
  return String((data as any)?.sale_type || 'detail_gros');
}

/**
 * 🛡️ Garde VENTE EN GROS : les endpoints du côté VENDEUR B2B (création de lien
 * de vente…) exigent sale_type ∈ {detail_gros, gros}. Le côté ACHAT reste
 * ouvert à tous (le détaillant est le CLIENT du B2B) ; les LECTURES restent
 * ouvertes (suivi du « B2B en cours » après une descente de type).
 * Répond 403 SALE_TYPE_REQUIRED et renvoie false si refus.
 */
async function requireWholesaleSaleType(vendorId: string, res: Response): Promise<boolean> {
  const saleType = await vendorSaleType(vendorId);
  if (saleType === 'detaillant') {
    fail(res, 403, 'Activez la vente en gros (type de vente) pour utiliser l\'espace Ventes B2B', 'SALE_TYPE_REQUIRED');
    return false;
  }
  return true;
}

/**
 * GET /api/b2b/suppliers/resolve-vendor?identifier=
 * Résolution EXACTE d'un vendeur plateforme : code 224 / USR / téléphone / email
 * (via la résolution universelle des profils) OU nom de boutique EXACT (insensible
 * à la casse, 0 ou 1 — jamais de liste, anti-énumération).
 */
router.get('/suppliers/resolve-vendor', resolveVendorLimiter, verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const identifier = String(req.query.identifier || '').trim();
    if (!identifier) return fail(res, 400, 'Identifiant requis', 'IDENTIFIER_REQUIRED');

    const callerVendorId = await requireSupplierContext(req, res);
    if (!callerVendorId) return;

    // 1) vendors.id direct (uuid)
    if (UUID_RE.test(identifier)) {
      const card = await publicVendorCard(identifier);
      if (card && card.vendor_id !== callerVendorId) return ok(res, card);
    }

    // 2) Résolution universelle (code 224 / téléphone / email) → user → son vendor
    const userId = await resolveExactUserId(identifier);
    if (userId) {
      const { data: vendor } = await supabaseAdmin
        .from('vendors').select('id').eq('user_id', userId).maybeSingle();
      if (vendor && vendor.id !== callerVendorId) {
        const card = await publicVendorCard(vendor.id);
        if (card) return ok(res, card);
      }
    }

    // 3) Nom de boutique EXACT (insensible à la casse). Une correspondance unique, sinon rien.
    const { data: byName } = await supabaseAdmin
      .from('vendors')
      .select('id')
      .ilike('business_name', identifier.replace(/[%_]/g, '')) // ilike sans joker = égalité insensible à la casse
      .neq('id', callerVendorId)
      .limit(2);
    if (byName && byName.length === 1) {
      const card = await publicVendorCard(byName[0].id);
      if (card) return ok(res, card);
    }

    // Aucune correspondance (même forme de réponse — anti-énumération).
    return ok(res, null);
  } catch (error: any) {
    logger.error(`[b2b/resolve-vendor] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de la résolution du vendeur');
  }
});

/**
 * POST /api/b2b/suppliers/:supplierRowId/link-request
 * Body : { target_vendor_id: uuid, message?: string }
 * Envoie une demande de liaison (RPC atomique) + notification in-app au fournisseur.
 */
router.post('/suppliers/:supplierRowId/link-request', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const supplierRowId = String(req.params.supplierRowId || '');
    const { target_vendor_id, message } = req.body || {};
    if (!UUID_RE.test(supplierRowId) || !UUID_RE.test(String(target_vendor_id || ''))) {
      return fail(res, 400, 'Paramètres invalides', 'INVALID_PARAMS');
    }

    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;

    const { data, error } = await supabaseAdmin.rpc('request_supplier_link', {
      p_supplier_row_id: supplierRowId,
      p_requester_vendor_id: vendorId,
      p_target_vendor_id: target_vendor_id,
      p_message: typeof message === 'string' && message.trim() ? message.trim().slice(0, 500) : null,
    });
    if (error) {
      logger.error(`[b2b/link-request] RPC: ${error.message}`);
      return fail(res, 500, 'Erreur lors de l\'envoi de la demande');
    }
    const result = data as any;
    if (!result?.success) {
      const code = String(result?.error || 'UNKNOWN');
      const messages: Record<string, string> = {
        SELF_LINK_FORBIDDEN: 'Vous ne pouvez pas vous lier à votre propre boutique',
        SUPPLIER_NOT_FOUND: 'Fiche fournisseur introuvable',
        ALREADY_LINKED: 'Ce fournisseur est déjà connecté',
        REQUEST_ALREADY_PENDING: 'Une demande est déjà en attente pour ce fournisseur',
        TARGET_VENDOR_NOT_FOUND: 'Boutique cible introuvable',
        VENDOR_ALREADY_LINKED_ELSEWHERE: 'Ce vendeur est déjà lié à une autre fiche fournisseur',
      };
      return fail(res, 409, messages[code] || 'Demande refusée', code);
    }

    // Notification in-app au fournisseur (jamais bloquant pour le flux).
    await createNotification({
      userId: result.target_user_id,
      title: 'Demande de liaison fournisseur',
      message: `${result.requester_business_name || 'Une boutique'} souhaite vous ajouter comme fournisseur 224Solutions.`,
      type: 'b2b_link_request',
      metadata: {
        link: '/vendeur/suppliers?tab=b2b',
        request_id: result.request_id,
        requester_vendor_id: vendorId,
      },
    });

    return ok(res, { request_id: result.request_id });
  } catch (error: any) {
    logger.error(`[b2b/link-request] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de l\'envoi de la demande');
  }
});

/**
 * GET /api/b2b/link-requests?box=received|sent
 * Demandes de liaison du vendeur courant, enrichies des noms de boutiques.
 */
router.get('/link-requests', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;
    const box = req.query.box === 'sent' ? 'sent' : 'received';

    const { data, error } = await supabaseAdmin
      .from('supplier_link_requests')
      .select('id, supplier_row_id, requester_vendor_id, target_vendor_id, status, message, created_at, responded_at')
      .eq(box === 'received' ? 'target_vendor_id' : 'requester_vendor_id', vendorId)
      .order('created_at', { ascending: false })
      .limit(100);
    if (error) throw error;

    const rows = data || [];
    const otherIds = Array.from(new Set(rows.map(r => box === 'received' ? r.requester_vendor_id : r.target_vendor_id)));
    let names = new Map<string, { business_name: string; logo_url: string | null }>();
    if (otherIds.length > 0) {
      const { data: vendors } = await supabaseAdmin
        .from('vendors').select('id, business_name, logo_url').in('id', otherIds);
      names = new Map((vendors || []).map(v => [v.id, { business_name: v.business_name, logo_url: v.logo_url || null }]));
    }

    return ok(res, rows.map(r => {
      const otherId = box === 'received' ? r.requester_vendor_id : r.target_vendor_id;
      return {
        ...r,
        other_vendor_id: otherId,
        other_business_name: names.get(otherId)?.business_name || null,
        other_logo_url: names.get(otherId)?.logo_url || null,
      };
    }));
  } catch (error: any) {
    logger.error(`[b2b/link-requests] ${error?.message}`);
    return fail(res, 500, 'Erreur lors du chargement des demandes');
  }
});

/**
 * POST /api/b2b/link-requests/:id/respond
 * Body : { accept: boolean } — réservé au vendeur CIBLE (le fournisseur).
 */
router.post('/link-requests/:id/respond', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const requestId = String(req.params.id || '');
    const accept = req.body?.accept;
    if (!UUID_RE.test(requestId) || typeof accept !== 'boolean') {
      return fail(res, 400, 'Paramètres invalides', 'INVALID_PARAMS');
    }

    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;

    const { data, error } = await supabaseAdmin.rpc('respond_supplier_link', {
      p_request_id: requestId,
      p_responder_vendor_id: vendorId,
      p_accept: accept,
    });
    if (error) {
      logger.error(`[b2b/link-respond] RPC: ${error.message}`);
      return fail(res, 500, 'Erreur lors de la réponse à la demande');
    }
    const result = data as any;
    if (!result?.success) {
      const code = String(result?.error || 'UNKNOWN');
      const messages: Record<string, string> = {
        REQUEST_NOT_FOUND: 'Demande introuvable',
        NOT_YOUR_REQUEST: 'Cette demande ne vous est pas adressée',
      };
      return fail(res, code === 'NOT_YOUR_REQUEST' ? 403 : 404, messages[code] || 'Réponse impossible', code);
    }
    if (result.already_responded) {
      return ok(res, { already_responded: true, status: result.status });
    }

    // Notification in-app au demandeur.
    await createNotification({
      userId: result.requester_user_id,
      title: accept ? 'Liaison fournisseur acceptée' : 'Liaison fournisseur refusée',
      message: accept
        ? `${result.responder_business_name || 'Le fournisseur'} a accepté la liaison — vous pouvez maintenant commander dans son catalogue.`
        : `${result.responder_business_name || 'Le fournisseur'} a refusé la demande de liaison.`,
      type: accept ? 'b2b_link_accepted' : 'b2b_link_rejected',
      metadata: {
        link: '/vendeur/suppliers?tab=suppliers',
        supplier_row_id: result.supplier_row_id,
      },
    });

    return ok(res, { accepted: accept, supplier_row_id: result.supplier_row_id });
  } catch (error: any) {
    logger.error(`[b2b/link-respond] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de la réponse à la demande');
  }
});

// ═══════════════════════════ Bloc 2 — COMMANDE B2B ═══════════════════════════

/**
 * GET /api/b2b/suppliers/:supplierRowId/catalog
 * Catalogue du fournisseur LIÉ : ses produits publiés (photo, prix, stock dispo,
 * conditionnement carton). Réservé au propriétaire de la fiche liée.
 */
router.get('/suppliers/:supplierRowId/catalog', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const supplierRowId = String(req.params.supplierRowId || '');
    if (!UUID_RE.test(supplierRowId)) return fail(res, 400, 'Paramètres invalides', 'INVALID_PARAMS');

    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;

    const { data: supplier } = await supabaseAdmin
      .from('vendor_suppliers')
      .select('id, name, linked_vendor_id, link_status')
      .eq('id', supplierRowId)
      .eq('vendor_id', vendorId)
      .maybeSingle();
    if (!supplier) return fail(res, 404, 'Fiche fournisseur introuvable', 'SUPPLIER_NOT_FOUND');
    if ((supplier as any).link_status !== 'linked' || !(supplier as any).linked_vendor_id) {
      return fail(res, 409, 'Ce fournisseur n\'est pas connecté à 224Solutions', 'SUPPLIER_NOT_LINKED');
    }

    const { data: products, error } = await supabaseAdmin
      .from('products')
      .select('id, name, description, price, stock_quantity, images, sku, category_id, sell_by_carton, units_per_carton, price_carton, currency')
      .eq('vendor_id', (supplier as any).linked_vendor_id)
      .eq('is_active', true)
      .gt('stock_quantity', 0)
      .order('name');
    if (error) throw error;

    const card = await publicVendorCard((supplier as any).linked_vendor_id);
    return ok(res, { supplier: card, products: products || [] });
  } catch (error: any) {
    logger.error(`[b2b/catalog] ${error?.message}`);
    return fail(res, 500, 'Erreur lors du chargement du catalogue');
  }
});

const CreateB2BOrderSchema = z.object({
  supplier_row_id: z.string().uuid(),
  items: z.array(z.object({
    product_id: z.string().uuid(),
    quantity: z.number().int().min(1).max(1_000_000),
  })).min(1).max(200),
  payment_mode: z.enum(['wallet', 'cash', 'credit']),
  payment_timing: z.enum(['on_order', 'on_reception']),
  notes: z.string().max(1000).nullish(),
  due_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullish(),
  minimum_installment: z.number().min(0).nullish(),
});

/**
 * POST /api/b2b/orders — envoyer une commande B2B au fournisseur lié.
 * Wallet + on_order : montants calculés ICI (backend autoritaire, FX + frais
 * acheteur = règle PDG purchase_fee_percent) puis débit/escrow atomiques en RPC.
 */
router.post('/orders', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = CreateB2BOrderSchema.safeParse(req.body);
    if (!parsed.success) {
      return fail(res, 400, parsed.error.issues[0]?.message || 'Données invalides', 'INVALID_PARAMS');
    }
    const input = parsed.data;

    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;
    const buyerUserId = req.user!.id;

    // Fournisseur lié (pour le calcul financier — la RPC revérifie tout).
    const { data: supplier } = await supabaseAdmin
      .from('vendor_suppliers')
      .select('id, linked_vendor_id, link_status')
      .eq('id', input.supplier_row_id)
      .eq('vendor_id', vendorId)
      .maybeSingle();
    if (!supplier || (supplier as any).link_status !== 'linked' || !(supplier as any).linked_vendor_id) {
      return fail(res, 409, 'Ce fournisseur n\'est pas connecté à 224Solutions', 'SUPPLIER_NOT_LINKED');
    }

    const customerId = await getOrCreateCustomerId(buyerUserId);

    // Montants (wallet + on_order uniquement) : prix DB + FX + frais acheteur.
    let currency = 'GNF';
    let walletDebit = 0;
    let walletCurrency: string | null = null;
    let buyerFee = 0;
    const summary = await buildOrderFinancialSummary({
      buyerUserId,
      vendorId: (supplier as any).linked_vendor_id,
      items: input.items.map(i => ({ productId: i.product_id, quantity: i.quantity })),
      productType: 'physical',
    });
    currency = summary.sellerCurrency;
    if (input.payment_mode === 'wallet' && input.payment_timing === 'on_order') {
      walletDebit = summary.totalPaidAmount;
      walletCurrency = summary.buyerCurrency;
      const feePercent = await getBuyerFeePercent();
      buyerFee = roundMoney(summary.totalPaidAmount * (feePercent / 100), summary.buyerCurrency);
    }

    const { data, error } = await supabaseAdmin.rpc('create_b2b_purchase_order' as any, {
      p_buyer_vendor_id: vendorId,
      p_supplier_row_id: input.supplier_row_id,
      p_items: input.items,
      p_payment_mode: input.payment_mode,
      p_payment_timing: input.payment_timing,
      p_customer_id: customerId,
      p_notes: input.notes || null,
      p_wallet_debit_amount: walletDebit,
      p_buyer_wallet_currency: walletCurrency,
      p_buyer_fee_amount: buyerFee,
      p_currency: currency,
      p_due_date: input.due_date || null,
      p_minimum_installment: input.minimum_installment ?? 0,
    });
    if (error) {
      logger.error(`[b2b/orders] RPC: ${error.message}`);
      return fail(res, 500, 'Erreur lors de la création de la commande');
    }
    const result = data as any;
    if (!result?.success) {
      const code = String(result?.error || 'UNKNOWN');
      const messages: Record<string, string> = {
        SUPPLIER_NOT_LINKED: 'Ce fournisseur n\'est pas connecté à 224Solutions',
        STOCK_INSUFFICIENT: `Stock fournisseur insuffisant${result?.product_name ? ` : ${result.product_name} (${result.available} disponible)` : ''}`,
        INSUFFICIENT_FUNDS: 'Solde wallet insuffisant',
        WALLET_NOT_FOUND: 'Wallet introuvable pour cette devise',
        PRODUCT_NOT_FOUND: 'Un produit du panier n\'est plus disponible',
        DUPLICATE_LINE: 'Une ligne produit est en double',
        INVALID_PAYMENT_TIMING: 'Moment de paiement invalide pour ce mode',
      };
      const status = code === 'INSUFFICIENT_FUNDS' ? 402 : 409;
      return fail(res, status, messages[code] || 'Commande refusée', code);
    }

    await createNotification({
      userId: result.supplier_user_id,
      title: 'Nouvelle commande B2B',
      message: `${result.buyer_business_name || 'Une boutique'} vous a envoyé la commande ${result.order_number}.`,
      type: 'b2b_order_received',
      metadata: { link: '/vendeur/suppliers?tab=b2b', order_id: result.order_id },
    });

    return ok(res, {
      order_id: result.order_id,
      purchase_id: result.purchase_id,
      order_number: result.order_number,
      subtotal: result.subtotal,
      currency: result.currency,
      escrow_status: result.escrow_status,
    });
  } catch (error: any) {
    logger.error(`[b2b/orders] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de la création de la commande');
  }
});

/** Erreurs RPC → messages FR (transitions). */
function b2bTransitionError(res: Response, result: any): Response {
  const code = String(result?.error || 'UNKNOWN');
  const messages: Record<string, string> = {
    ORDER_NOT_FOUND: 'Commande introuvable',
    PURCHASE_NOT_FOUND: 'Achat introuvable',
    PURCHASE_GONE: 'Achat lié introuvable',
    ORDER_GONE: 'Commande liée introuvable',
    INVALID_STATUS: `Transition impossible depuis l'état actuel${result?.status ? ` (${result.status})` : ''}`,
    STOCK_INSUFFICIENT: `Stock insuffisant${result?.product_name ? ` : ${result.product_name} (${result.available} disponible)` : ''}`,
    INSUFFICIENT_FUNDS: 'Solde wallet insuffisant pour le complément',
    RESERVATION_INTEGRITY: 'Incohérence de réservation détectée — contactez le support',
    NOT_A_PARTY: 'Vous n\'êtes pas partie à cette commande',
    LINE_NOT_FOUND: 'Ligne produit introuvable',
    ALL_LINES_REMOVED: 'Impossible : toutes les lignes seraient supprimées',
    REFUND_FAILED: 'Échec du remboursement — action annulée',
    ESCROW_GONE: 'Escrow introuvable',
  };
  const status = code === 'INSUFFICIENT_FUNDS' ? 402
    : code === 'NOT_A_PARTY' ? 403
    : code === 'ORDER_NOT_FOUND' || code === 'PURCHASE_NOT_FOUND' ? 404 : 409;
  return fail(res, status, messages[code] || 'Action refusée', code);
}

const AdjustmentsSchema = z.object({
  adjustments: z.array(z.object({
    product_id: z.string().uuid(),
    quantity: z.number().int().min(0).max(1_000_000),
    unit_price: z.number().min(0).nullish(),
  })).max(200).nullish(),
  note: z.string().max(500).nullish(),
});

/**
 * POST /api/b2b/orders/:orderId/confirm — FOURNISSEUR : confirmer (réservation
 * miroir) ou proposer des ajustements ligne à ligne (l'acheteur revalide).
 */
router.post('/orders/:orderId([0-9a-fA-F-]{36})/confirm', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = AdjustmentsSchema.safeParse(req.body || {});
    if (!parsed.success) return fail(res, 400, 'Données invalides', 'INVALID_PARAMS');

    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;

    const { data, error } = await supabaseAdmin.rpc('confirm_b2b_order' as any, {
      p_order_id: req.params.orderId,
      p_supplier_vendor_id: vendorId,
      p_adjustments: parsed.data.adjustments?.length ? parsed.data.adjustments : null,
      p_note: parsed.data.note || null,
    });
    if (error) {
      logger.error(`[b2b/confirm] RPC: ${error.message}`);
      return fail(res, 500, 'Erreur lors de la confirmation');
    }
    const result = data as any;
    if (!result?.success) return b2bTransitionError(res, result);

    await createNotification({
      userId: result.buyer_user_id,
      title: result.adjusted ? 'Commande B2B ajustée' : 'Commande B2B confirmée',
      message: result.adjusted
        ? `Le fournisseur a ajusté la commande ${result.order_number} — votre revalidation est requise.`
        : `La commande ${result.order_number} est confirmée — le stock fournisseur est réservé.`,
      type: result.adjusted ? 'b2b_order_adjusted' : 'b2b_order_confirmed',
      metadata: { link: '/vendeur/suppliers?tab=purchases', purchase_id: result.purchase_id },
    });

    return ok(res, { adjusted: !!result.adjusted, purchase_id: result.purchase_id });
  } catch (error: any) {
    logger.error(`[b2b/confirm] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de la confirmation');
  }
});

/**
 * POST /api/b2b/orders/:orderId/revalidate — ACHETEUR : accepter (delta wallet/
 * escrow + réservation) ou refuser (annulation propre) les ajustements.
 */
router.post('/orders/:orderId([0-9a-fA-F-]{36})/revalidate', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const accept = req.body?.accept;
    if (typeof accept !== 'boolean') return fail(res, 400, 'Paramètre accept requis', 'INVALID_PARAMS');

    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;

    const { data, error } = await supabaseAdmin.rpc('revalidate_b2b_order' as any, {
      p_order_id: req.params.orderId,
      p_buyer_vendor_id: vendorId,
      p_accept: accept,
    });
    if (error) {
      logger.error(`[b2b/revalidate] RPC: ${error.message}`);
      return fail(res, 500, 'Erreur lors de la revalidation');
    }
    const result = data as any;
    if (!result?.success) return b2bTransitionError(res, result);

    await createNotification({
      userId: result.supplier_user_id,
      title: accept ? 'Ajustements acceptés' : 'Ajustements refusés',
      message: accept
        ? `L'acheteur a accepté les ajustements — la commande ${result.order_number} est confirmée.`
        : `L'acheteur a refusé les ajustements — la commande ${result.order_number} est annulée.`,
      type: accept ? 'b2b_order_confirmed' : 'b2b_order_cancelled',
      metadata: { link: '/vendeur/suppliers?tab=b2b', order_id: req.params.orderId },
    });

    return ok(res, { accepted: accept, cancelled: !!result.cancelled });
  } catch (error: any) {
    logger.error(`[b2b/revalidate] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de la revalidation');
  }
});

/**
 * POST /api/b2b/orders/:orderId/ship — FOURNISSEUR : expédier (sortie définitive
 * du stock réservé, marchandise en transit).
 */
router.post('/orders/:orderId([0-9a-fA-F-]{36})/ship', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;

    const { data, error } = await supabaseAdmin.rpc('ship_b2b_order' as any, {
      p_order_id: req.params.orderId,
      p_supplier_vendor_id: vendorId,
    });
    if (error) {
      logger.error(`[b2b/ship] RPC: ${error.message}`);
      return fail(res, 500, 'Erreur lors de l\'expédition');
    }
    const result = data as any;
    if (!result?.success) return b2bTransitionError(res, result);

    await createNotification({
      userId: result.buyer_user_id,
      title: 'Commande B2B expédiée',
      message: `La commande ${result.order_number} est en transit — réceptionnez-la à l'arrivée pour entrer le stock.`,
      type: 'b2b_order_shipped',
      metadata: { link: '/vendeur/suppliers?tab=purchases', purchase_id: result.purchase_id },
    });

    return ok(res, { purchase_id: result.purchase_id });
  } catch (error: any) {
    logger.error(`[b2b/ship] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de l\'expédition');
  }
});

/**
 * POST /api/b2b/orders/:orderId/cancel — l'une OU l'autre partie, avant
 * expédition. Libère la réservation, rembourse l'escrow (frais acheteur non
 * remboursé — règle standard plateforme).
 */
router.post('/orders/:orderId([0-9a-fA-F-]{36})/cancel', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;

    const reason = typeof req.body?.reason === 'string' ? req.body.reason.slice(0, 500) : null;
    const { data, error } = await supabaseAdmin.rpc('cancel_b2b_order' as any, {
      p_order_id: req.params.orderId,
      p_caller_vendor_id: vendorId,
      p_reason: reason,
    });
    if (error) {
      logger.error(`[b2b/cancel] RPC: ${error.message}`);
      return fail(res, 500, 'Erreur lors de l\'annulation');
    }
    const result = data as any;
    if (!result?.success) return b2bTransitionError(res, result);

    await createNotification({
      userId: result.other_user_id,
      title: result.new_status === 'rejected' ? 'Commande B2B refusée' : 'Commande B2B annulée',
      message: `La commande ${result.order_number} a été ${result.new_status === 'rejected' ? 'refusée par le fournisseur' : 'annulée'}.${Number(result.refunded_amount) > 0 ? ' Le paiement wallet a été remboursé.' : ''}`,
      type: 'b2b_order_cancelled',
      metadata: {
        link: result.cancelled_by === 'supplier' ? '/vendeur/suppliers?tab=purchases' : '/vendeur/suppliers?tab=b2b',
        purchase_id: result.purchase_id,
        order_id: req.params.orderId,
      },
    });

    return ok(res, { new_status: result.new_status, refunded_amount: result.refunded_amount });
  } catch (error: any) {
    logger.error(`[b2b/cancel] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de l\'annulation');
  }
});

// ═══════════════════════ Bloc 3 — RÉCEPTION (acheteur) ═══════════════════════

const ReceiveSchema = z.object({
  lines: z.array(z.object({
    item_id: z.string().uuid(),
    received_qty: z.number().int().min(0).max(1_000_000),
    buyer_product_id: z.string().uuid().nullish(),
    new_product: z.object({
      name: z.string().max(200).nullish(),
      selling_price: z.number().min(0).nullish(),
      category_id: z.string().uuid().nullish(),
    }).nullish(),
  })).min(1).max(200),
  close: z.boolean().nullish(),
  note: z.string().max(1000).nullish(),
});

/**
 * POST /api/b2b/purchases/:purchaseId/receive — le moment pivot : quantités
 * RÉELLEMENT reçues (partiel autorisé), entrée de stock + PMP par ligne, écarts
 * tracés ; à la clôture : finalisation financière (escrow libéré / transfert
 * on_reception + frais PDG / dette à crédit / dépense).
 */
router.post('/purchases/:purchaseId([0-9a-fA-F-]{36})/receive', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = ReceiveSchema.safeParse(req.body || {});
    if (!parsed.success) {
      return fail(res, 400, parsed.error.issues[0]?.message || 'Données invalides', 'INVALID_PARAMS');
    }
    const input = parsed.data;

    const ctx = await resolveVendorContext(req.user!.id);
    if (!ctx.vendorId) return fail(res, 403, 'Boutique non trouvée', 'VENDOR_NOT_FOUND');
    if (ctx.isAgent && !vendorContextHasPermission(ctx, 'manage_inventory') && !vendorContextHasPermission(ctx, 'manage_suppliers')) {
      return fail(res, 403, 'Permission insuffisante pour réceptionner', 'PERMISSION_DENIED');
    }
    const vendorId = ctx.vendorId;

    // Achat + items pour préparer le paiement on_reception (montants autoritaires).
    const { data: purchase } = await supabaseAdmin
      .from('stock_purchases')
      .select('id, vendor_id, status, payment_mode, payment_timing, currency, linked_order_id')
      .eq('id', req.params.purchaseId)
      .eq('vendor_id', vendorId)
      .maybeSingle();
    if (!purchase) return fail(res, 404, 'Achat introuvable', 'PURCHASE_NOT_FOUND');

    let walletDebit = 0;
    let walletCurrency: string | null = null;
    let buyerFee = 0;
    const p = purchase as any;
    if (p.payment_mode === 'wallet' && p.payment_timing === 'on_reception') {
      // Valeur finale reçue = existant + ce qui arrive maintenant (plafonné à la commande).
      const { data: items } = await supabaseAdmin
        .from('stock_purchase_items')
        .select('id, quantity, received_quantity, purchase_price')
        .eq('purchase_id', p.id);
      const byId = new Map((items || []).map((i: any) => [i.id, i]));
      let receivedValue = 0;
      for (const it of (items || []) as any[]) {
        const incoming = input.lines.find(l => l.item_id === it.id)?.received_qty ?? 0;
        const total = Math.min(it.received_quantity + incoming, it.quantity);
        receivedValue += total * Number(it.purchase_price || 0);
      }
      for (const l of input.lines) {
        if (!byId.has(l.item_id)) return fail(res, 400, 'Ligne inconnue dans cet achat', 'LINE_NOT_FOUND');
      }

      const purchaseCurrency = String(p.currency || 'GNF');
      walletCurrency = await getBuyerCurrency(req.user!.id);
      if (walletCurrency.toUpperCase() === purchaseCurrency.toUpperCase()) {
        walletDebit = roundMoney(receivedValue, walletCurrency);
      } else {
        const fx = await getInternalFxRate(purchaseCurrency, walletCurrency);
        walletDebit = roundMoney(receivedValue * fx.rate, walletCurrency);
      }
      const feePercent = await getBuyerFeePercent();
      buyerFee = roundMoney(walletDebit * (feePercent / 100), walletCurrency);
    }

    const { data, error } = await supabaseAdmin.rpc('receive_b2b_purchase' as any, {
      p_purchase_id: req.params.purchaseId,
      p_buyer_vendor_id: vendorId,
      p_lines: input.lines,
      p_close: input.close ?? false,
      p_note: input.note || null,
      p_wallet_debit_amount: walletDebit,
      p_buyer_wallet_currency: walletCurrency,
      p_buyer_fee_amount: buyerFee,
    });
    if (error) {
      logger.error(`[b2b/receive] RPC: ${error.message}`);
      // Erreurs par LIGNE (RAISE atomique : rien n'a été réceptionné). Format
      // « B2B_RECV:CODE:nom_produit » → message clair identifiant la ligne.
      const m = /B2B_RECV:([A-Z_]+):?(.*)/.exec(error.message);
      if (m) {
        const code = m[1];
        const prod = (m[2] || '').split(/\s*\(/)[0].trim();
        const perLine: Record<string, string> = {
          RECEIVED_EXCEEDS_ORDERED: 'Quantité reçue supérieure au restant attendu',
          BUYER_PRODUCT_INVALID: 'Produit de destination invalide',
          STOCK_ENTRY_FAILED: 'Échec de l\'entrée en stock',
          LINE_NOT_FOUND: 'Ligne introuvable',
          INVALID_RECEIVED_QTY: 'Quantité reçue invalide',
        };
        const base = perLine[code] || 'Réception refusée';
        return fail(res, 409, prod ? `${base} — ligne « ${prod} ». Rien n'a été réceptionné.` : `${base}. Rien n'a été réceptionné.`, code);
      }
      const friendly = /B2B_ESCROW_RELEASE_FAILED/.test(error.message)
        ? 'Échec de la libération de l\'escrow — réception annulée'
        : 'Erreur lors de la réception';
      return fail(res, 500, friendly);
    }
    const result = data as any;
    if (!result?.success) {
      const code = String(result?.error || 'UNKNOWN');
      const messages: Record<string, string> = {
        PURCHASE_NOT_FOUND: 'Achat introuvable',
        INVALID_STATUS: `Réception impossible depuis l'état actuel${result?.status ? ` (${result.status})` : ''}`,
        RECEIVED_EXCEEDS_ORDERED: `Quantité reçue supérieure au restant attendu${result?.product_name ? ` : ${result.product_name}` : ''}`,
        LINE_NOT_FOUND: 'Ligne introuvable',
        BUYER_PRODUCT_INVALID: 'Produit de destination invalide',
        INSUFFICIENT_FUNDS: 'Solde wallet insuffisant pour régler la réception',
        WALLET_NOT_FOUND: 'Wallet introuvable pour cette devise',
        DEBIT_MISMATCH: 'Incohérence de montant détectée — réessayez',
        STOCK_ENTRY_FAILED: 'Échec de l\'entrée en stock',
        EMPTY_LINES: 'Aucune ligne à réceptionner',
      };
      const status = code === 'INSUFFICIENT_FUNDS' ? 402 : code === 'PURCHASE_NOT_FOUND' ? 404 : 409;
      return fail(res, status, messages[code] || 'Réception refusée', code);
    }

    if (result.supplier_user_id) {
      await createNotification({
        userId: result.supplier_user_id,
        title: result.final ? 'Commande B2B réceptionnée' : 'Réception partielle',
        message: result.final
          ? `L'acheteur a réceptionné la commande ${result.order_number}.${p.payment_mode === 'wallet' ? ' Le paiement a été libéré sur votre wallet.' : ''}`
          : `L'acheteur a réceptionné partiellement la commande ${result.order_number} — le reliquat reste attendu.`,
        type: result.final ? 'b2b_order_received' : 'b2b_order_received_partial',
        metadata: { link: '/vendeur/suppliers?tab=b2b', order_id: p.linked_order_id },
      });
    }

    return ok(res, {
      final: !!result.final,
      status: result.status,
      report: result.report,
      gaps: result.gaps,
      received_value: result.received_value,
      ordered_value: result.ordered_value,
      debt_id: result.debt_id ?? null,
    });
  } catch (error: any) {
    logger.error(`[b2b/receive] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de la réception');
  }
});

/**
 * POST /api/b2b/purchases/:purchaseId/release-reliquat — ACHETEUR : « Annuler le
 * reliquat » d'une réception clôturée avec écart. L'argent a déjà été réglé au reçu
 * (receive close) ; ici on REND l'écart au stock VENDABLE du fournisseur + trace +
 * notif. Idempotent.
 */
router.post('/purchases/:purchaseId([0-9a-fA-F-]{36})/release-reliquat', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const ctx = await resolveVendorContext(req.user!.id);
    if (!ctx.vendorId) return fail(res, 403, 'Boutique non trouvée', 'VENDOR_NOT_FOUND');
    if (ctx.isAgent && !vendorContextHasPermission(ctx, 'manage_inventory') && !vendorContextHasPermission(ctx, 'manage_suppliers')) {
      return fail(res, 403, 'Permission insuffisante', 'PERMISSION_DENIED');
    }

    const { data, error } = await supabaseAdmin.rpc('b2b_release_reliquat_to_supplier' as any, {
      p_purchase_id: req.params.purchaseId,
      p_buyer_vendor_id: ctx.vendorId,
    });
    if (error) {
      logger.error(`[b2b/release-reliquat] RPC: ${error.message}`);
      return fail(res, 500, 'Erreur lors de la libération du reliquat');
    }
    const result = data as any;
    if (!result?.success) {
      const code = result?.error || 'RELIQUAT_FAILED';
      const msg = code === 'INVALID_STATUS'
        ? 'La réception doit être clôturée avant de rendre le reliquat.'
        : code === 'PURCHASE_NOT_FOUND' ? 'Achat introuvable' : 'Libération du reliquat impossible';
      return fail(res, 400, msg, code);
    }

    if (!result.already_released && result.supplier_user_id && Number(result.released) > 0) {
      await createNotification({
        userId: result.supplier_user_id,
        title: 'Reliquat B2B annulé',
        message: `L'acheteur a annulé le reliquat de la commande ${result.order_number} — ${result.released} article(s) sont revenus dans votre stock vendable.`,
        type: 'b2b_reliquat_released',
        metadata: { link: '/vendeur/suppliers?tab=b2b', order_number: result.order_number },
      });
    }
    return ok(res, { released: result.released, already_released: !!result.already_released, lines: result.lines });
  } catch (error: any) {
    logger.error(`[b2b/release-reliquat] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de la libération du reliquat');
  }
});

/**
 * POST /api/b2b/purchases/:purchaseId/dispute — ACHETEUR : ouvrir un LITIGE sur un
 * écart de réception. Rattaché au système escrow existant (escrow_disputes, lu par
 * l'interface PDG) — escrow_id nul si le mode de paiement n'a pas d'escrow. Photos
 * possibles (evidence_urls). Fournisseur + PDG notifiés.
 */
router.post('/purchases/:purchaseId([0-9a-fA-F-]{36})/dispute', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const ctx = await resolveVendorContext(req.user!.id);
    if (!ctx.vendorId) return fail(res, 403, 'Boutique non trouvée', 'VENDOR_NOT_FOUND');
    const reason = typeof req.body?.reason === 'string' ? req.body.reason.trim().slice(0, 1000) : '';
    if (!reason) return fail(res, 400, 'Motif du litige requis', 'REASON_REQUIRED');
    const evidenceUrls = Array.isArray(req.body?.evidence_urls)
      ? req.body.evidence_urls.filter((u: unknown) => typeof u === 'string').slice(0, 6) : [];

    const { data: purchase } = await supabaseAdmin
      .from('stock_purchases')
      .select('id, vendor_id, linked_order_id, purchase_number, reception_report')
      .eq('id', req.params.purchaseId)
      .eq('vendor_id', ctx.vendorId)
      .maybeSingle();
    if (!purchase || !(purchase as any).linked_order_id) return fail(res, 404, 'Achat introuvable', 'PURCHASE_NOT_FOUND');
    const pur = purchase as any;

    // Escrow de la commande (peut être absent en crédit / on_reception).
    const { data: escrow } = await supabaseAdmin
      .from('escrow_transactions')
      .select('id, seller_id, status')
      .eq('order_id', pur.linked_order_id)
      .maybeSingle();

    // Anti-doublon : un litige déjà ouvert pour cette commande ?
    const { data: existing } = await supabaseAdmin
      .from('escrow_disputes')
      .select('id')
      .filter('metadata->>purchase_id', 'eq', pur.id)
      .neq('status', 'resolved')
      .limit(1);
    if (existing && existing.length > 0) return fail(res, 400, 'Un litige est déjà en cours pour cette commande', 'DISPUTE_EXISTS');

    const { data: order } = await supabaseAdmin
      .from('orders').select('order_number, vendor_id').eq('id', pur.linked_order_id).maybeSingle();
    const supplierVendorId = (order as any)?.vendor_id;
    const { data: supVendor } = supplierVendorId
      ? await supabaseAdmin.from('vendors').select('user_id').eq('id', supplierVendorId).maybeSingle()
      : { data: null };

    const { data: dispute, error: dErr } = await supabaseAdmin
      .from('escrow_disputes')
      .insert({
        escrow_id: escrow ? (escrow as any).id : null,
        initiator_user_id: req.user!.id,
        initiator_role: 'buyer',
        reason,
        status: 'open',
        evidence_urls: evidenceUrls,
        metadata: {
          b2b: true,
          purchase_id: pur.id,
          purchase_number: pur.purchase_number,
          order_id: pur.linked_order_id,
          gaps: pur.reception_report?.gaps || [],
          request_type: 'b2b_reception_gap',
        },
      })
      .select('id')
      .single();
    if (dErr || !dispute) {
      logger.error(`[b2b/dispute] création: ${dErr?.message}`);
      return fail(res, 500, 'Erreur lors de la création du litige');
    }

    if ((supVendor as any)?.user_id) {
      await createNotification({
        userId: (supVendor as any).user_id,
        title: 'Litige B2B ouvert',
        message: `L'acheteur a ouvert un litige sur la réception de la commande ${(order as any)?.order_number || ''} — motif : ${reason.slice(0, 120)}.`,
        type: 'b2b_dispute_opened',
        metadata: { link: '/vendeur/suppliers?tab=b2b', order_number: (order as any)?.order_number },
      });
    }
    return ok(res, { dispute_id: dispute.id });
  } catch (error: any) {
    logger.error(`[b2b/dispute] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de la création du litige');
  }
});

/**
 * GET /api/b2b/supplier/reliquats — FOURNISSEUR : ses commandes réceptionnées
 * PARTIELLEMENT par l'acheteur (reliquat encore attendu) + les écarts déclarés.
 * Les données vivent dans le stock_purchase de l'ACHETEUR (RLS) → lues ici via
 * service_role et restreintes aux commandes du fournisseur.
 */
router.get('/supplier/reliquats', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const ctx = await resolveVendorContext(req.user!.id);
    if (!ctx.vendorId) return fail(res, 403, 'Boutique non trouvée', 'VENDOR_NOT_FOUND');

    const { data: myOrders } = await supabaseAdmin
      .from('orders').select('id, order_number').eq('vendor_id', ctx.vendorId);
    const orderIds = (myOrders || []).map((o: any) => o.id);
    if (orderIds.length === 0) return ok(res, { reliquats: [] });
    const orderNo = new Map((myOrders || []).map((o: any) => [o.id, o.order_number]));

    const { data: purchases } = await supabaseAdmin
      .from('stock_purchases')
      .select('purchase_number, linked_order_id, reception_report, updated_at')
      .in('linked_order_id', orderIds)
      .eq('status', 'received_partial')
      .order('updated_at', { ascending: false });

    const reliquats = (purchases || []).map((p: any) => {
      const gaps = (p.reception_report?.gaps || []) as Array<{ product_name: string; ordered: number; received: number; gap: number }>;
      return {
        order_number: orderNo.get(p.linked_order_id) || null,
        purchase_number: p.purchase_number,
        updated_at: p.updated_at,
        total_gap: gaps.reduce((s, g) => s + (Number(g.gap) || 0), 0),
        gaps,
      };
    }).filter((r) => r.total_gap > 0);

    return ok(res, { reliquats });
  } catch (error: any) {
    logger.error(`[b2b/supplier/reliquats] ${error?.message}`);
    return fail(res, 500, 'Erreur lors du chargement des reliquats');
  }
});

// ═══════════════════ ESPACE GROSSISTE — LIENS DE VENTE ═══════════════════════

const CreateStockLinkSchema = z.object({
  items: z.array(z.object({
    product_id: z.string().uuid(),
    quantity: z.number().int().min(1).max(1_000_000),
    unit_price: z.number().min(0),
  })).min(1).max(100),
  title: z.string().min(1).max(120),
  target_vendor_id: z.string().uuid().nullish(),
  expires_hours: z.number().int().min(1).max(24 * 90).nullish(),
  single_use: z.boolean().nullish(),
  max_uses: z.number().int().min(1).max(10_000).nullish(),
  allow_credit: z.boolean().nullish(),
  credit_due_days: z.number().int().min(0).max(365).nullish(),
  notes: z.string().max(1000).nullish(),
});

/**
 * POST /api/b2b/links — créer un lien de vente adossé au stock.
 * Usage unique + destinataire ciblé → RÉSERVATION immédiate du stock.
 */
router.post('/links', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = CreateStockLinkSchema.safeParse(req.body);
    if (!parsed.success) {
      return fail(res, 400, parsed.error.issues[0]?.message || 'Données invalides', 'INVALID_PARAMS');
    }
    const input = parsed.data;
    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;
    // 🛡️ Vendre en gros exige le type de vente adapté (jamais bloquant à l'ACHAT).
    if (!(await requireWholesaleSaleType(vendorId, res))) return;

    const singleUse = input.single_use !== false;
    const { data, error } = await supabaseAdmin.rpc('create_b2b_stock_link' as any, {
      p_supplier_vendor_id: vendorId,
      p_items: input.items,
      p_title: input.title,
      p_target_vendor_id: input.target_vendor_id || null,
      p_expires_hours: input.expires_hours ?? 72,
      p_single_use: singleUse,
      p_max_uses: singleUse ? null : (input.max_uses ?? 1),
      p_allow_credit: input.allow_credit ?? false,
      p_credit_due_days: input.credit_due_days ?? null,
      p_currency: 'GNF',
      p_notes: input.notes || null,
    });
    if (error) {
      logger.error(`[b2b/links create] RPC: ${error.message}`);
      return fail(res, 500, 'Erreur lors de la création du lien');
    }
    const result = data as any;
    if (!result?.success) {
      const code = String(result?.error || 'UNKNOWN');
      const messages: Record<string, string> = {
        STOCK_INSUFFICIENT: `Stock insuffisant${result?.product_name ? ` : ${result.product_name} (${result.available} disponible)` : ''}`,
        PRODUCT_NOT_FOUND: 'Un produit sélectionné est introuvable ou inactif',
        MAX_USES_REQUIRED: 'Un plafond total est requis pour un lien multi-usage',
        CREDIT_DUE_REQUIRED: 'Une échéance est requise quand le crédit est autorisé',
        SELF_TARGET: 'Vous ne pouvez pas cibler votre propre boutique',
        TARGET_NOT_FOUND: 'Boutique destinataire introuvable',
        TITLE_REQUIRED: 'Un titre est requis',
        INVALID_LINE: 'Ligne produit invalide',
        EMPTY_ITEMS: 'Aucun produit sélectionné',
        INVALID_TOTAL: 'Le total du lien doit être positif',
      };
      return fail(res, 409, messages[code] || 'Création du lien refusée', code);
    }

    // Notification in-app au client ciblé (jamais bloquant).
    if (input.target_vendor_id) {
      const { data: target } = await supabaseAdmin
        .from('vendors').select('user_id, business_name').eq('id', input.target_vendor_id).maybeSingle();
      const { data: me } = await supabaseAdmin
        .from('vendors').select('business_name').eq('id', vendorId).maybeSingle();
      if (target?.user_id) {
        await createNotification({
          userId: target.user_id,
          title: 'Nouvelle offre fournisseur',
          message: `${me?.business_name || 'Un fournisseur'} vous a envoyé une offre : ${input.title}.`,
          type: 'b2b_stock_link',
          metadata: { link: `/pay/${result.token}`, payment_link_id: result.link_id },
        });
      }
    }

    return ok(res, {
      link_id: result.link_id,
      payment_id: result.payment_id,
      token: result.token,
      total: result.total,
      reserved: result.reserved,
      url_path: `/pay/${result.token}`,
    });
  } catch (error: any) {
    logger.error(`[b2b/links create] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de la création du lien');
  }
});

/** GET /api/b2b/links — mes liens de vente (fournisseur), avec restes. */
router.get('/links', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;

    const { data, error } = await supabaseAdmin
      .from('payment_links')
      .select('id, payment_id, token, title, status, montant, total, devise, expires_at, created_at, paid_at, is_single_use, max_uses, use_count, target_vendor_id, allow_credit, credit_due_days, stock_reserved, gross_amount, metadata')
      .eq('vendeur_id', vendorId)
      .eq('link_type', 'b2b_stock')
      .order('created_at', { ascending: false })
      .limit(200);
    if (error) throw error;

    const rows = (data || []) as any[];
    const targetIds = Array.from(new Set(rows.map(r => r.target_vendor_id).filter(Boolean)));
    let names = new Map<string, string>();
    if (targetIds.length) {
      const { data: vendors } = await supabaseAdmin
        .from('vendors').select('id, business_name').in('id', targetIds);
      names = new Map((vendors || []).map(v => [v.id, v.business_name]));
    }

    // 🖼️ Vignettes produits des cartes de liens : metadata.items ne stocke pas
    // d'image → jointure produits en UNE requête (jamais de N+1), image
    // principale injectée dans la réponse (la base n'est pas modifiée).
    const productIds = Array.from(new Set(rows.flatMap(r =>
      ((r.metadata?.items || []) as Array<{ product_id?: string }>).map(it => it.product_id).filter(Boolean))));
    let images = new Map<string, string | null>();
    if (productIds.length) {
      const { data: prods } = await supabaseAdmin
        .from('products').select('id, images').in('id', productIds as string[]);
      images = new Map((prods || []).map((p: any) => [p.id, (p.images && p.images[0]) || null]));
    }

    return ok(res, rows.map(r => ({
      ...r,
      metadata: r.metadata ? {
        ...r.metadata,
        items: ((r.metadata.items || []) as any[]).map(it => ({
          ...it,
          image: it.image || (it.product_id ? images.get(it.product_id) || null : null),
        })),
      } : r.metadata,
      target_business_name: r.target_vendor_id ? names.get(r.target_vendor_id) || null : null,
      remaining_uses: r.is_single_use
        ? (r.use_count > 0 ? 0 : 1)
        : r.max_uses != null ? Math.max(0, r.max_uses - (r.use_count || 0)) : null,
    })));
  } catch (error: any) {
    logger.error(`[b2b/links list] ${error?.message}`);
    return fail(res, 500, 'Erreur lors du chargement des liens');
  }
});

/** POST /api/b2b/links/:id/cancel — annule + libère la réservation. */
router.post('/links/:id([0-9a-fA-F-]{36})/cancel', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;
    const { data, error } = await supabaseAdmin.rpc('cancel_b2b_stock_link' as any, {
      p_link_id: req.params.id, p_supplier_vendor_id: vendorId,
    });
    if (error) {
      logger.error(`[b2b/links cancel] RPC: ${error.message}`);
      return fail(res, 500, 'Erreur lors de l\'annulation du lien');
    }
    const result = data as any;
    if (!result?.success) return fail(res, 404, 'Lien introuvable', String(result?.error || 'LINK_NOT_FOUND'));
    return ok(res, { released: !!result.released, already: !!result.already });
  } catch (error: any) {
    logger.error(`[b2b/links cancel] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de l\'annulation du lien');
  }
});

/**
 * POST /api/b2b/links/:id/accept — le client-vendeur PAIE (wallet) ou ACCEPTE
 * À CRÉDIT. Crée la commande B2B DÉJÀ CONFIRMÉE (même moteur que le compagnon).
 * Frais acheteur = règle PDG B2B (purchase_fee_percent), fournisseur payé plein prix.
 */
router.post('/links/:id([0-9a-fA-F-]{36})/accept', verifyJWT, idempotencyGuard, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const mode = req.body?.mode === 'credit' ? 'credit' : 'wallet';
    const ctx = await resolveVendorContext(req.user!.id);
    if (!ctx.vendorId) {
      return fail(res, 403, 'Un compte vendeur 224Solutions est requis pour accepter cette offre', 'VENDOR_REQUIRED');
    }
    const customerId = await getOrCreateCustomerId(req.user!.id);

    // Frais acheteur (uniquement paiement wallet) sur le total du lien.
    let buyerFee = 0;
    if (mode === 'wallet') {
      const { data: link } = await supabaseAdmin
        .from('payment_links').select('total, montant, devise').eq('id', req.params.id).maybeSingle();
      const total = Number((link as any)?.total ?? (link as any)?.montant ?? 0);

      // 🔒 PIN au paiement B2B ≥ seuil (politique PDG, relue à chaque appel) —
      // fail-closed si le schéma PIN est absent ; crypto INTACTE (verifyWalletPin).
      if (!(await isPinSchemaAvailableForMoney())) {
        return fail(res, 503, 'Sécurité PIN indisponible — paiement refusé par prudence.', 'PIN_SCHEMA_UNAVAILABLE');
      }
      const { threshold, operations } = await getPinPolicy();
      if (operations.includes('b2b_payment') && total >= threshold) {
        const pinState = await getWalletPinState(req.user!.id);
        const pinEnabled = !!(pinState as any)?.pin_enabled && !!(pinState as any)?.pin_hash;
        if (!pinEnabled) {
          return fail(res, 403, 'Créez votre code PIN pour payer les montants importants (Wallet → Sécurité).', 'PIN_SETUP_REQUIRED');
        }
        const pin = String(req.body?.pin || '');
        if (!pin) return fail(res, 401, 'Code PIN requis pour confirmer ce paiement', 'PIN_REQUIRED');
        const v = await verifyWalletPin(req.user!.id, pin);
        if (!v.valid) return fail(res, 401, v.error || 'Code PIN invalide', 'PIN_INVALID');
      }

      const feePercent = await getBuyerFeePercent();
      buyerFee = roundMoney(total * (feePercent / 100), String((link as any)?.devise || 'GNF'));
    }

    const { data, error } = await supabaseAdmin.rpc('accept_b2b_stock_link' as any, {
      p_link_id: req.params.id,
      p_buyer_user_id: req.user!.id,
      p_buyer_vendor_id: ctx.vendorId,
      p_customer_id: customerId,
      p_mode: mode,
      p_buyer_fee: buyerFee,
    });
    if (error) {
      const m = String(error.message || '');
      logger.warn(`[b2b/links accept] RPC: ${m}`);
      const friendly = /INSUFFICIENT_FUNDS/.test(m) ? 'Solde wallet insuffisant'
        : /WALLET_BLOCKED/.test(m) ? 'Wallet bloqué'
        : /SELLER_WALLET_NOT_FOUND/.test(m) ? 'Le fournisseur n\'a pas de wallet'
        : /BUYER_WALLET_NOT_FOUND/.test(m) ? 'Wallet introuvable'
        : 'Erreur lors de l\'acceptation';
      return fail(res, /INSUFFICIENT_FUNDS/.test(m) ? 402 : 500, friendly);
    }
    const result = data as any;
    if (!result?.success) {
      const code = String(result?.error || 'UNKNOWN');
      const messages: Record<string, string> = {
        LINK_NOT_FOUND: 'Offre introuvable',
        LINK_NOT_PAYABLE: 'Cette offre n\'est plus disponible',
        LINK_EXPIRED: 'Cette offre a expiré',
        LINK_ALREADY_USED: 'Cette offre a déjà été utilisée',
        LINK_EXHAUSTED: 'Le plafond d\'utilisations de cette offre est atteint',
        NOT_TARGET: 'Cette offre est réservée à un autre destinataire',
        CREDIT_NOT_ALLOWED: 'Le paiement à crédit n\'est pas autorisé sur cette offre',
        OWN_LINK: 'Vous ne pouvez pas accepter votre propre offre',
        STOCK_INSUFFICIENT: `Stock fournisseur insuffisant${result?.product_name ? ` : ${result.product_name}` : ''}`,
        BUYER_VENDOR_INVALID: 'Compte vendeur invalide',
      };
      const status = code === 'NOT_TARGET' ? 403 : code === 'LINK_EXPIRED' ? 410 : 409;
      return fail(res, status, messages[code] || 'Acceptation refusée', code);
    }

    await createNotification({
      userId: result.supplier_user_id,
      title: mode === 'wallet' ? 'Offre payée' : 'Offre acceptée à crédit',
      message: `${result.buyer_business_name || 'Un client'} a ${mode === 'wallet' ? 'payé' : 'accepté à crédit'} votre offre ${result.link_payment_id} — commande ${result.order_number} confirmée, il ne reste qu'à expédier.`,
      type: 'b2b_link_accepted_order',
      metadata: { link: '/vendeur/suppliers?tab=b2b', order_id: result.order_id },
    });

    return ok(res, {
      order_id: result.order_id,
      purchase_id: result.purchase_id,
      order_number: result.order_number,
      total: result.total,
      currency: result.currency,
      mode,
      debt_id: result.debt_id ?? null,
      buyer_fee: buyerFee,
    });
  } catch (error: any) {
    logger.error(`[b2b/links accept] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de l\'acceptation');
  }
});

// ═══════════════════ ESPACE GROSSISTE — COCKPIT ══════════════════════════════

/** GET /api/b2b/clients — mes clients-vendeurs liés (annuaire + stats). */
router.get('/clients', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;

    // Fiches où JE suis le fournisseur lié → le propriétaire de la fiche est mon client.
    const { data: fiches, error } = await supabaseAdmin
      .from('vendor_suppliers')
      .select('id, vendor_id, created_at')
      .eq('linked_vendor_id', vendorId)
      .eq('link_status', 'linked');
    if (error) throw error;

    const clientIds = Array.from(new Set((fiches || []).map((f: any) => f.vendor_id)));
    if (clientIds.length === 0) return ok(res, []);

    const [{ data: vendors }, { data: orders }, { data: debts }] = await Promise.all([
      supabaseAdmin.from('vendors').select('id, business_name, logo_url, public_id').in('id', clientIds),
      (supabaseAdmin.from('orders') as any)
        .select('id, total_amount, status, metadata, created_at')
        .eq('vendor_id', vendorId).eq('order_type', 'b2b_purchase').limit(2000),
      supabaseAdmin
        .from('supplier_debts')
        .select('vendor_id, remaining_amount, status, supplier_id, vendor_suppliers!inner(linked_vendor_id)')
        .eq('vendor_suppliers.linked_vendor_id', vendorId)
        .in('status', ['in_progress', 'overdue']),
    ]);

    const vMap = new Map((vendors || []).map((v: any) => [v.id, v]));
    const stats = new Map<string, { orders: number; ca: number; last: string | null }>();
    for (const o of (orders || []) as any[]) {
      const buyer = o.metadata?.buyer_vendor_id;
      if (!buyer || !clientIds.includes(buyer)) continue;
      const s = stats.get(buyer) || { orders: 0, ca: 0, last: null };
      s.orders += 1;
      if (['delivered', 'completed'].includes(o.status)) s.ca += Number(o.total_amount || 0);
      if (!s.last || o.created_at > s.last) s.last = o.created_at;
      stats.set(buyer, s);
    }
    const debtMap = new Map<string, number>();
    for (const d of (debts || []) as any[]) {
      debtMap.set(d.vendor_id, (debtMap.get(d.vendor_id) || 0) + Number(d.remaining_amount || 0));
    }

    return ok(res, (fiches || []).map((f: any) => ({
      supplier_row_id: f.id,
      client_vendor_id: f.vendor_id,
      business_name: vMap.get(f.vendor_id)?.business_name || null,
      logo_url: vMap.get(f.vendor_id)?.logo_url || null,
      public_id: vMap.get(f.vendor_id)?.public_id || null,
      linked_since: f.created_at,
      orders_count: stats.get(f.vendor_id)?.orders || 0,
      ca_total: stats.get(f.vendor_id)?.ca || 0,
      last_order_at: stats.get(f.vendor_id)?.last || null,
      outstanding_credit: debtMap.get(f.vendor_id) || 0,
    })).sort((a, b) => b.ca_total - a.ca_total));
  } catch (error: any) {
    logger.error(`[b2b/clients] ${error?.message}`);
    return fail(res, 500, 'Erreur lors du chargement des clients');
  }
});

/** GET /api/b2b/receivables — mes CRÉANCES (dettes clients vues du créancier). */
router.get('/receivables', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;

    const { data, error } = await supabaseAdmin
      .from('supplier_debts')
      .select('id, vendor_id, purchase_id, total_amount, paid_amount, remaining_amount, minimum_installment, due_date, currency, status, created_at, vendor_suppliers!inner(linked_vendor_id)')
      .eq('vendor_suppliers.linked_vendor_id', vendorId)
      .order('due_date', { ascending: true, nullsFirst: false })
      .limit(500);
    if (error) throw error;

    const rows = (data || []) as any[];
    const debtorIds = Array.from(new Set(rows.map(r => r.vendor_id)));
    let names = new Map<string, string>();
    if (debtorIds.length) {
      const { data: vendors } = await supabaseAdmin
        .from('vendors').select('id, business_name').in('id', debtorIds);
      names = new Map((vendors || []).map((v: any) => [v.id, v.business_name]));
    }
    return ok(res, rows.map(r => ({
      id: r.id,
      debtor_vendor_id: r.vendor_id,
      debtor_business_name: names.get(r.vendor_id) || null,
      purchase_id: r.purchase_id,
      total_amount: r.total_amount,
      paid_amount: r.paid_amount,
      remaining_amount: r.remaining_amount,
      due_date: r.due_date,
      currency: r.currency,
      status: r.status,
      created_at: r.created_at,
    })));
  } catch (error: any) {
    logger.error(`[b2b/receivables] ${error?.message}`);
    return fail(res, 500, 'Erreur lors du chargement des créances');
  }
});

/** GET /api/b2b/kpis?days=30 — cockpit fournisseur : CA B2B, états, créances, top clients. */
router.get('/kpis', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const vendorId = await requireSupplierContext(req, res);
    if (!vendorId) return;
    const days = Math.min(Math.max(parseInt(String(req.query.days)) || 30, 1), 365);
    const since = new Date(Date.now() - days * 86_400_000).toISOString();

    const [{ data: orders }, { data: debts }] = await Promise.all([
      (supabaseAdmin.from('orders') as any)
        .select('id, total_amount, status, metadata, created_at')
        .eq('vendor_id', vendorId).eq('order_type', 'b2b_purchase')
        .gte('created_at', since).limit(5000),
      supabaseAdmin
        .from('supplier_debts')
        .select('remaining_amount, due_date, status, vendor_suppliers!inner(linked_vendor_id)')
        .eq('vendor_suppliers.linked_vendor_id', vendorId)
        .in('status', ['in_progress', 'overdue']),
    ]);

    const rows = (orders || []) as any[];
    const byState: Record<string, number> = {};
    let ca = 0;
    const perClient = new Map<string, { name: string; ca: number; orders: number }>();
    for (const o of rows) {
      byState[o.status] = (byState[o.status] || 0) + 1;
      const isDone = ['delivered', 'completed'].includes(o.status);
      if (isDone) ca += Number(o.total_amount || 0);
      const buyer = o.metadata?.buyer_vendor_id;
      if (buyer) {
        const c = perClient.get(buyer) || { name: o.metadata?.buyer_business_name || '', ca: 0, orders: 0 };
        c.orders += 1;
        if (isDone) c.ca += Number(o.total_amount || 0);
        perClient.set(buyer, c);
      }
    }
    const today = new Date().toISOString().slice(0, 10);
    let receivablesTotal = 0;
    let receivablesOverdue = 0;
    for (const d of (debts || []) as any[]) {
      receivablesTotal += Number(d.remaining_amount || 0);
      if (d.status === 'overdue' || (d.due_date && d.due_date < today)) {
        receivablesOverdue += Number(d.remaining_amount || 0);
      }
    }

    return ok(res, {
      period_days: days,
      ca_b2b: ca,
      orders_total: rows.length,
      orders_by_state: byState,
      receivables_total: receivablesTotal,
      receivables_overdue: receivablesOverdue,
      top_clients: Array.from(perClient.entries())
        .map(([vendor_id, c]) => ({ vendor_id, business_name: c.name, ca: c.ca, orders: c.orders }))
        .sort((a, b) => b.ca - a.ca)
        .slice(0, 5),
    });
  } catch (error: any) {
    logger.error(`[b2b/kpis] ${error?.message}`);
    return fail(res, 500, 'Erreur lors du chargement des indicateurs');
  }
});

export default router;
