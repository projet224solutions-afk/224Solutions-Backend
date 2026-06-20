/**
 * 🛡️ SURVEILLANCE SÉCURITÉ FRONTEND
 *
 * Scanne le frontend RÉELLEMENT PUBLIÉ (ce que voit un attaquant) à chaque cycle de
 * surveillance 24/7 + à la demande. 4 familles de contrôles :
 *   1. Secrets exposés dans le bundle JS (clés privées, service_role, sk_live, AWS, GitHub…),
 *      en ignorant les valeurs PUBLIQUES légitimes (anon key, clé publishable, config Firebase).
 *   2. Posture : en-têtes de sécurité manquants (CSP, HSTS, X-Frame-Options…).
 *   3. Source maps .map accessibles en prod (fuite du code source).
 *   4. Clés fournisseur publiques détectées (Google/Mapbox) → rappel : à restreindre côté provider.
 *
 * Renvoie { generated_at, checks } au format standard → branché dans MONITOR_DOMAINS
 * (domaine « frontend_security »), donc visible dans le panneau PDG Surveillance Plateforme.
 */

import type { MonitorCheck } from './escrowMonitor.service.js';
import { logger } from '../config/logger.js';

const FRONTEND_URL = (process.env.FRONTEND_PUBLIC_URL || 'https://224solution.net').replace(/\/+$/, '');
const MAX_BUNDLES = 20;
const MAX_BYTES = 6 * 1024 * 1024; // 6 Mo par fichier scanné

// Motifs DANGEREUX : ne doivent JAMAIS apparaître dans un bundle frontend public.
const DANGEROUS: { key: string; re: RegExp; label: string }[] = [
  { key: 'private_key', re: /-----BEGIN (?:RSA |EC |OPENSSH |PGP |DSA )?PRIVATE KEY-----/, label: 'Clé privée' },
  { key: 'stripe_secret', re: /\b(?:sk|rk)_(?:live|test)_[0-9a-zA-Z]{16,}/, label: 'Clé secrète Stripe' },
  { key: 'aws_access_key', re: /\bAKIA[0-9A-Z]{16}\b/, label: 'Clé d\'accès AWS' },
  { key: 'gcp_service_account', re: /"type"\s*:\s*"service_account"/, label: 'Compte de service GCP (JSON)' },
  { key: 'github_token', re: /\b(?:ghp|gho|ghu|ghs|ghr)_[0-9A-Za-z]{36}\b|\bgithub_pat_[0-9A-Za-z_]{22,}\b/, label: 'Token GitHub' },
  { key: 'slack_token', re: /\bxox[baprs]-[0-9A-Za-z-]{10,}\b/, label: 'Token Slack' },
  { key: 'generic_server_secret', re: /(?:SERVICE_ROLE_KEY|JWT_SECRET|SECRET_ACCESS_KEY|DB_PASSWORD|SUPABASE_SERVICE_ROLE)["'`]?\s*[:=]\s*["'`][^"'`\s]{12,}/, label: 'Secret serveur en dur' },
];

const SECURITY_HEADERS = [
  'content-security-policy',
  'x-frame-options',
  'x-content-type-options',
  'strict-transport-security',
  'referrer-policy',
];

async function fetchText(url: string): Promise<{ ok: boolean; status: number; text: string; headers: Headers } | null> {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 15000);
    const res = await fetch(url, { signal: ctrl.signal, redirect: 'follow' });
    clearTimeout(t);
    const reader = res.body?.getReader();
    let received = 0;
    let text = '';
    const decoder = new TextDecoder();
    if (reader) {
      // Lecture bornée (MAX_BYTES) pour ne pas charger un bundle géant en mémoire.
      // eslint-disable-next-line no-constant-condition
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        received += value.length;
        text += decoder.decode(value, { stream: true });
        if (received > MAX_BYTES) { try { await reader.cancel(); } catch { /* noop */ } break; }
      }
    } else {
      text = await res.text();
    }
    return { ok: res.ok, status: res.status, text, headers: res.headers };
  } catch (e: any) {
    logger.warn(`[FrontendSec] fetch ${url} échoué: ${e?.message || e}`);
    return null;
  }
}

/** JWT à rôle service_role (= clé service Supabase) exposé. role:anon est public et ignoré. */
function countServiceRoleJwt(text: string): number {
  let n = 0;
  const re = /eyJ[A-Za-z0-9_-]{10,}\.(eyJ[A-Za-z0-9_-]{10,})\.[A-Za-z0-9_-]{8,}/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    try {
      const payload = JSON.parse(Buffer.from(m[1], 'base64').toString('utf8'));
      if (payload?.role === 'service_role') n++;
    } catch { /* pas un JWT décodable → ignoré */ }
  }
  return n;
}

function resolveUrl(src: string): string | null {
  try {
    if (/^https?:\/\//i.test(src)) return src;
    if (src.startsWith('//')) return 'https:' + src;
    if (src.startsWith('/')) return FRONTEND_URL + src;
    return FRONTEND_URL + '/' + src;
  } catch { return null; }
}

export async function scanFrontendSecurity(): Promise<{ generated_at: string; checks: MonitorCheck[] }> {
  const generated_at = new Date().toISOString();
  let secretsFound = 0;
  let serviceRoleFound = 0;
  let sourceMapExposed = 0;
  let missingHeaders = 0;
  let providerKeys = 0;
  let scanError = 0;
  const details: string[] = [];

  const home = await fetchText(FRONTEND_URL + '/');
  if (!home) {
    scanError = 1;
    return { generated_at, checks: [buildCheck('frontend_scan_unreachable', 'Frontend injoignable pour le scan sécurité', 'high', 1)] };
  }

  // 1) En-têtes de sécurité manquants
  for (const h of SECURITY_HEADERS) {
    if (!home.headers.get(h)) { missingHeaders++; details.push(`header manquant: ${h}`); }
  }

  // 2) Découverte des bundles JS (scripts + assets)
  const urls = new Set<string>();
  const scriptRe = /<script[^>]+src=["']([^"']+)["']/gi;
  const assetRe = /["'](\/assets\/[^"']+\.js)["']/gi;
  let m: RegExpExecArray | null;
  while ((m = scriptRe.exec(home.text)) !== null) { const u = resolveUrl(m[1]); if (u) urls.add(u); }
  while ((m = assetRe.exec(home.text)) !== null) { const u = resolveUrl(m[1]); if (u) urls.add(u); }
  const bundles = [...urls].filter((u) => u.endsWith('.js')).slice(0, MAX_BUNDLES);

  // 3) Scan de chaque bundle + détection source map exposée
  for (const b of bundles) {
    const r = await fetchText(b);
    if (!r) { scanError++; continue; }
    for (const d of DANGEROUS) {
      if (d.re.test(r.text)) { secretsFound++; details.push(`${d.label} dans ${b.split('/').pop()}`); }
    }
    serviceRoleFound += countServiceRoleJwt(r.text);
    // Clés fournisseur PUBLIQUES (à restreindre, pas un secret) : Google AIza…, Mapbox pk.…
    if (/\bAIza[0-9A-Za-z_-]{35}\b/.test(r.text)) providerKeys++;
    if (/\bpk\.eyJ[0-9A-Za-z._-]{20,}/.test(r.text)) providerKeys++;
    // Source map référencée + réellement accessible ?
    const sm = /\/\/[#@]\s*sourceMappingURL=([^\s'"]+\.map)/.exec(r.text);
    if (sm) {
      const mapUrl = resolveUrl(sm[1].startsWith('http') ? sm[1] : b.replace(/[^/]+$/, sm[1]));
      if (mapUrl) {
        const mr = await fetchText(mapUrl);
        if (mr && mr.ok && mr.text.length > 0) { sourceMapExposed++; details.push(`source map accessible: ${mapUrl.split('/').pop()}`); }
      }
    }
  }

  if (details.length) logger.warn(`[FrontendSec] ${details.slice(0, 10).join(' | ')}`);

  return {
    generated_at,
    checks: [
      buildCheck('frontend_secret_exposed', 'Secret dangereux exposé dans le bundle public', 'critical', secretsFound),
      buildCheck('frontend_service_role_key', 'Clé service_role Supabase exposée (accès total à la base)', 'critical', serviceRoleFound),
      buildCheck('frontend_source_map_exposed', 'Source map .map accessible en prod (fuite du code source)', 'high', sourceMapExposed),
      buildCheck('frontend_missing_headers', 'En-têtes de sécurité HTTP manquants', 'medium', missingHeaders),
      buildCheck('frontend_provider_key', 'Clé fournisseur publique détectée (Google/Mapbox) — à restreindre côté provider', 'low', providerKeys),
      buildCheck('frontend_scan_error', 'Bundles non scannés (erreur réseau)', 'low', scanError),
    ],
  };
}

function buildCheck(key: string, label: string, severity: MonitorCheck['severity'], count: number): MonitorCheck {
  return { key, label, severity, count, observed: count };
}
