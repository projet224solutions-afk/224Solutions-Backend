import { env } from '../config/env.js';
import { logger } from '../config/logger.js';
import { checkSupabaseConnection, supabaseAdmin } from '../config/supabase.js';
import { redisHealthCheck, locks, isRedisConnected } from '../config/redis.js';
import { emitCoreFeatureEvent, type FeatureHealthStatus } from './coreFeatureEvents.service.js';
import { runPlatformMonitors } from './escrowMonitor.service.js';
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
      const includeFrontendScan = this.cycleCount === 1 || this.cycleCount % this.frontendScanEveryN === 0;
      try {
        await runPlatformMonitors({ skipFnDomains: !includeFrontendScan });
      } catch (e: any) {
        logger.warn(`[Surveillance24x7] platform monitor failed: ${e?.message || e}`);
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

      return summary;
    } catch (error: any) {
      logger.error(`[Surveillance24x7] Cycle failed: ${error?.message || 'unknown'}`);
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
