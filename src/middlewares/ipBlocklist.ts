/**
 * APPLICATION DU BLOCAGE D'IP - la riposte reelle.
 *
 * Avant : bloquer une IP l'ecrivait dans `blocked_ips` mais RIEN ne l'appliquait,
 * donc l'IP bloquee continuait d'acceder a tout. Ce middleware comble ce trou :
 *   1. ipBlocklist    : rejette (403) toute requete d'une IP presente dans blocked_ips
 *                       (active = non expiree). Cache memoire rafraichi periodiquement
 *                       pour ne pas taper la DB a chaque requete.
 *   2. autoBlockGuard : detecte des indicateurs d'attaque non ambigus (path traversal,
 *                       null byte, requete demesuree) et AUTO-BLOQUE l'IP (insert
 *                       blocked_ips temporaire) puis renvoie 403 -> riposte automatique.
 *
 * Securite : fail-open en cas d'erreur DB (on ne bloque jamais le trafic legitime a
 * cause d'une panne), IPs locales/privees jamais auto-bloquees, blocage auto temporaire.
 */

import type { Request, Response, NextFunction } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { reportAbuse } from '../services/abuseReport.service.js';

const REFRESH_MS = 30000;       // rafraichissement du cache des IPs bloquees
const AUTO_BLOCK_MINUTES = 60;  // duree d'un blocage automatique (temporaire)
const TARPIT_MS = 2000;         // delai inflige aux IPs bloquees (ruine les scans)

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

let blockedSet = new Set<string>();
let lastRefresh = 0;
let refreshing = false;

/** Normalise une IP : retire le prefixe IPv6-mapped et l'eventuel masque CIDR. */
function normalizeIp(ip: string): string {
  let v = String(ip || '').trim().toLowerCase();
  if (v.startsWith('::ffff:')) v = v.slice(7);
  const slash = v.indexOf('/');
  if (slash !== -1) v = v.slice(0, slash);
  return v;
}

/** Vraie IP cliente : 1er saut de X-Forwarded-For (derriere proxy), sinon req.ip. */
export function getClientIp(req: Request): string {
  const xff = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  return normalizeIp(xff || req.ip || '');
}

const LOCAL_OR_PRIVATE = [
  /^127\./, /^::1$/, /^10\./, /^192\.168\./,
  /^172\.(1[6-9]|2\d|3[01])\./, /^169\.254\./, /^fc00:/, /^fe80:/,
];
function isLocalOrPrivate(ip: string): boolean {
  return !ip || LOCAL_OR_PRIVATE.some((re) => re.test(ip));
}

/** Recharge le cache des IPs bloquees actives depuis la base. */
export async function refreshBlocklist(): Promise<void> {
  if (refreshing) return;
  refreshing = true;
  try {
    const { data, error } = await supabaseAdmin.from('blocked_ips').select('*');
    if (error) throw error;
    const next = new Set<string>();
    const now = Date.now();
    for (const row of data || []) {
      const r = row as any;
      const active = r.is_active !== false;
      const notExpired = !r.expires_at || new Date(r.expires_at).getTime() > now;
      if (active && notExpired && r.ip_address) next.add(normalizeIp(String(r.ip_address)));
    }
    blockedSet = next;
    lastRefresh = Date.now();
  } catch (e) {
    logger.warn('[ipBlocklist] echec rafraichissement liste', e as any);
    lastRefresh = Date.now();
  } finally {
    refreshing = false;
  }
}

/** Middleware 1 : rejette les IPs bloquees (403), avec tarpitting (delai). */
export async function ipBlocklist(req: Request, res: Response, next: NextFunction): Promise<void> {
  if (Date.now() - lastRefresh > REFRESH_MS) {
    void refreshBlocklist();
  }
  const ip = getClientIp(req);
  if (ip && blockedSet.has(ip)) {
    logger.warn(`[ipBlocklist] 403 (tarpit) - IP bloquee: ${ip} ${req.method} ${req.path}`);
    // Tarpitting : on ralentit la reponse pour ruiner le rythme des scans automatises.
    await sleep(TARPIT_MS);
    if (!res.headersSent && !res.writableEnded) {
      res.status(403).json({ success: false, error: 'Acces refuse.' });
    }
    return;
  }
  next();
}

/**
 * Enregistre un blocage automatique + cache memoire immediat.
 * Utilise le MEME RPC que l'UI (`block_ip_address`) pour respecter le schema reel
 * de la table (colonnes/triggers internes), au lieu d'un insert direct fragile.
 */
async function autoBlock(ip: string, reason: string): Promise<void> {
  blockedSet.add(ip); // effet immediat, sans attendre la DB
  try {
    // Escalade : si cette IP a deja ete bloquee auparavant (recidive), on passe en
    // ban PERMANENT (expires_at = null) au lieu d'un blocage temporaire.
    let priorBlocks = 0;
    try {
      const { count } = await supabaseAdmin
        .from('blocked_ips')
        .select('id', { count: 'exact', head: true })
        .eq('ip_address', ip);
      priorBlocks = count || 0;
    } catch { /* si le comptage echoue, on reste en temporaire */ }

    const isRepeat = priorBlocks >= 1;
    const expires_at = isRepeat ? null : new Date(Date.now() + AUTO_BLOCK_MINUTES * 60000).toISOString();
    const fullReason = (isRepeat ? `RECIDIVE -> ban permanent. ${reason}` : reason).slice(0, 200);

    // upsert (ip_address est UNIQUE) -> met a jour la ligne existante en cas de recidive,
    // au lieu d'echouer sur doublon. blocked_by est une colonne UUID -> laisse null.
    const { error } = await supabaseAdmin.from('blocked_ips').upsert({
      ip_address: ip,
      reason: fullReason,
      is_active: true,
      expires_at,
    }, { onConflict: 'ip_address' });
    if (error) throw error;
    logger.error(`[autoBlockGuard] IP ${isRepeat ? 'BANNIE DEFINITIVEMENT (recidive)' : 'auto-bloquee 1h'} ${ip} - ${reason}`);

    // Recidive confirmee -> preparer un signalement abuse (RDAP + alerte PDG a valider).
    if (isRepeat) void reportAbuse(ip, fullReason);
  } catch (e) {
    logger.warn('[autoBlockGuard] echec enregistrement blocage', e as any);
  }
}

/** Middleware 2 : auto-blocage sur indicateurs d'attaque non ambigus -> 403. */
export function autoBlockGuard(req: Request, res: Response, next: NextFunction): void {
  const ip = getClientIp(req);
  if (isLocalOrPrivate(ip)) return next();

  const path = req.path || '';
  const rawUrl = req.originalUrl || req.url || '';
  const ua = String(req.headers['user-agent'] || '');
  const queryKeys = Object.keys(req.query || {}).length;
  const decoded = decodeURIComponentSafe(rawUrl);

  const indicators = [
    path.includes('..') || rawUrl.includes('../') || rawUrl.includes('..%2f'),
    rawUrl.includes('%00'),
    /\/etc\/passwd|\/proc\/self|win\.ini/i.test(decoded),
    /\bunion\b\s+\bselect\b|\bselect\b.+\bfrom\b.+\binformation_schema\b/i.test(decoded),
    rawUrl.length > 8000,
    queryKeys > 100,
    /sqlmap|nikto|nmap|masscan|acunetix|nessus/i.test(ua),
  ];
  const hits = indicators.filter(Boolean).length;

  if (hits >= 1) {
    const reason = `Activite d'attaque detectee (${hits} indicateur) - ${req.method} ${path}`.slice(0, 200);
    void autoBlock(ip, reason);
    logger.error(`[autoBlockGuard] 403 + blocage ${ip} - ${reason}`);
    res.status(403).json({ success: false, error: 'Acces refuse.' });
    return;
  }
  next();
}

function decodeURIComponentSafe(s: string): string {
  try { return decodeURIComponent(s); } catch { return s; }
}
