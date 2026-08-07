/**
 * ❤️ HEALTH CHECK - Phase 6 Enhanced
 *
 * Liveness, readiness, and deep health probes.
 * Includes Redis, job queue, and metrics status.
 */

import { Router, Request, Response } from 'express';
import { checkSupabaseConnection, supabaseAdmin } from '../config/supabase.js';
import { redisHealthCheck, isRedisConnected } from '../config/redis.js';
import { metrics } from '../services/metrics.service.js';
import { env } from '../config/env.js';
import { routeRateLimit } from '../middlewares/routeRateLimiter.js';

const router = Router();

// Œil externe (GitHub Actions §5) — sonde publique VOLONTAIREMENT minimale.
const sentinelProbeRateLimit = routeRateLimit({
  maxRequests: 30, windowSeconds: 60, keyPrefix: 'health:sentinel', perIp: true,
});

/**
 * GET /health — Liveness probe (always returns 200 if process is alive)
 */
router.get('/', (_req: Request, res: Response) => {
  res.json({
    success: true,
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    environment: env.NODE_ENV,
    version: '3.0.0-phase6',
  });
});

/**
 * GET /health/sentinel — DEAD-MAN'S SWITCH, sonde pour l'œil externe (§5).
 * Ne renvoie QUE l'âge du heartbeat et un statut : AUCUN détail d'anomalie, AUCUNE
 * donnée, aucune structure interne. Rate-limité. Fail-closed : lecture impossible
 * → status 'unknown' (jamais un faux « ok »).
 */
router.get('/sentinel', sentinelProbeRateLimit, async (_req: Request, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('fatome_sentinel_heartbeat')
      .select('last_beat')
      .eq('id', 1)
      .maybeSingle();
    if (error || !data?.last_beat) {
      res.status(503).json({ success: false, status: 'unknown' });
      return;
    }
    const age = Math.round((Date.now() - new Date(data.last_beat as string).getTime()) / 1000);
    const status = age <= 300 ? 'ok' : age <= 900 ? 'stale' : 'dead';
    res.status(status === 'dead' ? 503 : 200).json({
      success: status !== 'dead',
      status,
      heartbeat_age_seconds: age,
    });
  } catch {
    res.status(503).json({ success: false, status: 'unknown' });
  }
});

/**
 * GET /health/ready — Readiness probe (checks critical dependencies)
 */
router.get('/ready', async (_req: Request, res: Response) => {
  const supabase = await checkSupabaseConnection();

  if (!supabase.success) {
    res.status(503).json({ success: false, status: 'not_ready', reason: 'supabase_unavailable' });
    return;
  }

  res.json({ success: true, status: 'ready' });
});

/**
 * GET /health/detailed — Deep health check with all dependencies
 */
router.get('/detailed', async (_req: Request, res: Response) => {
  const [supabaseStatus, redisStatus] = await Promise.all([
    checkSupabaseConnection(),
    redisHealthCheck(),
  ]);

  const memUsage = process.memoryUsage();
  const metricsSnapshot = metrics.getSnapshot();

  const overallStatus = supabaseStatus.success ? 'healthy' : 'degraded';

  res.json({
    success: true,
    status: overallStatus,
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    environment: env.NODE_ENV,
    version: '3.0.0-phase6',

    dependencies: {
      supabase: {
        status: supabaseStatus.success ? 'up' : 'down',
        latencyMs: supabaseStatus.latencyMs,
      },
      redis: {
        status: redisStatus.available ? 'up' : (process.env.REDIS_ENABLED === 'false' ? 'disabled' : 'down'),
        latencyMs: redisStatus.latencyMs,
        connected: isRedisConnected(),
      },
    },

    system: {
      memory: {
        heapUsed: `${Math.round(memUsage.heapUsed / 1024 / 1024)} MB`,
        heapTotal: `${Math.round(memUsage.heapTotal / 1024 / 1024)} MB`,
        rss: `${Math.round(memUsage.rss / 1024 / 1024)} MB`,
        external: `${Math.round((memUsage.external || 0) / 1024 / 1024)} MB`,
      },
      node: process.version,
      platform: process.platform,
      pid: process.pid,
      uptimeSeconds: Math.floor(process.uptime()),
    },

    metrics: {
      requests: metricsSnapshot.counters,
      latency: metricsSnapshot.histograms,
    },
  });
});

/**
 * GET /health/ops — Operational status for admin dashboards
 */
router.get('/ops', async (_req: Request, res: Response) => {
  const [supabaseStatus, redisStatus] = await Promise.all([
    checkSupabaseConnection(),
    redisHealthCheck(),
  ]);

  // Check for concerning indicators
  const memUsage = process.memoryUsage();
  const heapUsedMB = memUsage.heapUsed / 1024 / 1024;
  const concerns: string[] = [];

  if (!supabaseStatus.success) concerns.push('Supabase connection failed');
  if (!redisStatus.available && process.env.REDIS_ENABLED !== 'false') concerns.push('Redis unavailable (using fallback)');
  if (heapUsedMB > 512) concerns.push(`High memory usage: ${Math.round(heapUsedMB)}MB`);
  if (supabaseStatus.latencyMs && supabaseStatus.latencyMs > 1000) concerns.push(`Slow Supabase: ${supabaseStatus.latencyMs}ms`);

  res.json({
    success: true,
    status: concerns.length === 0 ? 'nominal' : concerns.length <= 1 ? 'warning' : 'critical',
    concerns,
    timestamp: new Date().toISOString(),
    uptimeHours: Math.round(process.uptime() / 3600 * 10) / 10,
  });
});

export default router;
