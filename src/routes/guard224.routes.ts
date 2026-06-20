/**
 * 🛡️ 224Guard — ingestion & lecture des alertes (Lot C).
 * - POST /alert  : toute session (authentifiée) remonte une alerte DÉJÀ masquée.
 *   Le backend persiste (service_role) + publie sur Ably (best-effort, clé serveur).
 * - GET  /summary, GET /alerts, POST /alert/:id/status : réservés admin/PDG.
 *
 * Aucune valeur de clé en clair n'est jamais attendue ni stockée (hash + masque seuls).
 */

import { Router, Response } from 'express';
import { z } from 'zod';
import { verifyJWT, requireRole } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();
const PDG_ROLES = ['admin', 'pdg', 'ceo'];
const ABLY_CHANNEL = 'guard224:alerts';

const alertSchema = z.object({
  client_id: z.string().max(64).optional(),
  type: z.string().max(40),
  severity: z.enum(['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']),
  pattern_key: z.string().max(80),
  label: z.string().max(300).optional(),
  key_hash: z.string().max(160).optional(),
  masked: z.string().max(200).optional(),
  sources: z.array(z.string().max(40)).max(20).optional(),
  locations: z.array(z.string().max(300)).max(50).optional(),
  score: z.any().optional(),
  count: z.number().int().min(1).max(1_000_000).optional(),
});

// Rate-limit best-effort par session (anti-flood d'ingestion, cf. attaque #5).
const buckets = new Map<string, { n: number; ts: number }>();
const RL_MAX = 120;
const RL_WINDOW = 60_000;
function rateLimited(userId: string): boolean {
  const t = Date.now();
  const b = buckets.get(userId) ?? { n: 0, ts: t };
  if (t - b.ts > RL_WINDOW) { b.n = 0; b.ts = t; }
  b.n++;
  buckets.set(userId, b);
  return b.n > RL_MAX;
}

async function publishAbly(payload: unknown): Promise<void> {
  const apiKey = process.env.ABLY_API_KEY;
  if (!apiKey) return; // Ably non configuré → silencieux (la persistance suffit).
  try {
    const Ably = await import('ably');
    const rest = new (Ably as any).Rest(apiKey);
    await rest.channels.get(ABLY_CHANNEL).publish('alert', payload);
  } catch (e: any) {
    logger.warn(`[guard224] publication Ably échouée: ${e?.message}`);
  }
}

/** POST /api/v2/guard224/alert — ingestion d'une alerte (toute session authentifiée). */
router.post('/alert', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const parsed = alertSchema.safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: parsed.error.issues[0].message }); return; }
    if (rateLimited(req.user!.id)) { res.status(429).json({ success: false, error: 'Trop d\'alertes' }); return; }

    const a = parsed.data;
    const row = {
      client_id: a.client_id ?? null,
      type: a.type,
      severity: a.severity,
      pattern_key: a.pattern_key,
      label: a.label ?? null,
      key_hash: a.key_hash ?? null,
      masked: a.masked ?? null,
      sources: a.sources ?? [],
      locations: a.locations ?? [],
      score: a.score ?? null,
      count: a.count ?? 1,
      status: 'OPEN',
      reporter_id: req.user!.id,
      user_agent: (req.headers['user-agent'] as string)?.slice(0, 300) ?? null,
    };

    const { data, error } = await supabaseAdmin.from('guard_224_alerts').insert(row).select('id').single();
    if (error) throw error;

    void publishAbly({ ...row, id: data?.id, created_at: new Date().toISOString() });
    res.json({ success: true, id: data?.id });
  } catch (e: any) {
    logger.error(`[guard224/alert] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur d\'ingestion' });
  }
});

/** GET /api/v2/guard224/summary — synthèse dashboard (admin/PDG). */
router.get('/summary', verifyJWT, requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.from('guard_224_dashboard_summary').select('*').maybeSingle();
    if (error) throw error;
    res.json({ success: true, summary: data });
  } catch (e: any) {
    logger.error(`[guard224/summary] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur synthèse' });
  }
});

/** GET /api/v2/guard224/alerts — liste récente (admin/PDG). */
router.get('/alerts', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const status = typeof req.query.status === 'string' ? req.query.status : null;
    let q = supabaseAdmin.from('guard_224_alerts').select('*').order('created_at', { ascending: false }).limit(200);
    if (status) q = q.eq('status', status);
    const { data, error } = await q;
    if (error) throw error;
    res.json({ success: true, alerts: data ?? [] });
  } catch (e: any) {
    logger.error(`[guard224/alerts] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lecture' });
  }
});

/** POST /api/v2/guard224/alert/:id/status — ACK / RESOLVED / FALSE_POSITIVE (admin/PDG). */
router.post('/alert/:id/status', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const status = String(req.body?.status || '').toUpperCase();
    if (!['OPEN', 'ACK', 'RESOLVED', 'FALSE_POSITIVE'].includes(status)) {
      res.status(400).json({ success: false, error: 'Statut invalide' }); return;
    }
    const { data: alert } = await supabaseAdmin.from('guard_224_alerts').select('pattern_key').eq('id', req.params.id).maybeSingle();
    const { error } = await supabaseAdmin.from('guard_224_alerts').update({ status, updated_at: new Date().toISOString() }).eq('id', req.params.id);
    if (error) throw error;

    // Apprentissage : un faux positif nourrit le trust score (jamais sur motif critique côté client).
    if (status === 'FALSE_POSITIVE' && alert?.pattern_key) {
      await supabaseAdmin.rpc('increment_guard224_false_positive', { p_pattern_key: alert.pattern_key }).then(
        () => {},
        async () => {
          // Fallback sans RPC : upsert manuel.
          const { data: cur } = await supabaseAdmin.from('guard_224_trust_scores').select('false_positives').eq('pattern_key', alert.pattern_key).maybeSingle();
          await supabaseAdmin.from('guard_224_trust_scores').upsert(
            { pattern_key: alert.pattern_key, false_positives: (cur?.false_positives ?? 0) + 1, updated_at: new Date().toISOString() },
            { onConflict: 'pattern_key' },
          );
        },
      );
    }
    res.json({ success: true });
  } catch (e: any) {
    logger.error(`[guard224/status] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur mise à jour' });
  }
});

/**
 * POST /api/v2/guard224/purge — clôture EN MASSE des faux positifs (admin/PDG).
 * Body : { pattern_key?, type? } (défaut : entropy.generic / HIGH_ENTROPY_STRING).
 * Passe les alertes OUVERTES correspondantes en RESOLVED (audit conservé, score nettoyé).
 */
router.post('/purge', verifyJWT, requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const patternKey = typeof req.body?.pattern_key === 'string' ? req.body.pattern_key : null;
    const type = typeof req.body?.type === 'string' ? req.body.type : null;

    let q = supabaseAdmin.from('guard_224_alerts')
      .update({ status: 'RESOLVED', updated_at: new Date().toISOString() })
      .eq('status', 'OPEN');

    if (patternKey) q = q.eq('pattern_key', patternKey);
    else if (type) q = q.eq('type', type);
    else q = q.or('pattern_key.eq.entropy.generic,type.eq.HIGH_ENTROPY_STRING'); // défaut : entropie

    const { data, error } = await q.select('id');
    if (error) throw error;
    res.json({ success: true, purged: data?.length ?? 0 });
  } catch (e: any) {
    logger.error(`[guard224/purge] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur de purge' });
  }
});

export default router;
