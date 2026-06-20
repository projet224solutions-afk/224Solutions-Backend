/**
 * 📦 PRODUCTS ROUTES - Phase 3
 * 
 * Tables utilisées :
 *   - `products` : name, price, images, vendor_id, is_active, stock_quantity, etc.
 *   - `vendors` : pour résoudre vendor_id depuis user_id
 *   - `plans` + `subscriptions` : pour appliquer les limites max_products et max_images_per_product
 * 
 * Limites appliquées côté backend :
 *   1. max_products — blocage de la création si quota atteint
 *   2. max_images_per_product — troncature automatique du tableau images[]
 * 
 * Le trigger DB `trg_enforce_product_limit` reste actif comme filet de sécurité,
 * mais le backend valide AVANT pour donner des messages d'erreur explicites.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { z } from 'zod';
import { resolveVendorId as resolveVendorIdCtx } from '../services/vendorContext.service.js';
import {
  shouldBlockActiveProductCreation,
  shouldBlockProductReactivation,
} from '../lib/productQuotaApiRules.js';

// ==================== VALIDATION SCHEMAS ====================

const BaseProductSchema = z.object({
  name: z.string().trim()
    .min(2, 'Nom requis (min 2 caractères)')
    .max(200, 'Nom trop long (max 200 caractères)'),
  price: z.number()
    .min(0, 'Le prix doit être >= 0')
    .max(1_000_000_000, 'Prix trop élevé'),
  description: z.string().trim().max(5000, 'Description trop longue').nullish(),
  category_id: z.string().uuid('category_id invalide').nullish(),
  stock_quantity: z.number().int().min(0, 'Stock ne peut pas être négatif').default(0),
  is_active: z.boolean().default(true),
  images: z.array(z.string().url('URL image invalide')).max(20).default([]),
  compare_price: z.number().min(0).nullish(),
  cost_price: z.number().min(0).nullish(),
  sku: z.string().trim().max(100).nullish(),
  tags: z.array(z.string().max(50)).max(20).nullish(),
  weight: z.number().min(0).nullish(),
  dimensions: z.string().max(100).nullish(),
  free_shipping: z.boolean().default(false),
  low_stock_threshold: z.number().int().min(0).nullish(),
  seo_title: z.string().max(200).nullish(),
  seo_description: z.string().max(500).nullish(),
  sell_by_carton: z.boolean().default(false),
  price_carton: z.number().min(0).nullish(),
  units_per_carton: z.number().int().min(1).nullish(),
  carton_sku: z.string().max(100).nullish(),
  // Champs additionnels gérés par le frontend (POS, médias, section, id public)
  public_id: z.string().max(20).nullish(),
  barcode: z.string().max(100).nullish(),
  barcode_value: z.string().max(100).nullish(),
  barcode_format: z.string().max(20).nullish(),
  section: z.string().max(100).nullish(),
  promotional_videos: z.array(z.string().url()).max(5).nullish(),
});

// Règle : le prix barré (compare_price) doit être > prix de vente (sinon barré incohérent)
const priceConsistency = (d: { price?: number | null; compare_price?: number | null }) =>
  d.compare_price == null || d.price == null || d.compare_price > d.price;
const PRICE_RULE = {
  message: 'Le prix barré doit être supérieur au prix de vente',
  path: ['compare_price'] as (string | number)[],
};

const CreateProductSchema = BaseProductSchema.refine(priceConsistency, PRICE_RULE);
const UpdateProductSchema = BaseProductSchema.partial().refine(priceConsistency, PRICE_RULE);

const router = Router();

// Fallback plan gratuit — sera chargé dynamiquement depuis la DB
// Ne plus jamais hardcoder ces valeurs
let FREE_PLAN_LIMITS = {
  max_products: 5 as number | null,
  max_images_per_product: 3 as number | null,
};


// Charger les limites du plan gratuit depuis la DB au premier appel
let freePlanLoaded = false;
async function loadFreePlanLimits() {
  if (freePlanLoaded) return;
  try {
    const { data } = await supabaseAdmin
      .from('plans')
      .select('max_products, max_images_per_product')
      .eq('name', 'free')
      .eq('is_active', true)
      .maybeSingle();
    if (data) {
      FREE_PLAN_LIMITS.max_products = data.max_products;
      FREE_PLAN_LIMITS.max_images_per_product = data.max_images_per_product;
    }
    freePlanLoaded = true;
  } catch (e) {
    console.error('Failed to load free plan limits from DB:', e);
  }
}

// ==================== HELPERS ====================

/**
 * Résout le vendor_id depuis le user_id authentifié.
 * Agent-aware : vendeur direct OU agent vendeur actif → le vendeur de l'agent.
 */
async function resolveVendorId(userId: string): Promise<string | null> {
  return resolveVendorIdCtx(userId);
}

/**
 * Récupère les limites du plan actif du vendeur.
 * Fallback vers les limites du plan gratuit si aucun abonnement actif.
 */
async function getVendorLimits(userId: string): Promise<{
  max_products: number | null;
  max_images_per_product: number | null;
  plan_name: string;
}> {
  // Accepter 'active' ET 'trialing' — un vendeur en période d'essai
  // doit pouvoir utiliser les limites de son plan, sinon il retombe
  // sur le plan gratuit et l'essai n'a aucun intérêt.
  const { data: sub } = await supabaseAdmin
    .from('subscriptions')
    .select('plans(name, max_products, max_images_per_product)')
    .eq('user_id', userId)
    .in('status', ['active', 'trialing'])
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const plan = (sub as any)?.plans;
  if (plan) {
    return {
      max_products: plan.max_products,
      max_images_per_product: plan.max_images_per_product,
      plan_name: plan.name,
    };
  }

  // Charger les limites du plan gratuit depuis la DB
  await loadFreePlanLimits();

  return {
    max_products: FREE_PLAN_LIMITS.max_products,
    max_images_per_product: FREE_PLAN_LIMITS.max_images_per_product,
    plan_name: 'free',
  };
}

/**
 * Synchronise la table `inventory` (miroir de products.stock_quantity).
 * NB : l'atomicité forte est garantie par le trigger DB sync_product_inventory
 * (migration 20260603140000) ; cet upsert reste un filet côté backend.
 */
async function upsertInventory(productId: string, quantity: number): Promise<{ error: any }> {
  const { error } = await supabaseAdmin
    .from('inventory')
    .upsert(
      [{ product_id: productId, quantity, last_updated: new Date().toISOString() }],
      { onConflict: 'product_id' }
    );
  return { error };
}

/**
 * Compte les produits actifs d'un vendeur
 */
async function countActiveProducts(vendorId: string): Promise<number> {
  const { count } = await supabaseAdmin
    .from('products')
    .select('id', { count: 'exact', head: true })
    .eq('vendor_id', vendorId)
    .eq('is_active', true);
  return count || 0;
}

// ==================== ROUTES ====================

/**
 * GET /api/products/mine
 * Liste les produits du vendeur connecté (paginé)
 */
router.get('/mine', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const vendorId = await resolveVendorId(req.user!.id);
    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const limit = Math.min(parseInt(req.query.limit as string) || 20, 100);
    const offset = parseInt(req.query.offset as string) || 0;
    const activeOnly = req.query.active !== 'false';

    let query = supabaseAdmin
      .from('products')
      .select('*', { count: 'exact' })
      .eq('vendor_id', vendorId)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (activeOnly) {
      query = query.eq('is_active', true);
    }

    const { data, error, count } = await query;
    if (error) throw error;

    res.json({
      success: true,
      data: data || [],
      meta: { limit, offset, total: count || 0, hasMore: (offset + limit) < (count || 0) }
    });
  } catch (error: any) {
    logger.error(`Error listing products: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * GET /api/products/limits
 * Retourne les limites du plan + usage actuel du vendeur
 */
router.get('/limits', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const vendorId = await resolveVendorId(userId);
    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    const [limits, currentCount] = await Promise.all([
      getVendorLimits(userId),
      countActiveProducts(vendorId),
    ]);

    const canCreate = limits.max_products === null || currentCount < limits.max_products;

    res.json({
      success: true,
      data: {
        plan_name: limits.plan_name,
        max_products: limits.max_products,
        max_images_per_product: limits.max_images_per_product,
        current_products: currentCount,
        can_create: canCreate,
        remaining: limits.max_products === null ? null : Math.max(0, limits.max_products - currentCount),
      }
    });
  } catch (error: any) {
    logger.error(`Error fetching product limits: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * POST /api/products
 * Créer un produit — avec validation des limites du plan
 * 
 * Contrôles effectués :
 *   1. L'utilisateur a une boutique (vendor_id résolu)
 *   2. Le nombre de produits actifs < max_products du plan
 *   3. Le nombre d'images <= max_images_per_product du plan (troncature si dépassement)
 */
router.post('/', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const vendorId = await resolveVendorId(userId);
    const requestedActive = req.body?.is_active !== false;

    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée. Créez d\'abord votre boutique.' });
      return;
    }

    // 1. Vérifier les limites du plan
    const [limits, currentCount] = await Promise.all([
      getVendorLimits(userId),
      countActiveProducts(vendorId),
    ]);

    // 2. Bloquer si quota max_products atteint
    const createDecision = shouldBlockActiveProductCreation(requestedActive, limits, currentCount);
    if (createDecision.blocked) {
      logger.warn(`Product creation blocked: vendor=${vendorId}, current=${currentCount}, max=${limits.max_products}, plan=${limits.plan_name}`);
      res.status(403).json({
        success: false,
        error: 'Limite de produits atteinte',
        message: createDecision.message,
        current: createDecision.current,
        max: createDecision.max,
        plan: createDecision.plan,
      });
      return;
    }

    // 3. Contrôler et tronquer les images si nécessaire
    let images: string[] = req.body.images || [];
    let imagesTruncated = false;

    if (limits.max_images_per_product !== null && images.length > limits.max_images_per_product) {
      logger.info(`Images truncated: ${images.length} → ${limits.max_images_per_product} for vendor=${vendorId}, plan=${limits.plan_name}`);
      images = images.slice(0, limits.max_images_per_product);
      imagesTruncated = true;
    }

    // 4. Valider le payload avec Zod
    const validation = CreateProductSchema.safeParse(req.body);
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

    const validated = validation.data;

    // 5. Construire l'objet produit avec données validées
    const productData: Record<string, any> = {
      vendor_id: vendorId,
      ...validated,
      images, // version potentiellement tronquée
    };

    // 5. Insérer le produit
    const { data: product, error } = await supabaseAdmin
      .from('products')
      .insert(productData)
      .select('*')
      .single();

    if (error) {
      // Intercepter l'erreur du trigger DB (filet de sécurité)
      if (error.message?.includes('limit') || error.message?.includes('maximum')) {
        res.status(403).json({
          success: false,
          error: 'Limite de produits atteinte (validation DB)',
          message: error.message,
        });
        return;
      }
      throw error;
    }

    // Sync inventaire (atomique : si échec, on annule la création du produit)
    const inv = await upsertInventory(product.id, validated.stock_quantity ?? 0);
    if (inv.error) {
      await supabaseAdmin.from('products').delete().eq('id', product.id);
      logger.error(`Inventory sync failed, product creation rolled back: ${inv.error.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors de la synchronisation de l\'inventaire' });
      return;
    }

    logger.info(`Product created: ${product.id} by vendor=${vendorId}, plan=${limits.plan_name}, count=${currentCount + 1}/${limits.max_products || '∞'}`);

    res.status(201).json({
      success: true,
      data: product,
      warnings: imagesTruncated
        ? [`Images tronquées à ${limits.max_images_per_product} (limite du plan "${limits.plan_name}")`]
        : undefined,
    });
  } catch (error: any) {
    logger.error(`Error creating product: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la création du produit' });
  }
});

/**
 * PATCH /api/products/:productId
 * Mise à jour d'un produit existant — avec contrôle max_images_per_product
 */
router.patch('/:productId', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { productId } = req.params;
    const vendorId = await resolveVendorId(userId);

    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    // Vérifier que le produit appartient bien au vendeur
    const { data: existing, error: fetchError } = await supabaseAdmin
      .from('products')
      .select('id, vendor_id, is_active')
      .eq('id', productId)
      .single();

    if (fetchError || !existing) {
      res.status(404).json({ success: false, error: 'Produit non trouvé' });
      return;
    }

    if (existing.vendor_id !== vendorId) {
      res.status(403).json({ success: false, error: 'Ce produit ne vous appartient pas' });
      return;
    }

    const requestedActive = req.body?.is_active;
    if (existing && existing.vendor_id === vendorId && existing.id) {
      const [limits, currentCount] = await Promise.all([
        getVendorLimits(userId),
        countActiveProducts(vendorId),
      ]);

      const reactivationDecision = shouldBlockProductReactivation(existing.is_active, requestedActive, limits, currentCount);
      if (reactivationDecision.blocked) {
        res.status(403).json({
          success: false,
          error: 'Limite de produits atteinte',
          message: reactivationDecision.message,
          current: reactivationDecision.current,
          max: reactivationDecision.max,
          plan: reactivationDecision.plan,
        });
        return;
      }
    }


    // Valider le payload partiel avec Zod
    const validation = UpdateProductSchema.safeParse(req.body);
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

    const updates: Record<string, any> = { ...validation.data };

    if (Object.keys(updates).length === 0) {
      res.status(400).json({ success: false, error: 'Aucun champ à mettre à jour' });
      return;
    }

    // Contrôle images si mises à jour
    let imagesTruncated = false;
    if (updates.images && Array.isArray(updates.images)) {
      const limits = await getVendorLimits(userId);
      if (limits.max_images_per_product !== null && updates.images.length > limits.max_images_per_product) {
        updates.images = updates.images.slice(0, limits.max_images_per_product);
        imagesTruncated = true;
      }
    }

    updates.updated_at = new Date().toISOString();

    const { data, error } = await supabaseAdmin
      .from('products')
      .update(updates)
      .eq('id', productId)
      .select('*')
      .single();

    if (error) throw error;

    // Sync inventaire si le stock a été modifié
    if (updates.stock_quantity !== undefined) {
      const inv = await upsertInventory(productId, updates.stock_quantity);
      if (inv.error) logger.warn(`[products PATCH] inventory sync: ${inv.error.message}`);
    }

    logger.info(`Product updated: ${productId} by vendor=${vendorId}`);
    res.json({
      success: true,
      data,
      warnings: imagesTruncated
        ? [`Images tronquées à la limite du plan`]
        : undefined,
    });
  } catch (error: any) {
    logger.error(`Error updating product: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la mise à jour' });
  }
});

/**
 * DELETE /api/products/:productId
 * Soft-delete uniquement (is_active = false).
 * Le hard-delete n'est pas exposé aux vendeurs — il est réservé
 * aux opérations admin internes pour éviter toute perte de données
 * accidentelle (commandes liées, historique, analytics).
 */
router.delete('/:productId', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { productId } = req.params;
    const vendorId = await resolveVendorId(userId);

    if (!vendorId) {
      res.status(404).json({ success: false, error: 'Boutique non trouvée' });
      return;
    }

    // Vérifier propriété
    const { data: existing } = await supabaseAdmin
      .from('products')
      .select('id, vendor_id')
      .eq('id', productId)
      .single();

    if (!existing || existing.vendor_id !== vendorId) {
      res.status(404).json({ success: false, error: 'Produit non trouvé ou non autorisé' });
      return;
    }

    const { error } = await supabaseAdmin
      .from('products')
      .update({ is_active: false, updated_at: new Date().toISOString() })
      .eq('id', productId);
    if (error) throw error;

    logger.info(`Product soft-deleted: ${productId} by vendor=${vendorId}`);
    res.json({ success: true, message: 'Produit désactivé' });
  } catch (error: any) {
    logger.error(`Error deleting product: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la suppression' });
  }
});

export default router;
