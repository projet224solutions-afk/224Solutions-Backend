/**
 * 👻 FATOME EXCHANGE — santé du système FX + collecte forcée (PDG).
 * GET  /api/fx/health      → état réel : paires actives/périmées, âge max, dernière
 *                            collecte, 5 dernières alertes fx_*.
 * POST /api/fx/collect-now → relance la collecte complète + croisés (cooldown 2 min).
 * Accès : PDG/admin uniquement (verifyJWT + rôle re-vérifié serveur).
 */
import { Router, type Response } from 'express';
import { verifyJWT, type AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { ok, fail } from '../utils/apiResponse.js';
import { collectAfricanRates, materializeCrossRates } from '../services/fxRates.service.js';
import { logger } from '../config/logger.js';

const router = Router();

async function requirePdg(req: AuthenticatedRequest, res: Response): Promise<boolean> {
  const userId = (req as any).user?.id;
  const { data: prof } = await supabaseAdmin.from('profiles').select('role').eq('id', userId).maybeSingle();
  const role = String((prof as any)?.role || '').toLowerCase();
  if (!['pdg', 'admin', 'ceo'].includes(role)) {
    fail(res, 403, 'Accès réservé au PDG', 'FORBIDDEN');
    return false;
  }
  return true;
}

router.get('/health', verifyJWT, async (req: AuthenticatedRequest, res) => {
  try {
    if (!(await requirePdg(req, res))) return;
    const FRESH_MS = 48 * 3600 * 1000;

    const [{ data: rates }, { data: lastLog }, { data: alerts }] = await Promise.all([
      supabaseAdmin.from('currency_exchange_rates')
        .select('from_currency, to_currency, retrieved_at, source_type').eq('is_active', true),
      supabaseAdmin.from('fx_collection_log')
        .select('status, collected_at, currency_code')
        .in('status', ['OK', 'NO_CHANGE', 'BCRG_CACHED', 'FALLBACK'])
        .order('collected_at', { ascending: false }).limit(1).maybeSingle(),
      supabaseAdmin.from('financial_security_alerts')
        .select('alert_type, title, severity, created_at, is_resolved')
        .like('alert_type', 'fx%')
        .order('created_at', { ascending: false }).limit(5),
    ]);

    let fresh = 0; let stale = 0; let oldestMs = 0; let crossCount = 0;
    for (const r of rates || []) {
      const age = r.retrieved_at ? Date.now() - new Date(r.retrieved_at).getTime() : Number.MAX_SAFE_INTEGER;
      if (age < FRESH_MS) fresh++; else stale++;
      if (age > oldestMs && age < Number.MAX_SAFE_INTEGER) oldestMs = age;
      if (r.source_type === 'cross') crossCount++;
    }
    const status = stale === 0 ? 'green' : fresh > stale ? 'orange' : 'red';

    return ok(res, {
      status,
      pairs_active: (rates || []).length,
      pairs_fresh: fresh,
      pairs_stale: stale,
      pairs_cross: crossCount,
      oldest_age_hours: Math.round(oldestMs / 3600000),
      last_collection_at: (lastLog as any)?.collected_at || null,
      alerts: alerts || [],
    });
  } catch (e: any) {
    logger.error(`[FX/health] ${e.message}`);
    return fail(res, 500, 'Erreur santé FX', 'FX_HEALTH_ERROR');
  }
});

let lastForcedAt = 0;
router.post('/collect-now', verifyJWT, async (req: AuthenticatedRequest, res) => {
  try {
    if (!(await requirePdg(req, res))) return;
    if (Date.now() - lastForcedAt < 2 * 60 * 1000) {
      return fail(res, 429, 'Collecte déjà lancée il y a moins de 2 minutes', 'FX_COOLDOWN');
    }
    lastForcedAt = Date.now();
    const result = await collectAfricanRates();
    const crosses = await materializeCrossRates();
    return ok(res, {
      ok: result.ok, fallback: result.fallback, cached: result.cached,
      failed: result.failed, duration_ms: result.durationMs, crosses_materialized: crosses,
    });
  } catch (e: any) {
    logger.error(`[FX/collect-now] ${e.message}`);
    return fail(res, 500, 'Échec de la collecte forcée', 'FX_COLLECT_ERROR');
  }
});

// 👻 V4/V6 — Revenus FX (spread) par corridor, pour le dashboard PDG.
router.get('/revenue', verifyJWT, async (req: AuthenticatedRequest, res) => {
  try {
    if (!(await requirePdg(req, res))) return;
    const days = Math.min(365, Math.max(1, Number(req.query.days) || 30));
    const since = new Date(Date.now() - days * 86400000).toISOString();
    const { data, error } = await supabaseAdmin.rpc('fx_revenue_by_corridor', { p_since: since });
    if (error) throw error;
    const rows = (data as any[]) || [];
    const total = rows.reduce((s, r) => s + Number(r.total || 0), 0);
    return ok(res, { corridors: rows, total, days });
  } catch (e: any) {
    logger.error(`[FX/revenue] ${e.message}`);
    return fail(res, 500, 'Erreur revenus FX', 'FX_REVENUE_ERROR');
  }
});

export default router;
