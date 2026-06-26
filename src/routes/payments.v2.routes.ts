/**
 * PAIEMENTS V2 — Point d'entrée backend Node.js (centralisation du flux financier)
 *
 * Le frontend n'appelle plus directement les Edge Functions de paiement : il passe par
 * ce backend, qui RELAIE (proxy) vers l'Edge Function correspondante en transmettant le
 * JWT de l'utilisateur. La logique de paiement éprouvée (Stripe / Orange Money / wallet,
 * idempotence, commissions) reste 100 % dans les Edge Functions — on ne la réécrit pas,
 * on ne casse rien. Le backend devient juste le point d'entrée unique (audit, contrôle).
 *
 * Contrat de réponse du proxy (pour que le frontend distingue les cas) :
 *   - Edge atteinte  → { success:true, proxied:true, edgeStatus:<code>, data:<json Edge> }
 *   - Edge injoignable / erreur backend → HTTP 502 { success:false } → le frontend bascule
 *     en fallback (appel Edge direct, MÊME idempotencyKey → aucun double débit).
 *
 * Pas de nouvelle RPC qui déplace de l'argent : les RPC atomiques "process_*_payment"
 * génériques n'existaient pas et réécrire la logique multi-méthodes serait risqué.
 */
import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { convertAmount } from '../services/currencyConversion.service.js';
import { env } from '../config/env.js';
import { logger } from '../config/logger.js';

const router = Router();
const EDGE_BASE = `${env.SUPABASE_URL}/functions/v1`;

// Whitelist stricte type → Edge Function de paiement (POST /service).
const SERVICE_PAYMENT_FN: Record<string, string> = {
  delivery:   'delivery-payment',
  restaurant: 'restaurant-payment',
  freight:    'freight-payment',
  service:    'service-payment',
};

/**
 * Relaie le paiement à l'Edge Function en transmettant le JWT utilisateur.
 * Ne réécrit AUCUNE logique d'argent — la fonction Edge fait tout (idempotence comprise).
 */
async function proxyEdgePayment(
  fnName: string,
  authHeader: string | undefined,
  body: unknown,
  res: Response,
): Promise<void> {
  if (!authHeader) {
    res.status(401).json({ success: false, error: 'Non authentifié' });
    return;
  }
  try {
    const r = await fetch(`${EDGE_BASE}/${fnName}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': env.SUPABASE_ANON_KEY,
        'Authorization': authHeader,
      },
      body: JSON.stringify(body ?? {}),
    });
    const edgeJson = await r.json().catch(() => ({}));
    // On a bien atteint l'Edge : on renvoie son code + son corps. Le frontend décide
    // (succès → data ; erreur métier → throw). PAS de fallback dans ce cas.
    res.json({ success: true, proxied: true, edgeStatus: r.status, data: edgeJson });
  } catch (err: any) {
    logger.error(`[payments.v2/${fnName}] proxy échec: ${err?.message}`);
    res.status(502).json({ success: false, error: 'Service de paiement indisponible' });
  }
}

/**
 * POST /api/v2/payments/taxi — paiement d'une course (relais → Edge taxi-payment).
 * body: { rideId, paymentMethod, idempotencyKey }
 */
router.post('/taxi', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const { rideId, paymentMethod, idempotencyKey } = req.body || {};
  if (!rideId || !paymentMethod) {
    res.status(400).json({ success: false, error: 'rideId et paymentMethod requis' });
    return;
  }
  await proxyEdgePayment('taxi-payment', req.headers.authorization, { rideId, paymentMethod, idempotencyKey }, res);
});

/**
 * POST /api/v2/payments/service — paiement générique (relais → Edge {type}-payment).
 * body: { type: 'delivery'|'restaurant'|'freight'|'service', ...champs attendus par l'Edge }
 */
router.post('/service', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const { type, ...rest } = req.body || {};
  const fn = SERVICE_PAYMENT_FN[String(type || '').toLowerCase()];
  if (!fn) {
    res.status(400).json({ success: false, error: `type de paiement invalide: ${type}` });
    return;
  }
  await proxyEdgePayment(fn, req.headers.authorization, rest, res);
});

/**
 * POST /api/v2/payments/convert-preview
 * Prévisualisation de conversion avant paiement (taux + montant converti). Lecture seule.
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
