/**
 * 📖 Chargement du MANIFESTE versionné (feature-manifest/*.json) → base, au boot du leader.
 * Les fichiers sont la VÉRITÉ (gardés par la CI) ; la base n'en est que le reflet exploitable.
 * Sert aussi de source au tag `feature_key` des erreurs temps réel (§8.3).
 */
import { readdirSync, readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { logger } from '../config/logger.js';

export interface ManifestFeature {
  feature_key: string; interface: string; label: string; criticality?: string;
  routes?: string[]; rpcs?: string[]; tables?: string[]; externals?: string[];
  invariants?: Array<{ key: string; rule: string }>; depends_on?: string[]; sources?: string[];
}
export interface ManifestProbe {
  probe_key: string; feature_key: string; probe_kind: string;
  label: string; criticality?: string; config?: Record<string, unknown>;
}

const HERE = dirname(fileURLToPath(import.meta.url));
// dist/services → ../../feature-manifest ; src/services (tsx) → ../../feature-manifest
const MANIFEST_DIR = join(HERE, '..', '..', 'feature-manifest');

let cache: { features: ManifestFeature[]; probes: ManifestProbe[] } | null = null;

export function readManifest(): { features: ManifestFeature[]; probes: ManifestProbe[] } {
  if (cache) return cache;
  const features: ManifestFeature[] = [];
  const probes: ManifestProbe[] = [];
  try {
    for (const f of readdirSync(MANIFEST_DIR).filter((n) => n.endsWith('.json'))) {
      const raw = JSON.parse(readFileSync(join(MANIFEST_DIR, f), 'utf8'));
      if (Array.isArray(raw.features)) features.push(...raw.features);
      if (Array.isArray(raw.probes)) probes.push(...raw.probes);
    }
  } catch (e: any) {
    logger.warn(`[Manifest] lecture impossible (${MANIFEST_DIR}): ${e?.message || e}`);
  }
  cache = { features, probes };
  return cache;
}

/**
 * Route Express (méthode + chemin monté) → feature_key du manifeste.
 * Correspondance par PRÉFIXE de chemin, la plus spécifique gagne (les paramètres :id sont
 * neutralisés). Renvoie null si la route n'est mémorisée par aucune fonctionnalité — c'est
 * précisément ce que le filet d'exécution (§8.6.3) doit faire remonter.
 */
export function featureKeyForRoute(method: string, path: string): string | null {
  const { features } = readManifest();
  const norm = (s: string) => s.replace(/:[^/]+/g, '*').replace(/\/+$/, '').toLowerCase();
  const target = `${method.toUpperCase()} ${norm(path)}`;
  let best: { key: string; len: number } | null = null;
  for (const f of features) {
    for (const r of f.routes || []) {
      const [m, p] = r.split(/\s+/);
      if (!m || !p) continue;
      if (m.toUpperCase() !== method.toUpperCase()) continue;
      const pref = norm(p).split('*')[0];
      if (target.startsWith(`${m.toUpperCase()} ${pref}`) && (!best || pref.length > best.len)) {
        best = { key: f.feature_key, len: pref.length };
      }
    }
  }
  return best?.key || null;
}
