import { env } from '../config/env.js';
import { logger } from '../config/logger.js';
import { checkSupabaseConnection, supabaseAdmin } from '../config/supabase.js';
import { redisHealthCheck, locks, isRedisConnected } from '../config/redis.js';
import { emitCoreFeatureEvent, type FeatureHealthStatus } from './coreFeatureEvents.service.js';
import { runPlatformMonitors, autoResolveStaleEventAlerts } from './escrowMonitor.service.js';
import { triggerAffiliateCommission } from './commission.service.js';
import { ingestAndSummarize, scanAndDiagnose } from './autoHealing.service.js';

type ServiceStatus = 'healthy' | 'degraded' | 'critical' | 'unknown';

interface ServiceCheckResult {
  serviceName: string;
  displayName: string;
  status: ServiceStatus;
  responseTimeMs: number;
  message: string;
  metadata?: Record<string, any>;
}

interface FeatureCheckResult {
  featureKey: string;
  status: FeatureHealthStatus;
  durationMs: number;
  message: string;
}

interface SurveillanceRunSummary {
  trigger: string;
  startedAt: string;
  finishedAt: string;
  durationMs: number;
  services: ServiceCheckResult[];
  features: FeatureCheckResult[];
}

class Surveillance24x7Service {
  private interval: ReturnType<typeof setInterval> | null = null;
  private isRunning = false;
  private readonly intervalMs: number;
  private cycleCount = 0;
  // Le scan RÉSEAU sécurité-frontend (lourd, ~100s) ne tourne PAS à chaque cycle : au démarrage
  // puis toutes les ~30 min. Entre-temps, les cycles 60s restent rapides (domaines DB seulement).
  private readonly frontendScanEveryN: number;

  constructor() {
    this.intervalMs = Number(process.env.MONITORING_INTERVAL_MS || 60_000);
    const scanIntervalMs = Number(process.env.FRONTEND_SCAN_INTERVAL_MS || 1_800_000); // 30 min
    this.frontendScanEveryN = Math.max(1, Math.round(scanIntervalMs / this.intervalMs));
  }

  start(): void {
    if (!env.ENABLE_MONITORING) {
      logger.info('[Surveillance24x7] Monitoring disabled by ENABLE_MONITORING=false');
      return;
    }

    if (this.interval) return;

    logger.info(`[Surveillance24x7] Starting autonomous checks every ${this.intervalMs}ms`);
    void this.tick('startup');

    this.interval = setInterval(() => {
      void this.tick('interval');
    }, this.intervalMs);
  }

  /**
   * Tick protégé par un VERROU DISTRIBUÉ (Redis) : en multi-instance (ECS Fargate),
   * un seul conteneur exécute le cycle par fenêtre → pas de surveillance dupliquée
   * (pas de doubles alertes). Le verrou expire après ~1 fenêtre (anti-deadlock si crash).
   * Si Redis est absent (dev/instance unique), on exécute normalement.
   */
  private async tick(trigger: string): Promise<void> {
    const ttl = Math.max(10, Math.floor(this.intervalMs / 1000) - 5);
    if (isRedisConnected()) {
      const got = await locks.acquire('surveillance:tick', ttl);
      if (!got) {
        // Une autre instance détient la fenêtre → on saute (pas de doublon).
        return;
      }
    }
    await this.runOnce(trigger);
  }

  stop(): void {
    if (!this.interval) return;
    clearInterval(this.interval);
    this.interval = null;
    logger.info('[Surveillance24x7] Stopped');
  }

  async runOnce(trigger: string = 'manual'): Promise<SurveillanceRunSummary | null> {
    if (this.isRunning) {
      logger.info('[Surveillance24x7] Skip run: previous cycle still running');
      return null;
    }

    this.isRunning = true;
    const cycleStart = Date.now();
    const startedAtIso = new Date(cycleStart).toISOString();

    try {
      const services = await this.collectServiceStatuses();
      await this.persistServiceStatuses(services);

      const features = await this.collectFeatureStatuses();
      await this.persistFeatureStatuses(features, trigger);

      // Surveillance plateforme (escrow/conversion + abonnements) → alertes system_alerts (best-effort).
      // Le scan RÉSEAU sécurité-frontend (lourd) ne tourne qu'au 1er cycle puis tous les frontendScanEveryN.
      this.cycleCount++;
      // 💓 Santé du cycle pour le HEARTBEAT (dead-man's switch) : un bloc critique qui échoue rend
      // la Sentinelle aveugle → on le remonte en last_ok=false (plus un simple logger.warn ignoré).
      let cycleOk = true; let cycleErr: string | null = null;
      const includeFrontendScan = this.cycleCount === 1 || this.cycleCount % this.frontendScanEveryN === 0;
      // UN SEUL run des monitors : synchro system_alerts (dans runPlatformMonitors) + on CONSERVE
      // le rapport pour la 2e synchro (Fatome, étage B ci-dessous) — jamais deux fois les RPC.
      let platformReport: Awaited<ReturnType<typeof runPlatformMonitors>> | null = null;
      try {
        platformReport = await runPlatformMonitors({ skipFnDomains: !includeFrontendScan });
      } catch (e: any) {
        cycleOk = false; cycleErr = `platform_monitor: ${e?.message || e}`;
        logger.warn(`[Surveillance24x7] platform monitor failed: ${e?.message || e}`);
      }

      // 📊 COMPTA — rollup PDG (leader-gardé, jamais dans le chemin d'une requête user) :
      // rafraîchit J et J-1 régulièrement (idempotent) + rattrapage 7 j moins souvent (les
      // saisies tardives de dépenses existent) + balayage de rapprochement (échantillon).
      // Gaté sur le compteur de cycles pour ne pas recalculer à chaque tick de 60 s.
      try {
        const every60 = this.cycleCount === 1 || this.cycleCount % 60 === 0;      // ~1×/h
        const every720 = this.cycleCount === 1 || this.cycleCount % 720 === 0;    // ~1×/12h (rattrapage 7j + sweep)
        if (every60) {
          const to = new Date().toISOString().slice(0, 10);
          const from = new Date(Date.now() - 86400000).toISOString().slice(0, 10); // J-1
          await supabaseAdmin.rpc('accounting_rollup_refresh' as any, { p_from: from, p_to: to });
        }
        if (every720) {
          const to = new Date().toISOString().slice(0, 10);
          const from7 = new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10);
          await supabaseAdmin.rpc('accounting_rollup_refresh' as any, { p_from: from7, p_to: to });
          await supabaseAdmin.rpc('pdg_accounting_reconcile_sweep' as any, { p_from: from7, p_to: to, p_sample: 50 });
        }
      } catch (e: any) {
        logger.warn(`[Surveillance24x7] accounting rollup failed: ${e?.message || e}`);
      }

      // 👻 FATOME SENTINELLE — Étage B : POINT DE CONVERGENCE de TOUTE la surveillance.
      // On RÉUTILISE le rapport plateforme ci-dessus (UN run, DEUX synchros — jamais de 2e appel RPC) :
      // pour CHAQUE domaine du registre (escrow, wallet, aml, coffre PDG, agent cash, commissions,
      // affiliation, …), les checks high/critical en anomalie → fatome_raise ; medium/low → system_alerts
      // seulement (pas de bruit Fatome). Type = '<domaine>:<key>', réf DATÉE (1 alerte max/jour/type,
      // sinon UNIQUE(type,ref) figerait le check). Check repassé à 0 → fatome_resolve_type (la carte PDG
      // suit l'état réel). system_alerts ne notifie PAS (aucun trigger) → une SEULE notif PDG par
      // anomalie/jour (fatome_raise idempotent).
      if (platformReport) {
        const day = new Date().toISOString().slice(0, 10);
        for (const dom of platformReport.domains) {
          for (const c of (dom.report?.checks || [])) {
            const sev = String(c?.severity || '');
            if (sev !== 'high' && sev !== 'critical') continue; // medium/low → system_alerts uniquement
            const type = `${dom.key}:${c.key}`;
            try {
              if (Number(c?.count || 0) > 0) {
                await supabaseAdmin.rpc('fatome_raise' as any, {
                  p_type: type, p_ref: `monitor:${type}:${day}`, p_severity: sev,
                  p_detail: { count: c.count, observed: c.observed, label: c.label, domain: dom.key, source: 'surveillance24x7_etageB' },
                });
              } else {
                await supabaseAdmin.rpc('fatome_resolve_type' as any, { p_type: type });
              }
            } catch (e: any) {
              logger.warn(`[Surveillance24x7] fatome escalation failed (${type}): ${e?.message || e}`);
            }
          }
        }
      }

      // 🔁 CH2 — RETRY des commissions d'affiliation EN ATTENTE (jamais perdues). Dès qu'un taux
      // frais existe, on convertit par Fatome (_acash_fx : taux+date+source, garde 24 h) et on verse
      // via le flux normal (idempotent par (transaction_id, related_user_id)). Leader-gardé (tout ce
      // cycle l'est) ; gaté ~toutes les 5 min pour ne pas marteler. Best-effort, jamais bloquant.
      if (this.cycleCount === 1 || this.cycleCount % 5 === 0) {
        try {
          const { data: pend } = await supabaseAdmin.rpc('affiliate_commission_pending_list' as any, { p_limit: 50 });
          for (const p of ((pend as any[]) || [])) {
            try {
              // UN SEUL point de conversion : on repasse le montant + la devise SOURCE au service, qui
              // convertit source→GNF (tracé) puis GNF→devise agent (tracé). Idempotent par transaction_id.
              // NO_RATE_SOURCE : fee_currency = devise source ; FX_DOWN : fee_currency = GNF (source déjà faite).
              const res = await triggerAffiliateCommission(p.beneficiary_user_id, Number(p.fee_amount), p.source_type, p.source_ref, p.fee_currency);
              const done = res.success && !res.pending; // pending = un leg toujours sans taux → reste en attente
              await supabaseAdmin.rpc('affiliate_commission_pending_mark' as any, {
                p_id: p.id, p_status: done ? 'resolved' : 'pending', p_error: done ? null : (res.error || 'still_pending'),
              });
            } catch (e: any) {
              await supabaseAdmin.rpc('affiliate_commission_pending_mark' as any, { p_id: p.id, p_status: 'pending', p_error: e?.message || String(e) });
            }
          }
        } catch (e: any) {
          logger.warn(`[Surveillance24x7] affiliate pending retry failed: ${e?.message || e}`);
        }
      }

      // Alertes ÉVÉNEMENTIELLES (224Guard, role.changed, observateur frontend…) : pas de
      // signal de fin → auto-résolution quand plus aucune occurrence depuis 24 h (72 h critiques).
      try {
        await autoResolveStaleEventAlerts();
      } catch (e: any) {
        logger.warn(`[Surveillance24x7] stale event alerts resolve failed: ${e?.message || e}`);
      }

      // Auto-réparation : ingestion RAPIDE des alertes actives en incidents (toujours, sans LLM).
      // Le diagnostic dual-IA (OpenAI→Claude) ne tourne en auto que si AUTO_HEALING_ENABLED=true
      // (sinon il reste à la demande via le bouton PDG « Scanner maintenant ») — maîtrise du coût LLM.
      try {
        if (process.env.AUTO_HEALING_ENABLED === 'true') await scanAndDiagnose();
        else await ingestAndSummarize();
      } catch (e: any) {
        logger.warn(`[Surveillance24x7] auto-healing failed: ${e?.message || e}`);
      }

      const summary: SurveillanceRunSummary = {
        trigger,
        startedAt: startedAtIso,
        finishedAt: new Date().toISOString(),
        durationMs: Date.now() - cycleStart,
        services,
        features,
      };

      logger.info(
        `[Surveillance24x7] Cycle complete trigger=${trigger} services=${services.length} features=${features.length} durationMs=${summary.durationMs}`
      );

      // 💓 HEARTBEAT (dead-man's switch) : le cycle a tourné → on bat. cycleOk=false si un bloc
      // critique a échoué (ex. runPlatformMonitors) → last_ok=false → le vérificateur pg_cron lève
      // sentinel_failing après 30 min. Best-effort : un heartbeat raté ne casse jamais le cycle.
      try {
        await supabaseAdmin.rpc('fatome_heartbeat_beat' as any, { p_ok: cycleOk, p_error: cycleErr, p_cycle: this.cycleCount });
      } catch (e: any) { logger.warn(`[Surveillance24x7] heartbeat beat failed: ${e?.message || e}`); }

      return summary;
    } catch (error: any) {
      logger.error(`[Surveillance24x7] Cycle failed: ${error?.message || 'unknown'}`);
      // 💓 HEARTBEAT en ERREUR : la panne du cycle devient une DONNÉE (plus un log ignoré).
      try {
        await supabaseAdmin.rpc('fatome_heartbeat_beat' as any, { p_ok: false, p_error: String(error?.message || error).slice(0, 500), p_cycle: this.cycleCount });
      } catch { /* best-effort */ }
      return null;
    } finally {
      this.isRunning = false;
    }
  }

  private async collectServiceStatuses(): Promise<ServiceCheckResult[]> {
    const results: ServiceCheckResult[] = [];

    const supabase = await checkSupabaseConnection();
    results.push({
      serviceName: 'database',
      displayName: 'Base de donnees',
      status: supabase.success ? 'healthy' : 'critical',
      responseTimeMs: supabase.latencyMs ?? -1,
      message: supabase.success ? 'Supabase SQL OK' : supabase.message,
    });

    const authStart = Date.now();
    try {
      const { error } = await supabaseAdmin.auth.admin.listUsers({ page: 1, perPage: 1 });
      if (error) throw error;
      results.push({
        serviceName: 'auth',
        displayName: 'Authentification',
        status: 'healthy',
        responseTimeMs: Date.now() - authStart,
        message: 'Supabase Auth OK',
      });
    } catch (error: any) {
      results.push({
        serviceName: 'auth',
        displayName: 'Authentification',
        status: 'critical',
        responseTimeMs: Date.now() - authStart,
        message: error?.message || 'Auth check failed',
      });
    }

    const realtimeStart = Date.now();
    try {
      const { error } = await supabaseAdmin.from('monitoring_service_status').select('id').limit(1);
      if (error) throw error;
      results.push({
        serviceName: 'realtime',
        displayName: 'Realtime',
        status: 'healthy',
        responseTimeMs: Date.now() - realtimeStart,
        message: 'Realtime channel tables reachable',
      });
    } catch (error: any) {
      results.push({
        serviceName: 'realtime',
        displayName: 'Realtime',
        status: 'degraded',
        responseTimeMs: Date.now() - realtimeStart,
        message: error?.message || 'Realtime check failed',
      });
    }

    const storageStart = Date.now();
    try {
      const { error } = await supabaseAdmin.storage.listBuckets();
      if (error) throw error;
      results.push({
        serviceName: 'storage',
        displayName: 'Stockage',
        status: 'healthy',
        responseTimeMs: Date.now() - storageStart,
        message: 'Storage API OK',
      });
    } catch (error: any) {
      results.push({
        serviceName: 'storage',
        displayName: 'Stockage',
        status: 'degraded',
        responseTimeMs: Date.now() - storageStart,
        message: error?.message || 'Storage check failed',
      });
    }

    const redisStatus = await redisHealthCheck();
    results.push({
      serviceName: 'security',
      displayName: 'Securite',
      status: redisStatus.available ? 'healthy' : 'degraded',
      responseTimeMs: redisStatus.latencyMs,
      message: redisStatus.available ? 'Redis lock layer OK' : 'Redis unavailable (fallback mode)',
      metadata: { redisAvailable: redisStatus.available },
    });

    results.push({
      serviceName: 'edge_functions',
      displayName: 'Edge Functions',
      status: supabase.success ? 'healthy' : 'degraded',
      responseTimeMs: supabase.latencyMs ?? -1,
      message: supabase.success ? 'Supabase project reachable' : 'Supabase degraded; edge functions at risk',
    });

    results.push({
      serviceName: 'pwa',
      displayName: 'PWA / Mobile',
      status: 'healthy',
      responseTimeMs: 1,
      message: 'Backend online for PWA/API clients',
    });

    return results;
  }

  private async persistServiceStatuses(rows: ServiceCheckResult[]): Promise<void> {
    const now = new Date().toISOString();

    for (const row of rows) {
      const payload: Record<string, any> = {
        service_name: row.serviceName,
        display_name: row.displayName,
        status: row.status,
        response_time_ms: row.responseTimeMs,
        last_check_at: now,
        updated_at: now,
        metadata: {
          source: 'node_backend_surveillance_24x7',
          message: row.message,
          ...(row.metadata || {}),
        },
      };

      if (row.status === 'healthy') {
        payload.last_healthy_at = now;
      }

      const { error } = await supabaseAdmin
        .from('monitoring_service_status')
        .upsert(payload, { onConflict: 'service_name' });

      if (error) {
        logger.warn(`[Surveillance24x7] Service status upsert failed (${row.serviceName}): ${error.message}`);
      }
    }
  }

  private async collectFeatureStatuses(): Promise<FeatureCheckResult[]> {
    const { data: features, error } = await supabaseAdmin
      .from('core_feature_registry')
      .select('feature_key')
      .eq('enabled', true)
      .eq('auto_monitor', true);

    if (error) {
      logger.warn(`[Surveillance24x7] Failed to load feature registry: ${error.message}`);
      return [];
    }

    const checks: FeatureCheckResult[] = [];

    for (const feature of features || []) {
      const featureKey = String((feature as any).feature_key || '');
      if (!featureKey) continue;
      checks.push(await this.runFeatureCheck(featureKey));
    }

    return checks;
  }

  private async runFeatureCheck(featureKey: string): Promise<FeatureCheckResult> {
    const start = Date.now();
    try {
      switch (featureKey) {
        case 'auth.login': {
          const { error } = await supabaseAdmin.auth.admin.listUsers({ page: 1, perPage: 1 });
          if (error) throw error;
          return { featureKey, status: 'success', durationMs: Date.now() - start, message: 'Auth admin API reachable' };
        }
        case 'wallet.transfer': {
          const { error } = await supabaseAdmin.from('wallets').select('id').limit(1);
          if (error) throw error;
          return { featureKey, status: 'success', durationMs: Date.now() - start, message: 'Wallet table reachable' };
        }
        case 'payment.links.process': {
          const { error } = await supabaseAdmin.from('payment_links').select('id').limit(1);
          if (error) throw error;
          return { featureKey, status: 'success', durationMs: Date.now() - start, message: 'Payment links table reachable' };
        }
        case 'marketplace.ranking': {
          const { error } = await supabaseAdmin.from('marketplace_visibility_settings').select('id').limit(1);
          if (error) throw error;
          return { featureKey, status: 'success', durationMs: Date.now() - start, message: 'Marketplace visibility settings reachable' };
        }
        case 'surveillance.detect_anomalies': {
          const { error } = await supabaseAdmin.from('monitoring_alerts').select('id').limit(1);
          if (error) throw error;
          return { featureKey, status: 'success', durationMs: Date.now() - start, message: 'Monitoring alerts table reachable' };
        }
        default: {
          const { error } = await supabaseAdmin.from('core_feature_health_events').select('id').limit(1);
          if (error) throw error;
          return { featureKey, status: 'degraded', durationMs: Date.now() - start, message: 'No dedicated checker yet' };
        }
      }
    } catch (error: any) {
      return {
        featureKey,
        status: 'failure',
        durationMs: Date.now() - start,
        message: error?.message || 'Feature check failed',
      };
    }
  }

  private async persistFeatureStatuses(rows: FeatureCheckResult[], trigger: string): Promise<void> {
    for (const row of rows) {
      await emitCoreFeatureEvent({
        featureKey: row.featureKey,
        status: row.status,
        signalType: 'synthetic',
        source: 'node_surveillance_24x7',
        payload: {
          trigger,
          durationMs: row.durationMs,
          message: row.message,
        },
      });

      if (row.status === 'failure') {
        const { error } = await supabaseAdmin.from('monitoring_events').insert({
          event_type: 'core_feature_failure',
          source: 'node_surveillance_24x7',
          severity: 'high',
          message: `Feature check failed: ${row.featureKey}`,
          service_name: 'edge_functions',
          metadata: {
            featureKey: row.featureKey,
            durationMs: row.durationMs,
            reason: row.message,
            trigger,
          },
          response_time_ms: row.durationMs,
        });

        if (error) {
          logger.warn(`[Surveillance24x7] monitoring_events insert failed (${row.featureKey}): ${error.message}`);
        }
      }
    }
  }
}

export const surveillance24x7Service = new Surveillance24x7Service();
