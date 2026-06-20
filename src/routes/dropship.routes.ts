/**
 * 🛍️ DROPSHIPPING — Phase 1 : bridge « importé → vendable »
 * ---------------------------------------------------------------------------
 * Publie un produit dropship dans le catalogue marketplace (`products`) pour le
 * rendre ACHETABLE, ou le dépublie. Tout passe par des RPC atomiques
 * (publish/unpublish_dropship_product) qui contrôlent la propriété côté serveur.
 */

import { Router, Response } from 'express';
import { verifyJWT, requireRole } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { placeDropshipOrder } from '../services/dropship/placementService.js';
import { syncAllDropshipProducts } from '../services/dropship/syncService.js';
import { syncTrackingForOrder } from '../services/dropship/trackingService.js';

const router = Router();
const PDG_ROLES = ['admin', 'pdg', 'ceo'];

/** POST /api/v2/dropship/:dropshipId/publish — rend le produit importé achetable. */
router.post('/:dropshipId/publish', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { dropshipId } = req.params;
    const { data, error } = await supabaseAdmin.rpc('publish_dropship_product', {
      p_dropship_id: dropshipId,
      p_actor_user_id: req.user!.id,
    });
    if (error) {
      const code = error.message?.includes('NOT_OWNER') ? 403
        : error.message?.includes('NOT_FOUND') ? 404
        : 400;
      logger.warn(`[dropship/publish] ${dropshipId}: ${error.message}`);
      res.status(code).json({ success: false, error: error.message });
      return;
    }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[dropship/publish] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la publication' });
  }
});

/** POST /api/v2/dropship/:dropshipId/unpublish — retire le produit du catalogue. */
router.post('/:dropshipId/unpublish', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { dropshipId } = req.params;
    const { data, error } = await supabaseAdmin.rpc('unpublish_dropship_product', {
      p_dropship_id: dropshipId,
      p_actor_user_id: req.user!.id,
    });
    if (error) {
      logger.warn(`[dropship/unpublish] ${dropshipId}: ${error.message}`);
      res.status(400).json({ success: false, error: error.message });
      return;
    }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) {
    logger.error(`[dropship/unpublish] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du retrait' });
  }
});

/**
 * POST /api/v2/dropship/order/:orderId/fulfill — relance manuelle du fulfillment auto
 * (idempotent : ne recrée pas les commandes fournisseur déjà présentes). Admin/PDG.
 */
router.post('/order/:orderId/fulfill', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { orderId } = req.params;
    const { data, error } = await supabaseAdmin.rpc('fulfill_dropship_for_order', { p_order_id: orderId });
    if (error) {
      logger.warn(`[dropship/fulfill] ${orderId}: ${error.message}`);
      res.status(400).json({ success: false, error: error.message });
      return;
    }
    res.json({ success: true, created: data ?? 0 });
  } catch (e: any) {
    logger.error(`[dropship/fulfill] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du fulfillment' });
  }
});

/**
 * POST /api/v2/dropship/order/:id/place — passe la commande chez le fournisseur (SERVEUR).
 * Réel si credentials connecteur présents, sinon mock. Idempotent (déjà placée → no-op).
 * Réservé au vendeur propriétaire ou admin/PDG.
 */
router.post('/order/:id/place', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const result = await placeDropshipOrder(req.params.id, { id: req.user!.id, role: req.user!.role });
    if (!result.success) {
      const status = result.code === 'NOT_OWNER' ? 403 : result.code === 'NOT_FOUND' ? 404 : 400;
      res.status(status).json(result);
      return;
    }
    res.json(result);
  } catch (e: any) {
    logger.error(`[dropship/place] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du placement fournisseur' });
  }
});

/**
 * POST /api/v2/dropship/sync — lance MANUELLEMENT la sync prix/stock (admin/PDG).
 * (Sinon automatique toutes les 30 min sur le worker.) En mock = no-op.
 */
router.post('/sync', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const summary = await syncAllDropshipProducts();
    res.json({ success: true, summary });
  } catch (e: any) {
    logger.error(`[dropship/sync] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la synchronisation' });
  }
});

/**
 * POST /api/v2/dropship/order/:id/tracking/sync — rapatrie le suivi fournisseur d'une
 * commande (vendeur propriétaire ou admin). En mock = no-op. (Sinon auto toutes les 30 min.)
 */
router.post('/order/:id/tracking/sync', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: row, error } = await supabaseAdmin
      .from('dropship_orders')
      .select('id, vendor_id, supplier_order_id, dropship_product_id, customer_order_id, tracking_number, status')
      .eq('id', req.params.id)
      .maybeSingle();
    if (error) throw error;
    if (!row) { res.status(404).json({ success: false, error: 'Commande fournisseur introuvable' }); return; }

    const isAdmin = PDG_ROLES.includes((req.user!.role || '').toLowerCase());
    if (!isAdmin) {
      const { data: vendor } = await supabaseAdmin.from('vendors').select('user_id').eq('id', row.vendor_id).maybeSingle();
      if (!vendor || vendor.user_id !== req.user!.id) { res.status(403).json({ success: false, error: 'Accès refusé' }); return; }
    }

    const result = await syncTrackingForOrder(row as any);
    res.json({ success: true, changed: result.changed, status: result.status });
  } catch (e: any) {
    logger.error(`[dropship/tracking/sync] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la synchronisation du suivi' });
  }
});

export default router;
