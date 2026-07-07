
// Charger dotenv AVANT tout autre import (absolument en premier)
import './config/load-env.js';

/**
 * 🚀 224SOLUTIONS - BACKEND NODE.JS CENTRALISÉ v3 (Phase 6)
 * 
 * Architecture: Express/TypeScript
 * Auth: JWT Supabase
 * Database: PostgreSQL via Supabase
 * Cache: Redis (optional, graceful fallback)
 * Jobs: BullMQ (optional, graceful fallback)
 * Webhooks: Stripe signature-validated
 */

import crypto from 'crypto';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import compression from 'compression';
import { env, assertSecretsOnBoot } from './config/env.js';
import { logger } from './config/logger.js';

// Validation des secrets au démarrage (fail-fast en production sur secret faible)
assertSecretsOnBoot();
import { errorHandler } from './middlewares/errorHandler.js';
import { requestLogger } from './middlewares/requestLogger.js';
import { closeRedis } from './config/redis.js';
import { jobQueue } from './jobs/jobQueue.js';
import { metrics } from './services/metrics.service.js';
import { surveillance24x7Service } from './services/surveillance24x7.service.js';
import { dropshipSyncScheduler } from './services/dropship/dropshipSync.service.js';
import { medicationReminderScheduler } from './services/medicationReminder.service.js';
import { notificationRetryScheduler } from './services/notificationRetry.service.js';

// Routes TypeScript
import healthRoutes from './routes/health.routes.js';
import subscriptionRoutes from './routes/subscriptions.routes.js';
import paymentRoutes from './routes/payments.routes.js';
import walletRoutesV2 from './routes/wallet.v2.routes.js';
import paymentsV2Routes from './routes/payments.v2.routes.js';
import deliveryRoutes from './routes/delivery.routes.js';
import taxiRoutes from './routes/taxi.routes.js';
import restaurantRoutes from './routes/restaurant.routes.js';
import travelRoutes from './routes/travel.routes.js';
import profilesRoutes from './routes/profiles.routes.js';
import pharmacyRoutes from './routes/pharmacy.routes.js';
import notificationDispatchRoutes from './routes/notificationDispatch.routes.js';
import countryPricingRoutes from './routes/countryPricing.routes.js';
import authFailoverRoutes from './routes/auth.failover.routes.js';
import realtimeRoutes from './routes/realtime.routes.js';
import liveRoutes from './routes/live.routes.js';
import storiesRoutes from './routes/stories.routes.js';
import agoraRoutes from './routes/agora.routes.js';
import turnRoutes from './routes/turn.routes.js';
import shareholderRoutes from './routes/shareholders.routes.js';
import adminRoutes from './routes/admin.routes.js';
import identityRoutes from './routes/identity.routes.js';
import pushRoutes from './routes/push.routes.js';
import vendorRoutes from './routes/vendors.routes.js';
import agentRoutes from './routes/agents.routes.js';
import documentsRoutes from './routes/documents.routes.js';
import productRoutes from './routes/products.routes.js';
import orderRoutes from './routes/orders.routes.js';
import digitalRoutes from './routes/digital.routes.js';
import dropshipRoutes from './routes/dropship.routes.js';
import bureauRoutes from './routes/bureau.routes.js';
import guard224Routes from './routes/guard224.routes.js';
import artisanRoutes from './routes/artisan.routes.js';
import bookingsRoutes from './routes/bookings.routes.js';
import copilotRoutes from './routes/copilot.routes.js';
import beautyRoutes from './routes/beauty.routes.js';
import groupBuyRoutes from './routes/groupbuy.routes.js';
import constructionRoutes from './routes/construction.routes.js';
import educationRoutes from './routes/education.routes.js';
import realestateRoutes from './routes/realestate.routes.js';
import aiRoutes from './routes/ai.routes.js';
import clinicRoutes from './routes/clinic.routes.js';
import quotesRoutes from './routes/quotes.routes.js';
import freightRoutes from './routes/freight.routes.js';
import contractsRoutes from './routes/contracts.routes.js';
import returnsRoutes from './routes/returns.routes.js';
import vendorAffiliateRoutes from './routes/vendorAffiliate.routes.js';
import mobilityRoutes from './routes/mobility.routes.js';
import posRoutes from './routes/pos.routes.js';
import inventoryRoutes from './routes/inventory.routes.js';
import affiliateRoutes from './routes/affiliate.routes.js';
import paymentLinksRoutes from './routes/paymentLinks.routes.js';
import marketplaceVisibilityRoutes from './routes/marketplaceVisibility.routes.js';
import marketplaceRoutes from './routes/marketplace.routes.js';
import coreRoutes from './routes/core.routes.js';
import campaignRoutes from './routes/campaigns.routes.js';
import webhookRoutes from './routes/webhooks.routes.js';
import migrationsRoutes from './routes/migrations.js';
// @ts-ignore
import edgeFunctionsRoutes from './routes/edge-functions/index.js';

// Routes legacy JS (auth migré vers auth.routes.ts)
import authRoutes from './routes/auth.routes.js';
// @ts-ignore
import walletRoutes from './routes/wallet.routes.js';
// @ts-ignore
import analyticsRoutes from './routes/analytics.routes.js';
// @ts-ignore
import jobsRoutes from './routes/jobs.routes.js';
// @ts-ignore
import mediaRoutes from './routes/media.routes.js';
// @ts-ignore
import internalRoutes from './routes/internal.routes.js';
// @ts-ignore
import { rateLimiter } from './middlewares/rateLimiter.js';
import { ipBlocklist, autoBlockGuard, refreshBlocklist } from './middlewares/ipBlocklist.js';

const app = express();

// 🔒 Derrière nginx (VPS) + proxy Vercel : faire confiance à X-Forwarded-For pour
// que req.ip = l'IP RÉELLE du client (pas 127.0.0.1 du proxy nginx). SANS ça, tous
// les utilisateurs partagent la même clé de rate-limit (global:127.0.0.1) → la
// limite saute pour tout le monde (« Trop de requêtes »). Indispensable au bon
// fonctionnement du rate-limiting par IP.
app.set('trust proxy', true);

function originMatchesPattern(origin: string, pattern: string): boolean {
  if (!pattern) return false;
  if (pattern === '*') return true;
  if (origin === pattern) return true;

  // Support patterns like: https://*.224solution.net
  const wildcardIndex = pattern.indexOf('*');
  if (wildcardIndex === -1) return false;

  const prefix = pattern.slice(0, wildcardIndex);
  const suffix = pattern.slice(wildcardIndex + 1);
  return origin.startsWith(prefix) && origin.endsWith(suffix);
}

function isAllowedLocalDevOrigin(origin: string): boolean {
  try {
    const parsed = new URL(origin);
    const hostname = parsed.hostname.replace(/^\[(.*)\]$/, '$1');

    return [
      'localhost',
      '127.0.0.1',
      '::1',
      '0.0.0.0',
    ].includes(hostname);
  } catch {
    return false;
  }
}

// ==================== SECURITY MIDDLEWARES ====================

const cspConnectSrc = env.CSP_CONNECT_SRC
  ? env.CSP_CONNECT_SRC.split(',').map(s => s.trim())
  : [];

app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      styleSrc: ["'self'"],
      scriptSrc: ["'self'"],
      connectSrc: ["'self'", ...cspConnectSrc],
      imgSrc: ["'self'", "data:", "https:"],
      fontSrc: ["'self'", "https:"],
      objectSrc: ["'none'"],
      frameSrc: ["'none'"],
      baseUri: ["'self'"],
    },
  },
  hsts: { maxAge: 31536000, includeSubDomains: true, preload: true }
}));

app.use(cors({
  origin: (origin, callback) => {
    if (!origin) return callback(null, true);

    const isAllowed = env.corsOrigins.some((allowedOrigin) => originMatchesPattern(origin, allowedOrigin));
    const isLocalDevOrigin = env.isDevelopment && isAllowedLocalDevOrigin(origin);

    if (isAllowed || isLocalDevOrigin) {
      callback(null, true);
    } else {
      logger.warn(`Blocked CORS from: ${origin}`);
      callback(new Error('Not allowed by CORS'));
    }
  },
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'X-Internal-API-Key', 'Idempotency-Key'],
  exposedHeaders: ['X-Request-Id', 'X-RateLimit-Limit', 'X-RateLimit-Remaining', 'X-RateLimit-Reset'],
}));

app.use(compression());

// ==================== WEBHOOK RAW BODY (before JSON parser) ====================

// Stripe webhooks need raw body for signature verification
app.use('/webhooks/stripe', express.raw({ type: 'application/json' }));
// Edge Functions Stripe webhooks also need raw body for signature verification
app.use('/edge-functions/webhooks/stripe', express.raw({ type: 'application/json' }));

// Standard JSON parser for everything else
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true, limit: '10mb' }));

// Correlation / Request ID
app.use((req, res, next) => {
  const requestId = req.headers['x-request-id'] as string || crypto.randomUUID();
  res.setHeader('X-Request-Id', requestId);
  (req as any).requestId = requestId;

  // Request timing for metrics
  const start = Date.now();
  res.on('finish', () => {
    const duration = Date.now() - start;
    metrics.increment('http.requests.total', 1, { method: req.method, status: String(res.statusCode) });
    metrics.observe('http.request.duration_ms', duration);
  });

  next();
});

app.use(rateLimiter);
// Riposte : rejette les IPs bloquees, puis auto-bloque les attaques evidentes.
app.use(ipBlocklist);
app.use(autoBlockGuard);
app.use(requestLogger);

// Pre-charge la liste des IPs bloquees au demarrage (cache memoire).
void refreshBlocklist();

// ==================== ROUTES ====================

// Accueil API (GET /)
app.get('/', (req, res) => {
  res.json({
    success: true,
    message: 'Bienvenue sur l’API 224Solutions',
    status: 'online',
    environment: process.env.NODE_ENV || 'development',
    timestamp: new Date().toISOString()
  });
});

// Health (public)
app.use('/health', healthRoutes);
app.use('/healthz', healthRoutes);
app.use('/healthz.json', healthRoutes);

// Migrations (admin, applies database changes)
app.use('/api/migrations', migrationsRoutes);

// Webhooks (public, signature-validated, BEFORE auth middleware)
app.use('/webhooks', webhookRoutes);

// Auth (public)
app.use('/auth', authRoutes);

// Analytics
app.use('/api/analytics', analyticsRoutes);

// ==================== LEGACY ROUTES ====================

app.use('/api/wallet', walletRoutes);
app.use('/internal', internalRoutes);
app.use('/jobs', jobsRoutes);
app.use('/media', mediaRoutes);

// ==================== V2 ROUTES ====================

app.use('/api/v2/wallet', walletRoutesV2);
app.use('/api/v2/payments', paymentsV2Routes);
app.use('/api/v2/delivery', deliveryRoutes);
app.use('/api/v2/taxi', taxiRoutes);
app.use('/api/v2/restaurant', restaurantRoutes);
app.use('/api/v2/travel', travelRoutes);
app.use('/api/v2/profiles', profilesRoutes);
app.use('/api/v2/pharmacy', pharmacyRoutes);
app.use('/api/v2/notifications', notificationDispatchRoutes);
app.use('/api/v2/country-pricing', countryPricingRoutes);
app.use('/api/auth/failover', authFailoverRoutes);
app.use('/api/v2/realtime', realtimeRoutes);
app.use('/api/v2/live', liveRoutes);
app.use('/api/v2/stories', storiesRoutes);
app.use('/api/v2/agora', agoraRoutes);
app.use('/api/v2', turnRoutes);
app.use('/api/shareholders', shareholderRoutes);
app.use('/api/admin', adminRoutes);
app.use('/api/identity', identityRoutes);
app.use('/api/v2/push', pushRoutes);
app.use('/api/subscriptions', subscriptionRoutes);
app.use('/api/payments', paymentRoutes);

// ==================== V3 ROUTES (with per-route rate limits) ====================

app.use('/api/vendors', vendorRoutes);
app.use('/api/agents', agentRoutes);
app.use('/api/documents', documentsRoutes);
app.use('/api/products', productRoutes);
app.use('/api/orders', orderRoutes);
app.use('/api/v2/digital', digitalRoutes);
app.use('/api/v2/dropship', dropshipRoutes);
app.use('/api/v2/bureau', bureauRoutes);
app.use('/api/v2/guard224', guard224Routes);
app.use('/api/v2/artisan', artisanRoutes);
app.use('/api/v2/bookings', bookingsRoutes);
app.use('/api/v2/copilot', copilotRoutes);
app.use('/api/v2/beauty', beautyRoutes);
app.use('/api/v2/group-buy', groupBuyRoutes);
app.use('/api/v2/construction', constructionRoutes);
app.use('/api/v2/education', educationRoutes);
app.use('/api/v2/realestate', realestateRoutes);
app.use('/api/v2/ai', aiRoutes);
app.use('/api/v2/clinic', clinicRoutes);
app.use('/api/v2/quotes', quotesRoutes);
app.use('/api/v2/freight', freightRoutes);
app.use('/api/contracts', contractsRoutes);
app.use('/api/returns', returnsRoutes);
app.use('/api/v2/mobility', mobilityRoutes);
app.use('/api/pos', posRoutes);
app.use('/api/affiliate', affiliateRoutes);
app.use('/api/affiliate-program', vendorAffiliateRoutes);
app.use('/api/inventory', inventoryRoutes);
app.use('/api/payment-links', paymentLinksRoutes);
app.use('/api/marketplace-visibility', marketplaceVisibilityRoutes);
app.use('/api/v2/marketplace', marketplaceRoutes);
app.use('/api/campaigns', campaignRoutes);
app.use('/api/core', coreRoutes);
app.use('/edge-functions', edgeFunctionsRoutes);

// ==================== ERROR HANDLING ====================

app.use((_req, res) => {
  res.status(404).json({ success: false, error: 'Route not found', path: _req.originalUrl });
});

app.use(errorHandler);

// ==================== SERVER ====================

const isVercelRuntime = Boolean(process.env.VERCEL);
let server: ReturnType<typeof app.listen> | null = null;

async function bootstrapBackgroundServices() {
  logger.info(`📍 Environment: ${env.NODE_ENV}`);
  logger.info(`🔐 CORS Origins: ${env.corsOrigins.join(', ')}`);

  // ⚖️ Scaling horizontal : ne lancer les tâches de fond que sur le WORKER
  // (RUN_BACKGROUND_JOBS=true). Sur les conteneurs WEB (=false) on sert uniquement
  // les requêtes HTTP → pas de jobs/surveillance dupliqués entre instances.
  if (!env.RUN_BACKGROUND_JOBS) {
    logger.info('🌐 Mode WEB (stateless) : tâches de fond désactivées (RUN_BACKGROUND_JOBS=false)');
    logger.info(`✅ Ready to handle requests`);
    return;
  }

  logger.info('🛠️  Mode WORKER : initialisation des tâches de fond (jobs + surveillance 24/7)');
  // Initialize job queues (non-blocking, graceful failure)
  await jobQueue.init();
  await jobQueue.scheduleRecurring();
  surveillance24x7Service.start();
  dropshipSyncScheduler.start();
  medicationReminderScheduler.start();
  notificationRetryScheduler.start();

  logger.info(`✅ Ready to handle requests`);
}

if (isVercelRuntime) {
  logger.info('⚡ Backend v3 running in Vercel serverless mode');
} else {
  server = app.listen(env.PORT, async () => {
    logger.info(`🚀 Backend v3 (Phase 6) started on port ${env.PORT}`);
    await bootstrapBackgroundServices();
  });
}

// Graceful shutdown
const gracefulShutdown = async (signal: string) => {
  logger.info(`${signal} received: shutting down gracefully`);

  if (!server) {
    process.exit(0);
  }

  server.close(async () => {
    logger.info('HTTP server closed');
    surveillance24x7Service.stop();
    dropshipSyncScheduler.stop();
    medicationReminderScheduler.stop();
    notificationRetryScheduler.stop();
    await jobQueue.shutdown();
    await closeRedis();
    await metrics.flushToDB();
    logger.info('All services shut down');
    process.exit(0);
  });

  setTimeout(() => {
    logger.error('Forced shutdown after timeout');
    process.exit(1);
  }, 15000);
};

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

process.on('unhandledRejection', (reason) => {
  logger.error('Unhandled Rejection:', reason);
  metrics.increment('errors.unhandled_rejection');
});
process.on('uncaughtException', (error) => {
  logger.error('Uncaught Exception:', error);
  metrics.increment('errors.uncaught_exception');
  process.exit(1);
});

export default app;
