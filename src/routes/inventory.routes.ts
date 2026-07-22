/**
 * 📊 INVENTORY ROUTES - Phase 4
 *
 * Gestion du stock 100% côté backend Node.js.
 *
 * Tables utilisées :
 *   - `products` : stock_quantity (source de vérité)
 *   - `inventory_history` : journal des mouvements
 *   - `vendors` : résolution vendeur
 *
 * Opérations :
 *   - Consultation stock
 *   - Ajustement manuel (avec raison obligatoire)
 *   - Historique des mouvements
 *   - Alertes stock bas
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { inventoryRateLimit } from '../middlewares/routeRateLimiter.js';
import { resolveVendorId as resolveVendorIdCtx, resolveVendorContext, vendorContextHasPermission } from '../services/vendorContext.service.js';
import { z } from 'zod';

const router = Router();

// ==================== VALIDATION SCHEMAS ====================

const StockAdjustmentSchema = z.object({
  product_id: z.string().uuid('product_id invalide'),
  adjustment: z.number().int('L\'ajustement doit être un entier')
    .refine(val => val !== 0, 'L\'ajustement ne peut pas être 0'),
  reason: z.enum([
    'restock',
    'manual_correction',
    'damaged',
    'lost',
    'returned',
    'count_adjustment',
    'other',
  ]),
  notes: z.string().max(500).nullish(),
});

const BatchAdjustmentSchema = z.object({
  adjustments: z.array(StockAdjustmentSchema).min(1).max(100),
});

// ==================== HELPERS ====================

async function resolveVendorId(userId: string): Promise<string | null> {
  // Agent-aware : vendeur direct OU agent vendeur actif → le vendeur de l'agent.
  return resolveVendorIdCtx(userId);
}

// ==================== ROUTES ====================

/**
 * POST /api/inventory/validate-purchase
 * Valide un achat de stock ATOMIQUEMENT (RPC validate_stock_purchase) : dépense + stock
 * + prix + fournisseurs + verrouillage, en une seule transaction. Migre l'Edge Function
 * `validate-purchase` vers le backend Node. SÉCURITÉ (absente de l'edge) : agent-aware +
 * l'appelant ne peut valider QUE les achats de SON vendeur (propriété vérifiée).
 */
const ValidatePurchaseSchema = z.object({
  purchase_id: z.string().uuid('purchase_id invalide'),
  vendor_id: z.string().uuid('vendor_id invalide').optional(),
  purchase_number: z.string().min(1).max(100),
  total_amount: z.number().min(0),
  items: z.array(z.object({
    product_id: z.string().uuid().nullish(),
    product_name: z.string().max(300).nullish(),
    quantity: z.number(),
    received_quantity: z.number().min(0).nullish(),  // réception par ligne (défaut = commandé)
    purchase_price: z.number().nullish(),
    selling_price: z.number().nullish(),
    supplier_id: z.string().uuid().nullish(),
    missing_reason: z.string().max(50).nullish(),
    missing_notes: z.string().max(500).nullish(),
  })).min(1, 'Au moins un article requis'),
});

router.post('/validate-purchase', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const parsed = ValidatePurchaseSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ success: false, error: parsed.error.issues[0]?.message || 'Données invalides' });
      return;
    }
    const { purchase_id, vendor_id, purchase_number, total_amount, items } = parsed.data;

    // Auth agent-aware : vendeur direct OU agent vendeur actif
    const ctx = await resolveVendorContext(req.user!.id);
    if (!ctx.vendorId) { res.status(403).json({ success: false, error: 'Boutique non trouvée' }); return; }
    // Propriété : on ne valide que les achats de SON vendeur
    if (vendor_id && vendor_id !== ctx.vendorId) {
      res.status(403).json({ success: false, error: 'Vous ne pouvez valider que les achats de votre boutique' });
      return;
    }
    // Permission agent (le vendeur direct a tout)
    if (ctx.isAgent && !vendorContextHasPermission(ctx, 'manage_inventory') && !vendorContextHasPermission(ctx, 'manage_suppliers')) {
      res.status(403).json({ success: false, error: 'Permission insuffisante pour valider un achat' });
      return;
    }

    const { data, error } = await supabaseAdmin.rpc('validate_stock_purchase', {
      p_purchase_id: purchase_id,
      p_vendor_id: ctx.vendorId,
      p_items: items,
      p_purchase_number: purchase_number,
      p_total_amount: total_amount,
    });
    if (error) {
      logger.error(`[inventory/validate-purchase] RPC: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors de la validation de l\'achat' });
      return;
    }
    const result = data as any;
    if (result && result.success === false) { res.status(400).json({ success: false, error: result.error }); return; }
    res.json({ success: true, data: result, ...result });
  } catch (err: any) {
    logger.error(`[inventory/validate-purchase] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

/**
 * POST /api/inventory/pay-supplier-debt
 * Règle une tranche de dette fournisseur ATOMIQUEMENT (RPC pay_supplier_debt) :
 * débit wallet + maj dette + statut. Agent-aware + propriété.
 */
router.post('/pay-supplier-debt', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const { debt_id, amount, idempotency_key } = req.body || {};
    if (!debt_id || typeof debt_id !== 'string') { res.status(400).json({ success: false, error: 'debt_id requis' }); return; }
    const amt = Number(amount);
    if (!Number.isFinite(amt) || amt <= 0) { res.status(400).json({ success: false, error: 'Montant invalide' }); return; }

    const ctx = await resolveVendorContext(req.user!.id);
    if (!ctx.vendorId) { res.status(403).json({ success: false, error: 'Boutique non trouvée' }); return; }
    if (ctx.isAgent && !vendorContextHasPermission(ctx, 'manage_suppliers') && !vendorContextHasPermission(ctx, 'manage_inventory')) {
      res.status(403).json({ success: false, error: 'Permission insuffisante pour régler une dette' });
      return;
    }

    const { data, error } = await supabaseAdmin.rpc('pay_supplier_debt', {
      p_debt_id: debt_id,
      p_vendor_id: ctx.vendorId,
      p_amount: amt,
      p_idempotency_key: idempotency_key || null,
    });
    if (error) {
      logger.error(`[inventory/pay-supplier-debt] RPC: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors du règlement' });
      return;
    }
    const result = data as any;
    if (result && result.success === false) {
      const msg = String(result.error || '');
      const code = msg.includes('INSUFFICIENT_FUNDS') ? 402 : msg.includes('EXCEEDS') ? 400 : 400;
      const friendly = msg.includes('INSUFFICIENT_FUNDS') ? 'Solde insuffisant'
        : msg.includes('AMOUNT_EXCEEDS_REMAINING') ? 'Le montant dépasse le restant dû'
        : msg.includes('DEBT_NOT_FOUND') ? 'Dette introuvable' : 'Échec du règlement';
      res.status(code).json({ success: false, error: friendly });
      return;
    }
    res.json({ success: true, data: result, ...result });
  } catch (err: any) {
    logger.error(`[inventory/pay-supplier-debt] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur interne' });
  }
});

/**
 * GET /api/inventory/stock
 * Vue d'ensemble du stock du vendeur
 */
router.get('/stock', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const vendorId = await resolveVendorId(req.user!.id);
    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const lowStockOnly = req.query.low_stock === 'true';

    let query = supabaseAdmin
      .from('products')
      .select('id, name, sku, stock_quantity, low_stock_threshold, is_active, images')
      .eq('vendor_id', vendorId)
      .eq('is_active', true)
      .order('stock_quantity', { ascending: true });

    if (lowStockOnly) {
      // Produits dont le stock est <= au seuil d'alerte
      query = query.not('low_stock_threshold', 'is', null);
    }

    const { data, error } = await query;
    if (error) throw error;

    let products = data || [];

    // Filtrer côté serveur pour le seuil (PostgREST ne supporte pas column <= column)
    if (lowStockOnly) {
      products = products.filter(p =>
        p.low_stock_threshold !== null &&
        (p.stock_quantity ?? 0) <= p.low_stock_threshold
      );
    }

    // Statistiques résumées
    const totalProducts = products.length;
    const outOfStock = products.filter(p => (p.stock_quantity ?? 0) === 0).length;
    const lowStock = products.filter(p =>
      p.low_stock_threshold !== null &&
      (p.stock_quantity ?? 0) > 0 &&
      (p.stock_quantity ?? 0) <= p.low_stock_threshold
    ).length;

    res.json({
      success: true,
      data: products,
      summary: {
        total_products: totalProducts,
        out_of_stock: outOfStock,
        low_stock: lowStock,
        healthy: totalProducts - outOfStock - lowStock,
      },
    });
  } catch (error: any) {
    logger.error(`Inventory stock error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * POST /api/inventory/adjust
 * Ajustement de stock (unitaire ou par lot)
 *
 * Chaque ajustement :
 *   1. Vérifie que le produit appartient au vendeur
 *   2. Vérifie que le stock résultant ne sera pas négatif
 *   3. Met à jour le stock
 *   4. Enregistre le mouvement dans l'historique
 */
router.post('/adjust', verifyJWT, inventoryRateLimit, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const vendorId = await resolveVendorId(userId);
    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const validation = BatchAdjustmentSchema.safeParse(req.body);
    if (!validation.success) {
      res.status(400).json({
        success: false,
        error: 'Données invalides',
        details: validation.error.issues.map(e => ({
          field: e.path.join('.'),
          message: e.message,
        })),
      });
      return;
    }

    const { adjustments } = validation.data;
    const results: Array<{
      product_id: string;
      status: 'success' | 'error';
      old_stock?: number;
      new_stock?: number;
      error?: string;
    }> = [];

    for (const adj of adjustments) {
      try {
        // Ajustement ATOMIQUE : verrou de ligne (FOR UPDATE) + garde anti-négatif
        // + historique dans la même transaction → plus de lost-update sous concurrence.
        const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc('adjust_product_stock_atomic' as any, {
          p_product_id: adj.product_id,
          p_vendor_id: vendorId,
          p_adjustment: adj.adjustment,
          p_reason: adj.reason,
          p_notes: adj.notes || null,
          p_user_id: userId,
        });

        if (rpcError) throw rpcError;

        const r = rpcResult as { status: 'success' | 'error'; old_stock?: number; new_stock?: number; error?: string };

        if (r.status === 'error') {
          results.push({
            product_id: adj.product_id,
            status: 'error',
            old_stock: r.old_stock,
            error: r.error,
          });
          continue;
        }

        results.push({
          product_id: adj.product_id,
          status: 'success',
          old_stock: r.old_stock,
          new_stock: r.new_stock,
        });

        logger.info(`Stock adjusted: product=${adj.product_id}, ${r.old_stock} → ${r.new_stock} (${adj.reason})`);
      } catch (adjError: any) {
        results.push({
          product_id: adj.product_id,
          status: 'error',
          error: adjError.message,
        });
      }
    }

    const successes = results.filter(r => r.status === 'success').length;
    const errors = results.filter(r => r.status === 'error').length;

    res.json({
      success: errors === 0,
      data: { results, summary: { total: adjustments.length, successes, errors } },
    });
  } catch (error: any) {
    logger.error(`Inventory adjustment error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * GET /api/inventory/history
 * Historique des mouvements de stock
 */
router.get('/history', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const vendorId = await resolveVendorId(req.user!.id);
    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const limit = Math.min(parseInt(req.query.limit as string) || 50, 200);
    const offset = parseInt(req.query.offset as string) || 0;
    const productId = req.query.product_id as string;

    let query = supabaseAdmin
      .from('inventory_history')
      .select('*, product:products(id, name, sku)', { count: 'exact' })
      .eq('vendor_id', vendorId)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (productId) {
      query = query.eq('product_id', productId);
    }

    const { data, error, count } = await query;
    if (error) throw error;

    res.json({
      success: true,
      data: data || [],
      meta: { limit, offset, total: count || 0 },
    });
  } catch (error: any) {
    logger.error(`Inventory history error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

export default router;
