/**
 * 🧪 RateLimitedQueue — prouve le plafond 5 SMS/seconde (Orange).
 * Faux timers → déterministe, sans attente réelle.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { RateLimitedQueue } from './rateLimitedQueue.js';

describe('RateLimitedQueue — débit 5 TPS', () => {
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(() => { vi.useRealTimers(); });

  it('espace les tâches d\'au moins 200 ms (5 par seconde)', () => {
    const q = new RateLimitedQueue(5);
    expect(q.spacingMs).toBe(200);
  });

  it('20 envois → étalés à 5 TPS (aucune rafale), tous exécutés dans l\'ordre', async () => {
    const q = new RateLimitedQueue(5);
    const started: number[] = [];
    const t0 = Date.now();
    const results: Promise<number>[] = [];
    for (let i = 0; i < 20; i++) {
      results.push(q.push(async () => { started.push(Date.now() - t0); return i; }));
    }

    // À t=0 : une seule tâche a démarré (pas de rafale).
    await Promise.resolve();
    expect(started.length).toBe(1);

    // Avance de 1 s → 5 tâches supplémentaires max (créneaux 200/400/600/800/1000).
    await vi.advanceTimersByTimeAsync(1000);
    expect(started.length).toBe(6); // t=0 + 5 dans la 1re seconde

    // Fin : les 20 sont exécutées, dans l'ordre, espacées d'exactement 200 ms.
    await vi.advanceTimersByTimeAsync(4000);
    const all = await Promise.all(results);
    expect(all).toEqual(Array.from({ length: 20 }, (_, i) => i));
    for (let i = 1; i < started.length; i++) {
      expect(started[i] - started[i - 1]).toBeGreaterThanOrEqual(200);
    }
    // 20 tâches à 5/s → la dernière démarre à ~3,8 s (jamais toutes d'un coup).
    expect(started[19]).toBe(3800);
  });
});
