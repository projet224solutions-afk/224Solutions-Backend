/**
 * EDGE FUNCTIONS INDEX
 * Central routing for all migrated Edge Functions
 *
 * Structure:
 * /edge-functions/auth/*        - Authentication (13 functions)
 * /edge-functions/payments/*    - Payments & Escrow (45 functions)
 * /edge-functions/users/*       - User Management (28 functions)
 * /edge-functions/ai/*          - AI/ML (14 functions)
 * /edge-functions/files/*       - File Generation (13 functions)
 * /edge-functions/webhooks/*    - External webhooks (9+ functions)
 * /edge-functions/products/*    - Product Management (14 functions)
 * /edge-functions/orders/*      - Order Management (9 functions)
 * /edge-functions/analytics/*   - Analytics & Monitoring (20+ functions)
 * /edge-functions/misc/*        - Other functions (60+ functions)
 */

import { Router } from "express";
import { supabaseAdmin } from "../../config/supabase.js";

// Import sub-routers
import authRoutes from "./auth.routes.js";
import paymentsRoutes from "./payments.routes.js";
import usersRoutes from "./users.routes.js";
import aiRoutes from "./ai.routes.js";
import filesRoutes from "./files.routes.js";
import webhooksRoutes from "./webhooks.routes.js";
import productsRoutes from "./products.routes.js";
import ordersRoutes from "./orders.routes.js";
import usersExtendedRoutes from "./users-extended.routes.js";
import analyticsRoutes from "./analytics.routes.js";
import notificationsRoutes from "./notifications.routes.js";
import miscRoutes from "./misc.routes.js";
// New extended routes for 100% parity
import authExtendedRoutes from "./auth-extended.routes.js";
import translationMediaRoutes from "./translation-media.routes.js";
import externalPaymentsRoutes from "./external-payments.routes.js";
import aiIntelligenceRoutes from "./ai-intelligence.routes.js";
import infrastructureRoutes from "./infrastructure.routes.js";
import copiloteSearchRoutes from "./copilote-search.routes.js";
import phoneSignupRoutes from "./phone-signup.routes.js";

const router = Router();

// ─────────────────────────────────────────────────────────────────────────────
// 🔒 GARDE D'AUTHENTIFICATION GLOBAL (CORRECTIF CRITIQUE)
// La quasi-totalité des routes edge-functions migrées étaient montées SANS aucun
// middleware → exploitables anonymement (argent, suppression d'utilisateurs,
// sécurité…). On exige une authentification pour TOUT, sauf : endpoints d'auth
// (login/OTP/reset), webhooks (signés en interne), health, et configs publiques.
// (Les contrôles de rôle fins restent au niveau des sous-routeurs, ex. payments.)
// ─────────────────────────────────────────────────────────────────────────────
function isPublicEdgePath(p: string): boolean {
  return (
    p.startsWith('/auth') ||
    p.startsWith('/webhooks') ||
    p.includes('webhook') ||          // tous les webhooks (vérifiés par signature)
    p === '/health' ||
    p === '/send-otp-email' ||
    p === '/phone-signup-send' ||   // OTP d'inscription — utilisateur pas encore créé
    p === '/phone-signup-verify' || // vérif OTP + création du compte — utilisateur pas encore créé
    p === '/paypal-client-id'
  );
}

// Opérations PRIVILÉGIÉES (sécurité/IP, data/infra, cron) → rôle admin/PDG requis,
// pas seulement une session valide. (Le routeur payments gère déjà ses propres ops admin.)
function isAdminEdgePath(p: string): boolean {
  return /(^|\/)security[/-]|block-ip|forensics|incident-response|fraud-detection|fraud\/detect|security-analysis|security\/threats|apply-migrations|sync-cloudsql|sync-apis|production-cron|api-guard-monitor|pubsub|task-worker|debug\/logs|cleanup-cache|cache\/cleanup/.test(p);
}
const ADMIN_ROLES_EDGE = new Set(['admin', 'pdg', 'ceo', 'super_admin']);

router.use(async (req, res, next) => {
  try {
    if (req.method === 'OPTIONS' || isPublicEdgePath(req.path)) return next();
    const authHeader = req.headers.authorization;
    const token = authHeader?.startsWith('Bearer ') ? authHeader.slice(7) : null;
    if (!token) { res.status(401).json({ success: false, error: 'Authentification requise' }); return; }
    const { data, error } = await supabaseAdmin.auth.getUser(token);
    if (error || !data.user) { res.status(401).json({ success: false, error: 'Token invalide' }); return; }
    (req as any).user = data.user;
    if (isAdminEdgePath(req.path)) {
      const { data: prof } = await supabaseAdmin.from('profiles').select('role').eq('id', data.user.id).maybeSingle();
      if (!ADMIN_ROLES_EDGE.has(String((prof as any)?.role))) {
        res.status(403).json({ success: false, error: 'Permissions insuffisantes' });
        return;
      }
    }
    next();
  } catch {
    res.status(500).json({ success: false, error: 'Auth guard error' });
  }
});

/**
 * Mount all Edge Functions routes
 * These are migrated from Supabase Edge Functions
 */
router.use("/auth", authRoutes);
router.use("/auth", authExtendedRoutes);
router.use("/payments", paymentsRoutes);
router.use("/payments", externalPaymentsRoutes);
router.use("/users", usersRoutes);
router.use("/users", usersExtendedRoutes);
router.use("/ai", aiRoutes);
router.use("/ai", aiIntelligenceRoutes);
router.use("/copilote", copiloteSearchRoutes);
router.use("/files", filesRoutes);
router.use("/webhooks", webhooksRoutes);
router.use("/products", productsRoutes);
router.use("/orders", ordersRoutes);
router.use("/analytics", analyticsRoutes);
router.use("/", phoneSignupRoutes);
router.use("/", translationMediaRoutes);
router.use("/", infrastructureRoutes);
router.use("/", notificationsRoutes);
router.use("/", miscRoutes);

/**
 * Health check for Edge Functions layer
 */
router.get("/health", (req, res) => {
  res.status(200).json({
    status: "ok",
    message: "Edge Functions proxy is healthy with comprehensive coverage",
    mounted_categories: [
      "auth (+ auth-extended)",
      "payments (+ external-payments)",
      "users (+ users-extended)",
      "ai (+ ai-intelligence)",
      "files",
      "webhooks",
      "products",
      "orders",
      "analytics",
      "translation-media",
      "infrastructure",
      "notifications/root-shared",
      "misc/root-shared"
    ],
    parity_status: "~100% functional - 216+ Supabase functions now routed",
  });
});

export default router;

