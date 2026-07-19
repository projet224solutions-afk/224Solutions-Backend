/**
 * File d'attente à débit limité (token-bucket par espacement) — module PUR, testable
 * avec des faux timers. Garantit qu'au plus `maxPerSecond` tâches démarrent par seconde
 * (Orange SMS = 5 TPS/pays imposé). Les tâches conservent leur ordre d'arrivée (FIFO).
 *
 * Chaque `push()` planifie le démarrage de la tâche à `max(now, prochaine fenêtre libre)`,
 * puis avance la fenêtre de `1000 / maxPerSecond` ms. Aucune tâche n'est rejetée : elles
 * sont simplement étalées dans le temps (jamais de 429 côté Orange).
 */
export class RateLimitedQueue {
  private readonly gapMs: number;
  private nextAt = 0;

  constructor(maxPerSecond: number) {
    if (!Number.isFinite(maxPerSecond) || maxPerSecond <= 0) {
      throw new Error('maxPerSecond doit être > 0');
    }
    this.gapMs = Math.ceil(1000 / maxPerSecond);
  }

  /** Enfile une tâche ; se résout (ou rejette) avec le résultat de la tâche, en respectant le débit. */
  push<T>(task: () => Promise<T>): Promise<T> {
    const now = Date.now();
    const startAt = Math.max(now, this.nextAt);
    // Réserve le créneau AVANT de programmer → deux push() concurrents ne se chevauchent pas.
    this.nextAt = startAt + this.gapMs;
    const delay = startAt - now;

    return new Promise<T>((resolve, reject) => {
      const run = () => { task().then(resolve, reject); };
      if (delay <= 0) run();
      else setTimeout(run, delay);
    });
  }

  /** Espacement minimal entre deux démarrages (ms) — exposé pour les tests/diagnostics. */
  get spacingMs(): number { return this.gapMs; }
}
