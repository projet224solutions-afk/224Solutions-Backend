/**
 * ⚡ §8.3 — LES ERREURS RÉELLES DES UTILISATEURS, en temps réel.
 * Les sondes détectent en minutes ; les utilisateurs, en secondes. Chaque erreur backend est
 * taguée par `feature_key` (déduit de la route via le manifeste) et comptée dans une fenêtre
 * glissante de 5 minutes EN MÉMOIRE (zéro écriture par requête — le chemin d'erreur ne doit
 * jamais coûter une écriture DB). Au-delà du seuil, un incident est ouvert AVANT le prochain
 * passage de sonde. Le trafic est aussi échantillonné pour le filet « route non mémorisée ».
 */
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';

const WINDOW_MS = 5 * 60_000;
const THRESHOLD = Number(process.env.FATOME_ERROR_SPIKE || 10);   // erreurs / 5 min / feature
const FLUSH_MS = 60_000;

interface Bucket { errors: number[]; total: number }

const buckets = new Map<string, Bucket>();
const routeHits = new Map<string, number>();
const lastIncident = new Map<string, number>();
let flushTimer: ReturnType<typeof setInterval> | null = null;

/** Compte une erreur applicative pour une fonctionnalité (appelé par le middleware d'erreurs). */
export function recordFeatureError(featureKey: string | null, route: string): void {
  if (route) routeHits.set(route, (routeHits.get(route) || 0) + 1);
  if (!featureKey) return;
  const b = buckets.get(featureKey) || { errors: [], total: 0 };
  const now = Date.now();
  b.errors = b.errors.filter((t) => now - t < WINDOW_MS);
  b.errors.push(now);
  b.total += 1;
  buckets.set(featureKey, b);
}

/** Compte une requête servie (échantillon léger) — alimente le filet 8.6.3. */
export function recordRouteHit(route: string): void {
  if (route) routeHits.set(route, (routeHits.get(route) || 0) + 1);
}

async function flush(): Promise<void> {
  const now = Date.now();

  // 1) Pics d'erreurs → incident immédiat (dédup 30 min par feature).
  for (const [feature, b] of buckets) {
    b.errors = b.errors.filter((t) => now - t < WINDOW_MS);
    if (b.errors.length < THRESHOLD) continue;
    if (now - (lastIncident.get(feature) || 0) < 30 * 60_000) continue;
    lastIncident.set(feature, now);
    try {
      await supabaseAdmin.rpc('fatome_incident_open' as any, {
        p_feature: feature,
        p_signature: `${feature}|frontend_api|ERROR_SPIKE`,
        p_layer: 'frontend-api',
        p_cause_code: 'ERROR_SPIKE',
        p_cause_label: `Pic d'erreurs réelles : ${b.errors.length} en 5 min (seuil ${THRESHOLD})`,
        p_suspect: null,
        p_impact: 'Utilisateurs impactés en direct sur cette fonctionnalité',
        p_detail: { errors_5min: b.errors.length, total_since_boot: b.total },
        p_severity: 'high',
      });
      logger.warn(`[FeatureErrorRate] pic d'erreurs sur ${feature}: ${b.errors.length}/5min → incident`);
    } catch (e: any) {
      logger.warn(`[FeatureErrorRate] ouverture incident ${feature}: ${e?.message || e}`);
    }
  }

  // 2) Trafic par route (agrégé) → table de comparaison au manifeste.
  const hits = [...routeHits.entries()];
  routeHits.clear();
  for (const [route, n] of hits) {
    try { await supabaseAdmin.rpc('fatome_route_seen' as any, { p_route: route, p_hits: n }); }
    catch { /* best-effort */ }
  }
}

export function startFeatureErrorRate(): void {
  if (flushTimer) return;
  flushTimer = setInterval(() => { void flush(); }, FLUSH_MS);
  logger.info('[FeatureErrorRate] compteur temps réel actif (fenêtre 5 min)');
}
export function stopFeatureErrorRate(): void {
  if (flushTimer) { clearInterval(flushTimer); flushTimer = null; }
}
