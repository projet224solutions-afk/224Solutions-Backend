/**
 * 👻 FATOME GÉNÉRAL — le superviseur de TOUS les Fatomes (§9.1/§9.3, squelette vague 1).
 * Toutes les 5 min (leader-gardé via server.ts), pour chaque Fatome du registre :
 * heartbeat frais ? santé OK ? cadence respectée ? → verdict SAIN/DÉGRADÉ/MORT/INCONNU
 * journalisé (append-only) + anomalie Fatome si un Fatome critique est MORT.
 * FAIL-CLOSED : une santé qui échoue = INCONNU, jamais « OK » par défaut.
 * NB (dit au rapport) : la séparation de PROCESSUS n'est pas possible en l'état (un seul
 * worker pm2) — le Général tourne sur un CYCLE SÉPARÉ de la sentinelle, et c'est le
 * vérificateur pg_cron (hors backend) qui vérifie le Général (§9.3).
 * Les contrôles CROISÉS (§9.2 : verdict SUSPECT) sont VAGUE 3 — non implémentés ici.
 * Aucun accès en écriture à quoi que ce soit d'argent.
 */
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';

const INTERVAL_MS = Number(process.env.FATOME_GENERAL_INTERVAL_MS || 300_000); // 5 min

type Verdict = 'SAIN' | 'DEGRADE' | 'MORT' | 'INCONNU';

interface RegistryRow {
  fatome_key: string;
  label: string;
  health_check_rpc: string | null;
  expected_interval_sec: number | null;
  criticality: string;
  enabled: boolean;
}

interface CheckResult {
  fatome_key: string;
  verdict: Verdict;
  reason: string;
  heartbeat_age_sec: number | null;
  detail?: Record<string, unknown>;
}

class FatomeGeneralService {
  private interval: ReturnType<typeof setInterval> | null = null;
  private running = false;
  private cycleCount = 0;

  start(): void {
    if (this.interval) return;
    logger.info(`[FatomeGeneral] Supervision des Fatomes toutes les ${INTERVAL_MS}ms (cycle séparé de la sentinelle)`);
    void this.runOnce();
    this.interval = setInterval(() => { void this.runOnce(); }, INTERVAL_MS);
  }

  stop(): void {
    if (this.interval) { clearInterval(this.interval); this.interval = null; }
  }

  private async runOnce(): Promise<void> {
    if (this.running) return;
    this.running = true;
    const t0 = Date.now();
    let ok = true; let err: string | null = null;
    const results: CheckResult[] = [];
    try {
      this.cycleCount++;
      const { data: registry, error: regErr } = await supabaseAdmin
        .from('fatome_registry').select('*').eq('enabled', true);
      if (regErr) throw new Error(`registry: ${regErr.message}`);

      for (const r of (registry || []) as RegistryRow[]) {
        if (r.fatome_key === 'fatome_general') continue; // le pg_cron NOUS vérifie (§9.3), pas nous-mêmes
        try {
          results.push(await this.checkOne(r));
        } catch (e: any) {
          // FAIL-CLOSED : un contrôle qui échoue = INCONNU, jamais SAIN.
          results.push({ fatome_key: r.fatome_key, verdict: 'INCONNU', reason: `contrôle en échec: ${String(e?.message || e).slice(0, 200)}`, heartbeat_age_sec: null });
        }
      }

      // Journal des verdicts (append-only) + anomalie si un Fatome critique est MORT.
      const day = new Date().toISOString().slice(0, 10);
      for (const v of results) {
        try {
          await supabaseAdmin.from('fatome_general_checks').insert({
            fatome_key: v.fatome_key, verdict: v.verdict, reason: v.reason,
            heartbeat_age_sec: v.heartbeat_age_sec, detail: v.detail || null,
          });
        } catch (e: any) { logger.warn(`[FatomeGeneral] journal verdict ${v.fatome_key}: ${e?.message || e}`); }

        const reg = ((registry || []) as RegistryRow[]).find((r) => r.fatome_key === v.fatome_key);
        const critical = reg?.criticality === 'critical' || reg?.criticality === 'high';
        const type = `general:${v.fatome_key}_dead`;
        try {
          if (v.verdict === 'MORT' && critical) {
            await supabaseAdmin.rpc('fatome_raise' as any, {
              p_type: type, p_ref: `monitor:${type}:${day}`, p_severity: 'critical',
              p_detail: { reason: v.reason, heartbeat_age_sec: v.heartbeat_age_sec, source: 'fatome_general' },
            });
          } else {
            await supabaseAdmin.rpc('fatome_resolve_type' as any, { p_type: type });
          }
        } catch (e: any) { logger.warn(`[FatomeGeneral] anomalie ${type}: ${e?.message || e}`); }
      }
    } catch (e: any) {
      ok = false; err = String(e?.message || e).slice(0, 500);
      logger.warn(`[FatomeGeneral] cycle en erreur: ${err}`);
    } finally {
      // Heartbeat du Général (contrat commun §9.1) + journal d'activité — best-effort.
      try {
        await supabaseAdmin.rpc('fatome_beat' as any, { p_key: 'fatome_general', p_ok: ok, p_error: err });
      } catch (e: any) { logger.warn(`[FatomeGeneral] beat: ${e?.message || e}`); }
      try {
        await supabaseAdmin.from('fatome_activity_log').insert({
          fatome_key: 'fatome_general', duration_ms: Date.now() - t0, ok,
          message: ok ? `Cycle ${this.cycleCount} : ${results.length} Fatome(s) contrôlés` : `Cycle en erreur : ${err}`,
          volume: { verdicts: results.map((r) => ({ k: r.fatome_key, v: r.verdict })) },
        });
      } catch { /* best-effort */ }
      this.running = false;
    }
  }

  private async checkOne(r: RegistryRow): Promise<CheckResult> {
    // Sentinelle : son heartbeat dédié (table à 1 ligne).
    if (r.fatome_key === 'fatome_sentinelle') {
      const { data } = await supabaseAdmin
        .from('fatome_sentinel_heartbeat').select('*').eq('id', 1).maybeSingle();
      if (!data?.last_beat) return { fatome_key: r.fatome_key, verdict: 'MORT', reason: 'aucun battement enregistré', heartbeat_age_sec: null };
      const age = Math.round((Date.now() - new Date(data.last_beat as string).getTime()) / 1000);
      if (age > 900) return { fatome_key: r.fatome_key, verdict: 'MORT', reason: `muette depuis ${Math.round(age / 60)} min`, heartbeat_age_sec: age };
      if (data.last_ok === false) return { fatome_key: r.fatome_key, verdict: 'DEGRADE', reason: `cycle en erreur: ${String(data.last_error || '?').slice(0, 150)}`, heartbeat_age_sec: age };
      const expected = Number(r.expected_interval_sec || 90);
      if (age > expected * 3) return { fatome_key: r.fatome_key, verdict: 'DEGRADE', reason: `cadence dégradée (${age}s > 3×${expected}s attendues)`, heartbeat_age_sec: age };
      return { fatome_key: r.fatome_key, verdict: 'SAIN', reason: `battement il y a ${age}s, cycles: ${data.cycle_count}`, heartbeat_age_sec: age };
    }

    // Fatome X : santé via SA RPC de registre (fx_monitor_report) — fail-closed.
    if (r.health_check_rpc) {
      const { data, error } = await supabaseAdmin.rpc(r.health_check_rpc as any, {});
      if (error) return { fatome_key: r.fatome_key, verdict: 'INCONNU', reason: `santé injoignable: ${error.message.slice(0, 150)}`, heartbeat_age_sec: null };
      const checks: Array<{ key: string; severity: string; count: number }> = (data as any)?.checks || [];
      const failing = checks.filter((c) => Number(c.count || 0) > 0);
      const worst = failing.some((c) => c.severity === 'critical') ? 'critical'
        : failing.some((c) => c.severity === 'high') ? 'high' : failing.length ? 'medium' : 'none';
      if (worst === 'critical') return { fatome_key: r.fatome_key, verdict: 'DEGRADE', reason: `signale du critique: ${failing.map((c) => c.key).join(', ').slice(0, 150)}`, heartbeat_age_sec: null, detail: { failing } };
      if (worst === 'high' || worst === 'medium') return { fatome_key: r.fatome_key, verdict: 'DEGRADE', reason: `signale: ${failing.map((c) => c.key).join(', ').slice(0, 150)}`, heartbeat_age_sec: null, detail: { failing } };
      return { fatome_key: r.fatome_key, verdict: 'SAIN', reason: `${checks.length} contrôle(s) au vert`, heartbeat_age_sec: null };
    }

    // Contrat commun : heartbeat dans fatome_heartbeats.
    const { data: hb } = await supabaseAdmin
      .from('fatome_heartbeats').select('*').eq('fatome_key', r.fatome_key).maybeSingle();
    if (!hb?.last_beat) return { fatome_key: r.fatome_key, verdict: 'INCONNU', reason: 'aucun heartbeat (jamais démarré ?)', heartbeat_age_sec: null };
    const age = Math.round((Date.now() - new Date(hb.last_beat as string).getTime()) / 1000);
    const expected = Number(r.expected_interval_sec || 300);
    if (age > expected * 3) return { fatome_key: r.fatome_key, verdict: 'MORT', reason: `muet depuis ${Math.round(age / 60)} min (attendu toutes les ${expected}s)`, heartbeat_age_sec: age };
    if (hb.last_ok === false) return { fatome_key: r.fatome_key, verdict: 'DEGRADE', reason: `en erreur: ${String(hb.last_error || '?').slice(0, 150)}`, heartbeat_age_sec: age };
    return { fatome_key: r.fatome_key, verdict: 'SAIN', reason: `battement il y a ${age}s`, heartbeat_age_sec: age };
  }
}

export const fatomeGeneralService = new FatomeGeneralService();
