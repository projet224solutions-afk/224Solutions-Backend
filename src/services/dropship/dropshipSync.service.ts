/**
 * ⏱️ PLANIFICATEUR — sync prix/stock dropshipping (Phase 4)
 * ---------------------------------------------------------------------------
 * Tourne UNIQUEMENT sur le worker (RUN_BACKGROUND_JOBS=true), comme la surveillance.
 * Verrou Redis distribué → un seul conteneur exécute le cycle par fenêtre (pas de
 * doublon en multi-instance). Intervalle par défaut : 30 min.
 */

import { logger } from '../../config/logger.js';
import { locks, isRedisConnected } from '../../config/redis.js';
import { syncAllDropshipProducts } from './syncService.js';
import { syncAllTracking } from './trackingService.js';

class DropshipSyncScheduler {
  private interval: ReturnType<typeof setInterval> | null = null;
  private isRunning = false;
  private readonly intervalMs: number;

  constructor() {
    this.intervalMs = Number(process.env.DROPSHIP_SYNC_INTERVAL_MS || 30 * 60_000);
  }

  start(): void {
    if (this.interval) return;
    logger.info(`[DropshipSync] démarrage (toutes les ${this.intervalMs}ms)`);
    void this.tick('startup');
    this.interval = setInterval(() => void this.tick('interval'), this.intervalMs);
  }

  stop(): void {
    if (!this.interval) return;
    clearInterval(this.interval);
    this.interval = null;
    logger.info('[DropshipSync] arrêté');
  }

  private async tick(trigger: string): Promise<void> {
    const ttl = Math.max(30, Math.floor(this.intervalMs / 1000) - 5);
    if (isRedisConnected()) {
      const got = await locks.acquire('dropship:sync:tick', ttl);
      if (!got) return; // autre instance détient la fenêtre
    }
    await this.runOnce(trigger);
  }

  async runOnce(trigger = 'manual'): Promise<void> {
    if (this.isRunning) { logger.info('[DropshipSync] cycle précédent encore en cours, skip'); return; }
    this.isRunning = true;
    try {
      const s = await syncAllDropshipProducts();
      const t = await syncAllTracking();
      logger.info(`[DropshipSync] cycle ${trigger} ok: produits=${JSON.stringify(s)} tracking=${JSON.stringify(t)}`);
    } catch (e: any) {
      logger.error(`[DropshipSync] cycle échoué: ${e?.message}`);
    } finally {
      this.isRunning = false;
    }
  }
}

export const dropshipSyncScheduler = new DropshipSyncScheduler();
