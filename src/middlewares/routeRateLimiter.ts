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

// 🚨 Redis indisponible : le PDG doit le SAVOIR (system_alerts), pas le découvrir.
// Une alerte par heure et par process, jamais bloquant pour la requête.
let lastRedisDownAlertAt = 0;
async function alertRedisUnavailableOnce(routeKey: string): Promise<void> {
  const now = Date.now();
  if (now - lastRedisDownAlertAt < 3600_000) return;
  lastRedisDownAlertAt = now;
  logger.error(`Rate limiter : Redis indisponible — repli MÉMOIRE par instance (route: ${routeKey})`);
  try {
    const { supabaseAdmin } = await import('../config/supabase.js');
    await supabaseAdmin.from('system_alerts').insert({
      title: 'Rate limiter : Redis indisponible',
      message: `Les limiteurs stricts tournent en repli MÉMOIRE par instance (quota exact en mono-instance ; jusqu'à N× le quota en multi-instance). Action : configurer REDIS_URL (+ NODE_ENV=production) sur le VPS. Première route touchée : ${routeKey}`,
      severity: 'high',
      module: 'rate_limiter',
      status: 'active',
      metadata: { route: routeKey },
    } as never);
  } catch { /* l'alerte ne casse jamais la requête */ }
}

/** État du limiteur (dashboard PDG) : Redis joignable ? entrées mémoire actives ? */
export async function rateLimiterState(): Promise<{ redis_available: boolean; mode: string; memory_entries: number }> {
  const { redisRateLimit } = await import('../config/redis.js');
  const probe = await redisRateLimit.check('health-probe', 1000000, 1);
  const up = probe.resetAt !== 0;
  return {
    redis_available: up,
    mode: up ? 'redis' : 'memoire_par_instance',
    memory_entries: memoryStore.size,
  };
}

/** Réarmement manuel (PDG) : vide le store mémoire (débloque un quota local). */
export function resetMemoryRateLimiter(): number {
  const n = memoryStore.size;
  memoryStore.clear();
  return n;
}

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
        // 🔧 CAUSE RACINE du « Service temporairement indisponible » PERMANENT
        // sur les routes ARGENT (retrait cash, dépôt, wallet-pay) : Redis absent
        // → l'ancien refus AVEUGLE bloquait 100 % des requêtes sans erreur
        // d'origine. Remplacé par le REPLI MÉMOIRE : le quota reste garanti PAR
        // INSTANCE (exact en mono-instance — la prod actuelle ; jusqu'à N× le
        // quota en multi-instance, compromis documenté), la disponibilité est
        // totale, et l'indisponibilité de Redis est ALERTÉE (system_alerts + log).
        await alertRedisUnavailableOnce(key);
        const strictMem = memoryRateLimit(key, maxRequests, windowSeconds * 1000);
        if (!strictMem.allowed) {
          if (logBreach) {
            await auditTrail.log({
              actorId: (req as any).user?.id || req.ip || 'unknown',
              actorType: 'user',
              action: 'rate_limit.exceeded',
              resourceType: 'endpoint',
              resourceId: req.originalUrl,
              ip: req.ip,
              riskLevel: 'high',
              metadata: { keyPrefix, reason: 'redis_unavailable_memory_fallback' },
            });
          }
          res.status(429).json({
            success: false,
            error: 'Trop de requêtes. Veuillez réessayer dans un moment.',
            error_code: 'RATE_LIMITED',
            retryAfter: windowSeconds,
          });
          return;
        }
        next();
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
          error_code: 'RATE_LIMITED',
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
        error_code: 'RATE_LIMITED',
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

/** Sondes d'auth NON sensibles (check-phone, email de secours) : anti-rafale
 *  par IP, fail-open (repli mémoire). authRateLimit fail-closed rendait la
 *  pré-vérification du numéro 429 permanente quand Redis est absent — or le
 *  filet réel est l'index UNIQUE en base + le flux OTP, pas ce limiteur. */
export const authSoftRateLimit = routeRateLimit({
  maxRequests: 30, windowSeconds: 900, keyPrefix: 'auth-soft', perUser: false, perIp: true, failClosed: false,
});

/** Studio Clips : anti-rafale par UTILISATEUR, fail-open (repli mémoire).
 *  Le quota/jour et l'idempotence vivent DANS la RPC create_clip_job — un
 *  fail-closed ici rendait la création de clips 429 permanente dès que Redis
 *  est absent (cause prouvée du « zéro clip jamais créé » en prod). Et le
 *  préfixe partagé 'auth' faisait consommer le budget des routes d'auth. */
export const clipCreateRateLimit = routeRateLimit({
  maxRequests: 10, windowSeconds: 60, keyPrefix: 'clips-create', perUser: true, perIp: false, failClosed: false,
});

/** Create order: 20 req / min per user (un checkout génère plusieurs POST légitimes :
 *  paiement mobile money retenté, cross-currency re-soumis, double-clic). 5/min bloquait
 *  des clients honnêtes. Combiné à idempotencyGuard AVANT ce middleware → seules les
 *  créations réellement nouvelles comptent. */
export const orderCreateRateLimit = routeRateLimit({
  maxRequests: 20, windowSeconds: 60, keyPrefix: 'order:create', perUser: true, perIp: true,
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

/** Cadeaux live (débit wallet réel) : 30 req / min per user — un envoi légitime est
 *  rare/manuel ; ce plafond coupe le spam de micro-cadeaux sans gêner un vrai donateur.
 *  Combiné à idempotencyGuard AVANT → les rejeux réseau ne comptent pas. */
export const giftRateLimit = routeRateLimit({
  maxRequests: 30, windowSeconds: 60, keyPrefix: 'live:gift', perUser: true, perIp: true,
});

/** Copilote IA (appel LLM = coût tokens réel) : 20 req / min per user. Un chat est
 *  manuel ; ce plafond stoppe l'abus/le scriptage qui ferait exploser la facture LLM. */
export const copilotRateLimit = routeRateLimit({
  maxRequests: 20, windowSeconds: 60, keyPrefix: 'copilot', perUser: true, perIp: true,
});
