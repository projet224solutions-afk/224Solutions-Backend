/**
 * MARKETPLACE PRICE ROUTES
 * Endpoints pour la preview de prix et le verrouillage du taux au checkout.
 *
 * Ces routes sont la seule source de vérité pour les prix convertis.
 * Le frontend affiche ce que le backend retourne — jamais l'inverse.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { logger } from '../config/logger.js';
import {
  buildDisplayPrice,
  buildOrderFinancialSummary,
  lockCheckoutRate,
  getBuyerCurrency,
  getSellerCurrency,
} from '../services/marketplacePricing.service.js';

const router = Router();

// ─────────────────────────────────────────────────────────────────
// GET /api/marketplace/price-preview/:productId
//
// Retourne le prix d'un produit converti dans la devise de l'acheteur.
// Utilisé par les fiches produit, pages boutique et sections home.
// ─────────────────────────────────────────────────────────────────
router.get('/price-preview/:productId', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { productId } = req.params;
    const userId = req.user!.id;

    const displayPrice = await buildDisplayPrice(productId, userId);

    res.json({
      success: true,
      data: displayPrice,
    });
  } catch (err: any) {
    logger.error(`price-preview: ${err.message}`);
    res.status(err.message.includes('introuvable') ? 404 : 500).json({
      success: false,
      error: err.message || 'Erreur calcul prix',
    });
  }
});

// ─────────────────────────────────────────────────────────────────
// POST /api/marketplace/price-preview/batch
//
// Retourne les prix convertis pour une liste de produits.
// Utilisé par le panier pour afficher tous les prix en même temps.
// Body: { product_ids: string[] }
// ─────────────────────────────────────────────────────────────────
router.post('/price-preview/batch', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { product_ids } = req.body;
    const userId = req.user!.id;

    if (!Array.isArray(product_ids) || product_ids.length === 0) {
      res.status(400).json({ success: false, error: 'product_ids requis (tableau non vide)' });
      return;
    }

    if (product_ids.length > 50) {
      res.status(400).json({ success: false, error: 'Maximum 50 produits par requête' });
      return;
    }

    const results = await Promise.allSettled(
      product_ids.map((id: string) => buildDisplayPrice(id, userId)),
    );

    const prices: Record<string, any> = {};
    for (let i = 0; i < product_ids.length; i++) {
      const result = results[i];
      prices[product_ids[i]] = result.status === 'fulfilled'
        ? { success: true, data: result.value }
        : { success: false, error: (result.reason as Error).message };
    }

    res.json({ success: true, prices });
  } catch (err: any) {
    logger.error(`price-preview batch: ${err.message}`);
    res.status(500).json({ success: false, error: 'Erreur calcul prix batch' });
  }
});

// ─────────────────────────────────────────────────────────────────
// POST /api/marketplace/checkout/financial-summary
//
// Calcule le résumé financier complet d'une commande avant paiement.
// Le backend recalcule TOUT depuis la DB.
// Body: { vendor_id, items: [{product_id, quantity}], product_type? }
// ─────────────────────────────────────────────────────────────────
router.post('/checkout/financial-summary', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { vendor_id, items, product_type } = req.body;
    const userId = req.user!.id;

    if (!vendor_id || !Array.isArray(items) || items.length === 0) {
      res.status(400).json({ success: false, error: 'vendor_id et items requis' });
      return;
    }

    const summary = await buildOrderFinancialSummary({
      buyerUserId:  userId,
      vendorId:     vendor_id,
      items:        items.map((i: any) => ({ productId: i.product_id, quantity: i.quantity })),
      productType:  product_type || 'physical',
    });

    res.json({ success: true, data: summary });
  } catch (err: any) {
    logger.error(`financial-summary: ${err.message}`);
    res.status(500).json({ success: false, error: err.message || 'Erreur calcul financier' });
  }
});

// ─────────────────────────────────────────────────────────────────
// POST /api/marketplace/checkout/lock-rate
//
// Verrouille le taux de change pour 8 minutes au moment du checkout.
// Body: { vendor_id, from_currency, to_currency, original_amount }
// ─────────────────────────────────────────────────────────────────
router.post('/checkout/lock-rate', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { vendor_id, from_currency, to_currency, original_amount } = req.body;
    const userId = req.user!.id;

    if (!vendor_id || !from_currency || !to_currency || !original_amount) {
      res.status(400).json({ success: false, error: 'Paramètres manquants' });
      return;
    }

    const lock = await lockCheckoutRate(
      userId,
      vendor_id,
      from_currency,
      to_currency,
      Number(original_amount),
    );

    res.json({ success: true, data: lock });
  } catch (err: any) {
    logger.error(`lock-rate: ${err.message}`);
    res.status(err.message.includes('introuvable') ? 404 : 500).json({
      success: false,
      error: err.message || 'Impossible de verrouiller le taux',
    });
  }
});

// ─────────────────────────────────────────────────────────────────
// GET /api/marketplace/currencies
//
// Retourne la devise acheteur + vendeur (pour la page checkout).
// ─────────────────────────────────────────────────────────────────
router.get('/currencies', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId   = req.user!.id;
    const vendorId = req.query.vendor_id as string | undefined;

    const [buyerCurrency, sellerCurrency] = await Promise.all([
      getBuyerCurrency(userId),
      vendorId ? getSellerCurrency(vendorId) : Promise.resolve(null),
    ]);

    res.json({
      success: true,
      data: {
        buyerCurrency,
        sellerCurrency,
        isCrossCurrency: sellerCurrency ? sellerCurrency !== buyerCurrency : null,
      },
    });
  } catch (err: any) {
    logger.error(`currencies: ${err.message}`);
    res.status(500).json({ success: false, error: 'Erreur récupération devises' });
  }
});

export default router;
