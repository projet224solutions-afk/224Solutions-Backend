/**
 * 🛡️ PER-ROUTE RATE LIMITER - Phase 6
 * 
 * Redis-backed rate limiting for critical endpoints.
 * Falls back to in-memory if Redis unavailable.
 * Configurable per-route with IP + user + API key dimensions.
 */

import { Request, Response, NextFunction } from 'express';
import { redisRateLimit } from '../config/redis.js';
import { logger } from '../config/logger.js';
import { auditTrail } from '../services/auditTrail.service.js';

interface RateLimitConfig {
  maxRequests: number;
  windowSeconds: number;
  keyPrefix?: string;
  /** Include user ID in rate limit key */
  perUser?: boolean;
  /** Include IP in rate limit key */
  perIp?: boolean;
  /** Log security event on limit breach */
  logBreach?: boolean;
  /**
   * Comportement si Redis est indisponible :
   * - false (défaut) : fallback mémoire local (disponibilité priorisée)
   * - true : REFUSER la requête (429) — pour les routes sensibles où mieux vaut
   *   bloquer que laisser passer N× le quota en multi-instance (auth/paiement/admin)
   */
  failClosed?: boolean;
}

// In-memory fallback store (basic, no persistence)
const memoryStore = new Map<string, { count: number; resetAt: number }>();

function memoryRateLimit(key: string, max: number, windowMs: number): { allowed: boolean; remaining: number } {
  const now = Date.now();
  const entry = memoryStore.get(key);

  if (!entry || now > entry.resetAt) {
    memoryStore.set(key, { count: 1, resetAt: now + windowMs });
    return { allowed: true, remaining: max - 1 };
  }

  entry.count++;
  const allowed = entry.count <= max;
  return { allowed, remaining: Math.max(0, max - entry.count) };
}

// Cleanup stale memory entries every 5 minutes
setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of memoryStore) {
    if (now > entry.resetAt) memoryStore.delete(key);
  }
}, 5 * 60 * 1000);

/**
 * Create a rate limiter middleware for a specific route.
 */
export function routeRateLimit(config: RateLimitConfig) {
  const {
    maxRequests,
    windowSeconds,
    keyPrefix = 'route',
    perUser = true,
    perIp = true,
    logBreach = true,
    failClosed = false,   // ✅ défaut : disponibilité (fallback mémoire)
  } = config;

  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    // Build composite key
    const parts = [keyPrefix];
    if (perIp) parts.push(req.ip || 'unknown');
    if (perUser) parts.push((req as any).user?.id || 'anon');
    const key = parts.join(':');

    // Try Redis first
    const result = await redisRateLimit.check(key, maxRequests, windowSeconds);

    // Redis indisponible (resetAt === 0)
    if (result.resetAt === 0) {
      // ✅ Routes sensibles : fail-closed — on refuse plutôt que de laisser
      // passer N× le quota entre instances quand Redis est down.
      if (failClosed) {
        logger.error(`Rate limit FAIL-CLOSED (Redis down) sur route sensible: ${key}`);
        if (logBreach) {
          await auditTrail.log({
            actorId: (req as any).user?.id || req.ip || 'unknown',
            actorType: 'user',
            action: 'rate_limit.fail_closed',
            resourceType: 'endpoint',
            resourceId: req.originalUrl,
            ip: req.ip,
            riskLevel: 'high',
            metadata: { keyPrefix, reason: 'redis_unavailable' },
          });
        }
        res.status(429).json({
          success: false,
          error: 'Service temporairement indisponible. Veuillez réessayer dans un moment.',
          retryAfter: windowSeconds,
        });
        return;
      }

      // Routes non sensibles : fallback mémoire local (disponibilité priorisée)
      const memResult = memoryRateLimit(key, maxRequests, windowSeconds * 1000);
      if (!memResult.allowed) {
        if (logBreach) {
          logger.warn(`Rate limit exceeded (memory): ${key}`);
          await auditTrail.log({
            actorId: (req as any).user?.id || req.ip || 'unknown',
            actorType: 'user',
            action: 'rate_limit.exceeded',
            resourceType: 'endpoint',
            resourceId: req.originalUrl,
            ip: req.ip,
            riskLevel: 'medium',
            metadata: { keyPrefix, maxRequests, windowSeconds },
          });
        }
        res.status(429).json({
          success: false,
          error: 'Trop de requêtes. Veuillez réessayer dans un moment.',
          retryAfter: windowSeconds,
        });
        return;
      }
      next();
      return;
    }

    // Set headers
    res.setHeader('X-RateLimit-Limit', maxRequests);
    res.setHeader('X-RateLimit-Remaining', result.remaining);
    res.setHeader('X-RateLimit-Reset', Math.ceil(result.resetAt / 1000));

    if (!result.allowed) {
      if (logBreach) {
        logger.warn(`Rate limit exceeded: ${key}, path=${req.originalUrl}`);
        await auditTrail.log({
          actorId: (req as any).user?.id || req.ip || 'unknown',
          actorType: 'user',
          action: 'rate_limit.exceeded',
          resourceType: 'endpoint',
          resourceId: req.originalUrl,
          ip: req.ip,
          riskLevel: 'medium',
          metadata: { keyPrefix, maxRequests, windowSeconds },
        });
      }
      res.status(429).json({
        success: false,
        error: 'Trop de requêtes. Veuillez réessayer dans un moment.',
        retryAfter: windowSeconds,
      });
      return;
    }

    next();
  };
}

// ==================== PRE-CONFIGURED LIMITERS ====================

/** Auth/Login: 10 req / 15 min per IP — FAIL-CLOSED (sécurité) */
export const authRateLimit = routeRateLimit({
  maxRequests: 10, windowSeconds: 900, keyPrefix: 'auth', perUser: false, perIp: true, failClosed: true,
});

/** Create order: 5 req / min per user */
export const orderCreateRateLimit = routeRateLimit({
  maxRequests: 5, windowSeconds: 60, keyPrefix: 'order:create', perUser: true, perIp: true,
});

/** Manage existing orders: 10 req / min per user */
export const orderManageRateLimit = routeRateLimit({
  maxRequests: 10, windowSeconds: 60, keyPrefix: 'order:manage', perUser: true, perIp: true,
});

/** Payment endpoints: 10 req / min per user — FAIL-CLOSED (argent) */
export const paymentRateLimit = routeRateLimit({
  maxRequests: 10, windowSeconds: 60, keyPrefix: 'payment', perUser: true, perIp: true, failClosed: true,
});

/** Webhook endpoints: 100 req / min per IP (Stripe retries) */
export const webhookRateLimit = routeRateLimit({
  maxRequests: 100, windowSeconds: 60, keyPrefix: 'webhook', perUser: false, perIp: true, logBreach: false,
});

/** POS sync: 30 req / min per user */
export const posSyncRateLimit = routeRateLimit({
  maxRequests: 30, windowSeconds: 60, keyPrefix: 'pos:sync', perUser: true, perIp: false,
});

/** Inventory adjust: 20 req / min per user */
export const inventoryRateLimit = routeRateLimit({
  maxRequests: 20, windowSeconds: 60, keyPrefix: 'inventory', perUser: true, perIp: false,
});

/** Subscription confirm/cancel: 5 req / min per user — FAIL-CLOSED (argent) */
export const subscriptionRateLimit = routeRateLimit({
  maxRequests: 5, windowSeconds: 60, keyPrefix: 'subscription', perUser: true, perIp: true, failClosed: true,
});

/** Admin endpoints: 30 req / min per user — FAIL-CLOSED (privilèges) */
export const adminRateLimit = routeRateLimit({
  maxRequests: 30, windowSeconds: 60, keyPrefix: 'admin', perUser: true, perIp: true, failClosed: true,
});
