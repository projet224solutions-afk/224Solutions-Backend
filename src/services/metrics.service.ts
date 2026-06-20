/**
 * 📊 METRICS SERVICE - Phase 6
 *
 * Lightweight metrics collection for observability.
 * Records to system_metrics table + in-memory for health endpoints.
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

// In-memory counters (lightweight, no persistence needed)
const counters = new Map<string, number>();
const histograms = new Map<string, number[]>();

export const metrics = {
  /** Increment a counter */
  increment(name: string, value: number = 1, labels?: Record<string, string>): void {
    const key = labels ? `${name}:${JSON.stringify(labels)}` : name;
    counters.set(key, (counters.get(key) || 0) + value);
  },

  /** Record a duration/value for histogram */
  observe(name: string, value: number): void {
    const arr = histograms.get(name) || [];
    arr.push(value);
    if (arr.length > 1000) arr.splice(0, arr.length - 1000); // Keep last 1000
    histograms.set(name, arr);
  },

  /** Get current snapshot for health endpoint */
  getSnapshot(): Record<string, any> {
    const snapshot: Record<string, any> = { counters: {}, histograms: {} };

    for (const [key, val] of counters) {
      snapshot.counters[key] = val;
    }

    for (const [key, vals] of histograms) {
      const sorted = [...vals].sort((a, b) => a - b);
      snapshot.histograms[key] = {
        count: vals.length,
        avg: vals.length ? vals.reduce((s, v) => s + v, 0) / vals.length : 0,
        p50: sorted[Math.floor(sorted.length * 0.5)] || 0,
        p95: sorted[Math.floor(sorted.length * 0.95)] || 0,
        p99: sorted[Math.floor(sorted.length * 0.99)] || 0,
        max: sorted[sorted.length - 1] || 0,
      };
    }

    return snapshot;
  },

  /** Flush current counters to DB (call periodically) */
  async flushToDB(): Promise<void> {
    const rows = [];
    for (const [key, val] of counters) {
      const parts = key.split(':');
      const name = parts[0];
      const labels = parts.length > 1 ? JSON.parse(parts.slice(1).join(':')) : {};
      rows.push({ metric_name: name, metric_value: val, labels });
    }

    if (rows.length === 0) return;

    try {
      await supabaseAdmin.from('system_metrics').insert(rows);
      counters.clear();
    } catch (err: any) {
      logger.warn(`Metrics flush failed: ${err.message}`);
    }
  },
};

// Auto-flush every 5 minutes
setInterval(() => metrics.flushToDB(), 5 * 60 * 1000);

export default metrics;
