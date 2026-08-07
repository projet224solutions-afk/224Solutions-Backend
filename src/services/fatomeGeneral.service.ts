/**
 * 👻 FATOME GÉNÉRAL — le superviseur de TOUS les Fatomes (§9.1/§9.3, squelette vague 1).
 * Toutes les 5 min (leader-gardé via server.ts), pour chaque Fatome du registre :
 * heartbeat frais ? santé OK ? cadence respectée ? → verdict SAIN/DÉGRADÉ/MORT/INCONNU
 * journalisé (append-only) + anomalie Fatome si un Fatome critique est MORT.
 * FAIL-CLOSED : une santé qui échoue = INCONNU, jamais « OK » par défaut.
 * NB (dit au rapport) : la séparation de PROCESSUS n'est pas possible en l'état (un seul
 * worker pm2) — le Général tourne sur un CYCLE SÉPARÉ de la sentinelle, et c'est le
 * vérificateur pg_cron (hors backend) qui vérifie le Général (§9.3).
 * §9.2 CONTRÔLES CROISÉS : un Fatome qui dit « tout va bien » alors que ses ENTRÉES prouvent
 * le contraire est déclaré SUSPECT (surveillant aveugle). Implémenté ci-dessous.
 * Aucun accès en écriture à quoi que ce soit d'argent.
 */
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';

const INTERVAL_MS = Number(process.env.FATOME_GENERAL_INTERVAL_MS || 300_000); // 5 min

type Verdict = 'SAIN' | 'DEGRADE' | 'MORT' | 'SUSPECT' | 'HEARTBEAT_MANQUANT' | 'INCONNU';

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
          const v = await this.checkOne(r);
          // §9.2 — CONTRÔLE CROISÉ : un « SAIN » démenti par ses propres entrées devient SUSPECT.
          if (v.verdict === 'SAIN') {
            const cross = await this.crossCheck(r.fatome_key);
            if (cross) { v.verdict = 'SUSPECT'; v.reason = cross; }
          }
          // 🔄 INCOHÉRENCE INVERSE : déclaré mort par le heartbeat, MAIS ses données prouvent
          // qu'il travaille → c'est un défaut de CÂBLAGE, pas une panne. Dire « MORT » ici
          // ferait sonner une alarme pour un service qui tourne (cas Fatome X du 07/08).
          if (v.verdict === 'MORT' || v.verdict === 'INCONNU') {
            const alive = await this.dataProvesAlive(r.fatome_key);
            if (alive) {
              v.verdict = 'HEARTBEAT_MANQUANT';
              v.reason = `heartbeat absent/vieux MAIS le travail est prouvé par les données (${alive}) — câblage du battement à corriger`;
            }
          }
          results.push(v);
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
          if (v.verdict === 'SUSPECT') {
            await supabaseAdmin.rpc('fatome_raise' as any, {
              p_type: `general:${v.fatome_key}_suspect`,
              p_ref: `monitor:general:${v.fatome_key}_suspect:${day}`,
              p_severity: 'critical',
              p_detail: { reason: v.reason, source: 'fatome_general_crosscheck' },
            });
          } else {
            await supabaseAdmin.rpc('fatome_resolve_type' as any, { p_type: `general:${v.fatome_key}_suspect` });
          }
        } catch (e: any) { logger.warn(`[FatomeGeneral] anomalie suspect ${v.fatome_key}: ${e?.message || e}`); }
        // Battement non câblé : signalé en 'high' (à corriger), jamais en critique — le
        // service fonctionne, c'est sa preuve de vie qui manque.
        try {
          if (v.verdict === 'HEARTBEAT_MANQUANT') {
            await supabaseAdmin.rpc('fatome_raise' as any, {
              p_type: `general:${v.fatome_key}_heartbeat_missing`,
              p_ref: `monitor:general:${v.fatome_key}_heartbeat_missing:${day}`,
              p_severity: 'high',
              p_detail: { reason: v.reason, source: 'fatome_general_inverse_check' },
            });
          } else {
            await supabaseAdmin.rpc('fatome_resolve_type' as any,
              { p_type: `general:${v.fatome_key}_heartbeat_missing` });
          }
        } catch (e: any) { logger.warn(`[FatomeGeneral] anomalie heartbeat ${v.fatome_key}: ${e?.message || e}`); }
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

  /**
   * SOURCE DE VÉRITÉ « DONNÉES » : le Fatome produit-il un travail RÉCENT, indépendamment
   * de son heartbeat ? Renvoie une preuve lisible, ou null. Permet de distinguer un
   * travailleur DONT LE BATTEMENT N'EST PAS CÂBLÉ d'un travailleur réellement mort.
   */
  private async dataProvesAlive(key: string): Promise<string | null> {
    const FRESH_MS = 2 * 3600_000;   // travail « récent » = moins de 2 h
    try {
      if (key === 'fatome_x') {
        const { data } = await supabaseAdmin
          .from('currency_exchange_rates').select('retrieved_at')
          .order('retrieved_at', { ascending: false }).limit(1).maybeSingle();
        if (data?.retrieved_at && Date.now() - new Date(data.retrieved_at as string).getTime() < FRESH_MS) {
          return `dernière collecte de taux il y a ${Math.round((Date.now() - new Date(data.retrieved_at as string).getTime()) / 60000)} min`;
        }
      }
      if (key === 'fatome_sentinelle') {
        const { data } = await supabaseAdmin
          .from('fatome_activity_log').select('run_at')
          .eq('fatome_key', 'fatome_sentinelle')
          .order('run_at', { ascending: false }).limit(1).maybeSingle();
        if (data?.run_at && Date.now() - new Date(data.run_at as string).getTime() < FRESH_MS) {
          return 'cycles de l\'étage B journalisés récemment';
        }
      }
      if (key === 'fatome_fonctionnalites') {
        const { data } = await supabaseAdmin
          .from('fatome_probe_runs').select('run_at')
          .order('run_at', { ascending: false }).limit(1).maybeSingle();
        if (data?.run_at && Date.now() - new Date(data.run_at as string).getTime() < FRESH_MS) {
          return 'sondes exécutées récemment';
        }
      }
    } catch (e: any) {
      logger.warn(`[FatomeGeneral] preuve par les données ${key}: ${e?.message || e}`);
    }
    return null;
  }

  /**
   * §9.2 — CONTRÔLE CROISÉ. Renvoie la RAISON du soupçon, ou null si la cohérence tient.
   * Principe : on confronte ce que le Fatome AFFIRME à ce que ses ENTRÉES montrent.
   */
  private async crossCheck(key: string): Promise<string | null> {
    try {
      if (key === 'fatome_sentinelle') {
        // « 0 anomalie » alors que les erreurs réelles explosent → surveillant aveugle.
        const { count: anomalies } = await supabaseAdmin
          .from('fatome_anomalies').select('id', { count: 'exact', head: true })
          .eq('resolved', false);
        const { count: incidents } = await supabaseAdmin
          .from('fatome_feature_incidents').select('id', { count: 'exact', head: true })
          .is('resolved_at', null);
        if ((anomalies || 0) === 0 && (incidents || 0) >= 3) {
          return `dit « 0 anomalie » alors que ${incidents} incident(s) fonctionnel(s) sont ouverts — surveillant aveugle probable`;
        }
        // Étage B qui tourne mais n'a rien journalisé depuis 30 min → cycle vide suspect.
        const { data: act } = await supabaseAdmin
          .from('fatome_activity_log').select('run_at')
          .eq('fatome_key', 'fatome_sentinelle').order('run_at', { ascending: false }).limit(1).maybeSingle();
        if (act?.run_at && Date.now() - new Date(act.run_at as string).getTime() > 30 * 60_000) {
          return 'bat le heartbeat mais n\'a journalisé aucun cycle depuis plus de 30 min';
        }
      }

      if (key === 'fatome_x') {
        // « taux frais » alors que la dernière ligne de taux date de plus de 24 h → il ment ou il est cassé.
        const { data: last } = await supabaseAdmin
          .from('currency_exchange_rates').select('retrieved_at')
          .order('retrieved_at', { ascending: false }).limit(1).maybeSingle();
        const age = last?.retrieved_at ? Date.now() - new Date(last.retrieved_at as string).getTime() : Infinity;
        if (age > 24 * 3600_000) {
          return `annonce des taux sains alors que la dernière collecte date de ${Math.round(age / 3600_000)} h`;
        }
      }

      if (key === 'fatome_fonctionnalites') {
        // Sondes déclarées mais AUCUN run récent → exécuteur qui tourne à vide.
        const { count: probes } = await supabaseAdmin
          .from('fatome_feature_probes').select('probe_key', { count: 'exact', head: true }).eq('enabled', true);
        if ((probes || 0) > 0) {
          const { count: runs } = await supabaseAdmin
            .from('fatome_probe_runs').select('id', { count: 'exact', head: true })
            .gte('run_at', new Date(Date.now() - 2 * 3600_000).toISOString());
          if ((runs || 0) === 0) {
            return `${probes} sonde(s) déclarée(s) mais AUCUNE exécution depuis 2 h — exécuteur aveugle`;
          }
        }
      }
    } catch (e: any) {
      logger.warn(`[FatomeGeneral] contrôle croisé ${key}: ${e?.message || e}`);
    }
    return null;
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
