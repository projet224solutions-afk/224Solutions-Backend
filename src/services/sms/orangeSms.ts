/**
 * 🟠 PROVIDER ORANGE SMS — multi-pays, piloté par variables d'environnement.
 *
 * FAITS ORANGE (respectés) :
 *  - UN SEUL couple d'identifiants pour TOUTE l'application (ORANGE_CLIENT_ID /
 *    ORANGE_CLIENT_SECRET), quels que soient les pays souscrits.
 *  - Token OAuth v3 (https://api.orange.com/oauth/v3/token) valide 1 h → CACHÉ
 *    (mémoire + Redis) et renouvelé auto ; jamais un token par SMS.
 *  - Envoi : https://api.orange.com/smsmessaging/v1 — admin/solde : /sms/admin/v1.
 *  - Débit ≤ 5 SMS/seconde → file d'attente centralisée PAR PAYS (RateLimitedQueue).
 *  - PROPRE À CHAQUE PAYS (jamais global) : sender address (`tel:+224…`), sender
 *    name, solde/bundle, activation. Lu dynamiquement via ORANGE_SMS_{ISO}_*.
 *
 * Ajouter un pays = remplir 3 lignes de .env + redémarrer. AUCUN code à modifier.
 * Les secrets (client id/secret, token) ne sont JAMAIS journalisés.
 */
import { env } from '../../config/env.js';
import { logger } from '../../config/logger.js';
import { cache } from '../../config/redis.js';
import { isoFromE164, formatPhoneIntl } from '../phoneFormat.js';
import { RateLimitedQueue } from './rateLimitedQueue.js';

const OAUTH_URL = 'https://api.orange.com/oauth/v3/token';
const SMS_BASE = 'https://api.orange.com/smsmessaging/v1';
const ADMIN_BASE = 'https://api.orange.com/sms/admin/v1';
const TOKEN_CACHE_KEY = 'orange:oauth_token';
const MAX_TPS = 5;

/** Résultat d'un envoi provider. `skipped` = ce pays n'est pas géré par Orange → passer au suivant. */
export interface OrangeSendResult {
  ok: boolean;
  error?: string;
  code?: string;
  skipped?: boolean;
}

/** Config d'un pays lue depuis ORANGE_SMS_{ISO}_*. */
interface CountryConfig {
  iso: string;
  enabled: boolean;
  senderAddress: string; // tel:+224XXXXXXXXX
  senderName: string;
}

// Permet aux tests d'injecter un fetch simulé sans toucher au global.
type FetchLike = typeof fetch;
let fetchImpl: FetchLike = ((...args: Parameters<FetchLike>) => fetch(...args)) as FetchLike;
export function __setOrangeFetch(f: FetchLike | null): void {
  fetchImpl = f ?? (((...args: Parameters<FetchLike>) => fetch(...args)) as FetchLike);
}

// Token en mémoire (partagé process) + verrou d'inflight pour ne PAS lancer deux
// demandes de token en parallèle (2 SMS quasi simultanés = 1 seul appel token).
let memToken: { token: string; expiresAt: number } | null = null;
let tokenInflight: Promise<string> | null = null;

// Une file 5 TPS PAR PAYS (le débit Orange est par contrat pays).
const queues = new Map<string, RateLimitedQueue>();
function queueFor(iso: string): RateLimitedQueue {
  let q = queues.get(iso);
  if (!q) { q = new RateLimitedQueue(MAX_TPS); queues.set(iso, q); }
  return q;
}

/** RÀZ complet (tests uniquement). */
export function __resetOrangeState(): void {
  memToken = null; tokenInflight = null; queues.clear();
}

/** Lit la config d'un pays depuis l'environnement (ORANGE_SMS_{ISO}_*). */
export function countryConfig(iso: string): CountryConfig | null {
  const up = String(iso || '').trim().toUpperCase();
  if (!/^[A-Z]{2}$/.test(up)) return null;
  const prefix = `ORANGE_SMS_${up}_`;
  const enabled = process.env[`${prefix}ENABLED`] === 'true';
  const senderAddress = (process.env[`${prefix}SENDER_ADDRESS`] || '').trim();
  const senderName = (process.env[`${prefix}SENDER_NAME`] || '').trim();
  return { iso: up, enabled, senderAddress, senderName };
}

/**
 * En-tête Authorization pour l'OAuth Orange. Deux façons équivalentes de le fournir :
 *  - ORANGE_AUTHORIZATION = l'en-tête prêt de MyApps (« Basic <base64> »), collé tel quel
 *    (le préfixe « Basic » est ajouté s'il manque). PRIME s'il est présent.
 *  - sinon ORANGE_CLIENT_ID + ORANGE_CLIENT_SECRET → l'en-tête est calculé.
 */
function orangeAuthHeader(): string {
  const raw = (env.ORANGE_AUTHORIZATION || '').trim();
  if (raw) return /^basic\s/i.test(raw) ? raw : `Basic ${raw}`;
  return 'Basic ' + Buffer.from(`${env.ORANGE_CLIENT_ID}:${env.ORANGE_CLIENT_SECRET}`).toString('base64');
}

/** Orange est-il globalement activé ET correctement doté d'identifiants ? */
export function orangeGloballyReady(): boolean {
  return env.ORANGE_SMS_ENABLED
    && Boolean((env.ORANGE_CLIENT_ID && env.ORANGE_CLIENT_SECRET) || env.ORANGE_AUTHORIZATION);
}

/** Liste des pays configurés ET activés (pour le job solde + l'écran PDG). */
export function orangeEnabledCountries(): CountryConfig[] {
  const out: CountryConfig[] = [];
  for (const key of Object.keys(process.env)) {
    const m = key.match(/^ORANGE_SMS_([A-Z]{2})_ENABLED$/);
    if (m && process.env[key] === 'true') {
      const cfg = countryConfig(m[1]);
      if (cfg) out.push(cfg);
    }
  }
  return out;
}

/**
 * Récupère un token OAuth valide (cache mémoire → Redis → nouvel appel).
 * TTL = expires_in − 60 s de marge. Ne journalise jamais le token.
 */
async function getToken(): Promise<string> {
  const now = Date.now();
  if (memToken && memToken.expiresAt > now + 5000) return memToken.token;

  // Redis partagé entre instances (best-effort).
  const cached = await cache.get<{ token: string; expiresAt: number }>(TOKEN_CACHE_KEY);
  if (cached && cached.expiresAt > now + 5000) {
    memToken = cached;
    return cached.token;
  }

  // Un seul appel token concurrent.
  if (tokenInflight) return tokenInflight;
  tokenInflight = (async () => {
    const res = await fetchImpl(OAUTH_URL, {
      method: 'POST',
      headers: {
        Authorization: orangeAuthHeader(),
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: 'application/json',
      },
      body: 'grant_type=client_credentials',
    });
    if (!res.ok) {
      let detail = `${res.status}`;
      try { const j: any = await res.json(); detail = j?.error_description || j?.error || detail; } catch { /* ignore */ }
      throw new Error(`OAuth Orange refusé (${detail})`);
    }
    const j: any = await res.json();
    const token = j?.access_token as string;
    const expiresIn = Number(j?.expires_in) || 3600;
    if (!token) throw new Error('OAuth Orange : access_token absent');
    const expiresAt = Date.now() + Math.max(60, expiresIn - 60) * 1000;
    memToken = { token, expiresAt };
    await cache.set(TOKEN_CACHE_KEY, memToken, Math.max(60, expiresIn - 60));
    logger.info(`[SMS/Orange] token OAuth renouvelé (ttl≈${expiresIn}s)`); // aucune valeur de secret
    return token;
  })();
  try { return await tokenInflight; }
  finally { tokenInflight = null; }
}

/** POST d'un SMS via l'API Orange (déjà dans la file 5 TPS). Le token est passé en argument. */
async function postSms(cfg: CountryConfig, toFormatted: string, message: string, token: string): Promise<OrangeSendResult> {
  const sender = cfg.senderAddress;
  const url = `${SMS_BASE}/outbound/${encodeURIComponent(sender)}/requests`;
  const body: any = {
    outboundSMSMessageRequest: {
      address: `tel:${toFormatted}`,
      senderAddress: sender,
      outboundSMSTextMessage: { message },
    },
  };
  if (cfg.senderName) body.outboundSMSMessageRequest.senderName = cfg.senderName;

  const res = await fetchImpl(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    let detail = `${res.status}`;
    try { const j: any = await res.json(); detail = j?.requestError?.serviceException?.text || j?.requestError?.policyException?.text || j?.message || detail; } catch { /* ignore */ }
    return { ok: false, error: `Orange ${cfg.iso}: ${detail}`, code: 'ORANGE_SEND_FAILED' };
  }
  return { ok: true };
}

/**
 * Envoie un SMS via Orange pour le pays du destinataire.
 * - Orange globalement désactivé → skipped (passer au fournisseur suivant).
 * - Pays inconnu / non configuré / désactivé / sender absent → REFUS propre
 *   ORANGE_COUNTRY_NOT_CONFIGURED (la passerelle bascule).
 * - Sinon : token caché + envoi dans la file 5 TPS du pays.
 * @param to  numéro (brut ou E.164) ; @param countryCode ISO-2 optionnel (sinon déduit du numéro).
 */
export async function orangeSend(to: string, message: string, countryCode?: string): Promise<OrangeSendResult> {
  if (!orangeGloballyReady()) return { ok: false, skipped: true, code: 'ORANGE_DISABLED' };

  const formatted = formatPhoneIntl(to, countryCode);
  const iso = (countryCode && /^[A-Z]{2}$/i.test(countryCode)) ? countryCode.toUpperCase() : isoFromE164(formatted);
  if (!iso) return { ok: false, code: 'ORANGE_COUNTRY_NOT_CONFIGURED', error: 'Indicatif destinataire non reconnu' };

  const cfg = countryConfig(iso);
  if (!cfg || !cfg.enabled || !cfg.senderAddress) {
    return { ok: false, code: 'ORANGE_COUNTRY_NOT_CONFIGURED', error: `Orange non configuré pour ${iso}` };
  }

  // Solde épuisé connu (mis à jour par le job) → refus → bascule (le crédit à zéro
  // ne doit JAMAIS bloquer une inscription).
  const bal = await cache.get<number>(`orange:balance:${iso}`);
  if (bal !== null && bal !== undefined && bal <= 0) {
    return { ok: false, code: 'ORANGE_BALANCE_DEPLETED', error: `Solde Orange ${iso} épuisé` };
  }

  try {
    const token = await getToken();
    return await queueFor(iso).push(() => postSms(cfg, formatted, message, token));
  } catch (err: any) {
    return { ok: false, code: 'ORANGE_SEND_FAILED', error: err?.message || 'Erreur Orange' };
  }
}

/** Solde d'un pays activé via /sms/admin/v1/contracts. { units, expiresAt } ou null si indisponible. */
export async function orangeBalance(iso: string): Promise<{ units: number; expiresAt: string | null } | null> {
  if (!orangeGloballyReady()) return null;
  try {
    const token = await getToken();
    const res = await fetchImpl(`${ADMIN_BASE}/contracts`, {
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
    });
    if (!res.ok) return null;
    const j: any = await res.json();
    // Réponse Orange = liste de contrats/offres ; on somme les unités du pays (indicatif).
    const cfg = countryConfig(iso);
    const dial = (cfg?.senderAddress.match(/\+(\d{1,4})/) || [])[1] || '';
    const list: any[] = Array.isArray(j) ? j : (j?.contracts || j?.partnerContracts || []);
    let units = 0; let expiresAt: string | null = null;
    for (const item of list) {
      const country = String(item?.country || item?.countryName || '').toLowerCase();
      const offerName = String(item?.offerName || item?.serviceName || '').toLowerCase();
      const matchesDial = dial && (country.includes(dial) || offerName.includes(dial));
      // Si l'API ne discrimine pas par pays, on prend l'agrégat (mieux que rien) ;
      // sinon on ne compte que les lignes du pays.
      if (!dial || matchesDial || list.length === 1) {
        units += Number(item?.availableUnits ?? item?.balance ?? 0) || 0;
        expiresAt = item?.expirationDate || item?.expires || expiresAt;
      }
    }
    return { units, expiresAt };
  } catch {
    return null;
  }
}
