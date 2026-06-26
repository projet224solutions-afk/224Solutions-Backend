/**
 * PAIEMENTS V2 — Point d'entrée backend Node.js (centralisation du flux financier)
 *
 * ÉTAT : fondation. Seul `convert-preview` (lecture seule, aucun mouvement d'argent)
 * est exposé pour l'instant.
 *
 * ⚠️ Endpoints /taxi et /service NON exposés volontairement : les RPC atomiques
 * `process_taxi_payment_atomic` et `process_service_payment_atomic` n'existent PAS
 * encore en base (vérifié le 2026-06-27). Les créer maintenant produirait des
 * endpoints qui échouent (« function not found ») et casserait les paiements si le
 * frontend était redirigé dessus. À ajouter une fois les RPC atomiques créées
 * (ou câblées sur le flux de paiement existant taxi/restaurant/livraison).
 */
import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { convertAmount } from '../services/currencyConversion.service.js';
import { logger } from '../config/logger.js';

const router = Router();

/**
 * POST /api/v2/payments/convert-preview
 * Prévisualisation de conversion avant paiement (taux + montant converti).
 * Lecture seule — aucun débit/crédit.
 */
router.post('/convert-preview', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const { amount, from = 'GNF', to } = req.body || {};
  if (!amount || amount <= 0 || !to) {
    res.status(400).json({ success: false, error: 'Paramètres invalides' });
    return;
  }
  try {
    const result = await convertAmount(amount, from, to);
    res.json({ success: true, data: result });
  } catch (err: any) {
    logger.warn(`[payments.v2/convert-preview] ${err?.message}`);
    res.status(404).json({ success: false, error: err?.message || 'Taux indisponible' });
  }
});

export default router;
