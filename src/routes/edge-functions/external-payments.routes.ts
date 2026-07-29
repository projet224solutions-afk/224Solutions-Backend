import { Router, Request, Response } from "express";

const router = Router();

// ============================================================================
// external-payments — STUBS MONÉTAIRES NEUTRALISÉS (audit « aucun crédit sans paiement réel »)
// ----------------------------------------------------------------------------
// Ces handlers renvoyaient historiquement { success:true, transaction_id:'…' } ou
// { status:'completed' } SANS contacter aucun prestataire et SANS créditer aucun wallet
// → faux positif de succès (un poller/appelant pouvait croire un paiement encaissé). Ils
// ne créent pas d'argent en base mais MENTENT. Politique d'audit : un canal non implémenté
// échoue explicitement (503 + error_code), JAMAIS success:true / status:'completed'.
// Les VRAIS canaux de dépôt vivent ailleurs :
//   * Carte  : /edge-functions/payments/stripe-deposit (PaymentIntent) → webhook signé
//              /webhooks/stripe → crédit atomique. (stripe-deposit / confirm-stripe-deposit
//              réels sont servis par payments.routes.ts, monté AVANT ce fichier → ils gagnent ;
//              les doublons ci-dessous sont ombrés et neutralisés par défense en profondeur.)
//   * Mobile money / PayPal : Edge Functions Supabase dédiées (chapchappay-*, djomy-*,
//              paypal-deposit) — voir DEPOSIT_SECURITY_REPORT.md.
// Les stubs NON monétaires purement opérationnels (taxi accept/refuse, subscription-expiry-check,
// subscription-webhook) sont conservés tels quels — hors périmètre « argent ».
// ============================================================================

/** Réponse standard « canal non configuré » (503, jamais un faux succès). */
function notConfigured(res: Response, code: string) {
  return res.status(503).json({
    success: false,
    error: "Canal de paiement non configuré sur ce point. Utilisez carte ou mobile money.",
    error_code: code,
  });
}

// ── ChapChapPay (mobile money) — NEUTRALISÉ ───────────────────────────────────
router.post("/chapchappay-ecommerce", (_req, res) => notConfigured(res, "CHAPCHAP_NOT_CONFIGURED"));
router.post("/chapchappay-pull", (_req, res) => notConfigured(res, "CHAPCHAP_NOT_CONFIGURED"));
router.post("/chapchappay-push", (_req, res) => notConfigured(res, "CHAPCHAP_NOT_CONFIGURED"));
router.get("/chapchappay-status", (_req, res) => notConfigured(res, "CHAPCHAP_NOT_CONFIGURED"));
router.post("/chapchappay-status", (_req, res) => notConfigured(res, "CHAPCHAP_NOT_CONFIGURED"));
router.post("/chapchappay-webhook", (_req, res) => notConfigured(res, "CHAPCHAP_WEBHOOK_NOT_CONFIGURED"));

// ── PayPal ────────────────────────────────────────────────────────────────────
// client-id : config PUBLIQUE (pas un secret). Renvoie la vraie valeur env ; 503 si absente
// (jamais de "sandbox-client" bidon qui laisserait croire PayPal opérationnel).
const handlePayPalClientId = (_req: Request, res: Response) => {
  const clientId = process.env.PAYPAL_CLIENT_ID;
  if (!clientId) return notConfigured(res, "PAYPAL_NOT_CONFIGURED");
  return res.json({ success: true, client_id: clientId });
};
router.get("/paypal-client-id", handlePayPalClientId);
router.post("/paypal-client-id", handlePayPalClientId);

router.post("/paypal-deposit", (_req, res) => notConfigured(res, "PAYPAL_NOT_CONFIGURED"));
router.post("/paypal-withdrawal", (_req, res) => notConfigured(res, "PAYPAL_NOT_CONFIGURED"));
router.post("/paypal-webhook", (_req, res) => notConfigured(res, "PAYPAL_WEBHOOK_NOT_CONFIGURED"));

// ── Taxi : accept/refuse = opérationnel (conservé) ; paiement = argent (neutralisé) ──
router.post("/taxi-accept-ride", async (req: Request, res: Response) => {
  const { ride_id, driver_id } = req.body || {};
  return res.json({ success: true, ride_id, driver_id, accepted: true });
});
router.post("/taxi-refuse-ride", async (req: Request, res: Response) => {
  const { ride_id, driver_id } = req.body || {};
  return res.json({ success: true, ride_id, driver_id, refused: true });
});
router.post("/taxi-payment", (_req, res) => notConfigured(res, "TAXI_PAYMENT_NOT_CONFIGURED"));
router.post("/taxi-payment-process", (_req, res) => notConfigured(res, "TAXI_PAYMENT_NOT_CONFIGURED"));

// ── Abonnement : renouvellement = argent (neutralisé) ; expiry-check/webhook = opérationnel ──
router.post("/renew-subscription", (_req, res) => notConfigured(res, "SUBSCRIPTION_RENEWAL_NOT_CONFIGURED"));
router.post("/subscription-expiry-check", async (req: Request, res: Response) => {
  const { subscription_id } = req.body || {};
  return res.json({ success: true, subscription_id, expired: false });
});
router.post("/subscription-webhook", async (_req: Request, res: Response) => {
  return res.json({ success: true, webhook_processed: true });
});

// ── Stripe (doublons ombrés + non implémentés) — NEUTRALISÉ ───────────────────
router.post("/stripe-create-payment-intent", (_req, res) => notConfigured(res, "STRIPE_NOT_CONFIGURED"));
router.post("/stripe-deposit", (_req, res) => notConfigured(res, "STRIPE_NOT_CONFIGURED"));
router.post("/stripe-pos-payment", (_req, res) => notConfigured(res, "STRIPE_NOT_CONFIGURED"));
router.post("/stripe-withdrawal", (_req, res) => notConfigured(res, "STRIPE_NOT_CONFIGURED"));
router.post("/stripe-webhook", (_req, res) => notConfigured(res, "STRIPE_WEBHOOK_NOT_CONFIGURED"));
router.post("/confirm-stripe-deposit", (_req, res) => notConfigured(res, "STRIPE_NOT_CONFIGURED"));
router.post("/create-payment-intent", (_req, res) => notConfigured(res, "STRIPE_NOT_CONFIGURED"));

export default router;
