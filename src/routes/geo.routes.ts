/**
 * 🌍 GEO DETECT — /api/geo/detect
 *
 * Détection pays / devise / langue, 100 % sur NOTRE infra (remplace l'Edge Function
 * Supabase `geo-detect` qui renvoyait GN-pour-tous à l'étranger).
 *
 * Chaîne de résolution (chaque niveau ne s'applique que si le précédent échoue) :
 *   a. Base GeoIP LOCALE embarquée (geoip-lite / GeoLite2) → 0 réseau, < 1 ms — mode nominal.
 *   b. Repli intelligent : fuseau horaire envoyé par le client (Africa/Dakar → SN).
 *   c. Défaut GN/GNF/fr, marqué detection_method='default' (jamais présenté comme certain).
 *
 * Durcissements : IP lue CÔTÉ SERVEUR (trust proxy), JAMAIS l'IP complète dans les logs
 * (dernier octet anonymisé) ; cache par préfixe d'IP (TTL 24 h) ; réponse TOUJOURS 200
 * avec un résultat exploitable (une erreur ne doit jamais casser le chargement de l'app).
 * Le mapping pays→devise vit dans la table `countries` (éditable PDG) ; pays→langue embarqué.
 */
import { Router, type Request, type Response } from 'express';
import geoip from 'geoip-lite';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { cache } from '../config/redis.js';
import { ok } from '../utils/apiResponse.js';
import { verifyJWT, type AuthenticatedRequest } from '../middlewares/auth.middleware.js';

const router = Router();

// ── Observabilité (traçabilité PDG) : répartition des méthodes de détection sur une
// fenêtre glissante d'1 h, EN MÉMOIRE (par instance — VPS mono-instance). Alerte
// system_alerts si le taux de repli 'default' dépasse un seuil (GeoIP probablement KO).
const geoStats: Record<'geoip' | 'timezone' | 'default', number> = { geoip: 0, timezone: 0, default: 0 };
let geoStatsSince = 0; // rempli au 1er comptage (Date.now() interdit au niveau module ? non — runtime OK)
let lastFallbackAlertAt = 0;
const FALLBACK_RATE_THRESHOLD = 0.2;   // 20 % de repli 'default'
const FALLBACK_MIN_SAMPLES = 50;       // pas d'alerte sous 50 détections (bruit)

function recordDetection(method: string): void {
  const now = Date.now();
  if (geoStatsSince === 0 || now - geoStatsSince > 3600_000) {
    geoStats.geoip = 0; geoStats.timezone = 0; geoStats.default = 0; geoStatsSince = now;
  }
  if (method === 'geoip' || method === 'timezone' || method === 'default') geoStats[method]++;
}

async function maybeAlertFallback(): Promise<void> {
  const total = geoStats.geoip + geoStats.timezone + geoStats.default;
  if (total < FALLBACK_MIN_SAMPLES) return;
  const rate = geoStats.default / total;
  if (rate < FALLBACK_RATE_THRESHOLD) return;
  if (Date.now() - lastFallbackAlertAt < 3600_000) return; // throttle 1/h par instance
  lastFallbackAlertAt = Date.now();
  try {
    const alertKey = 'geo_fallback_high';
    const { data: existing } = await supabaseAdmin.from('system_alerts')
      .select('id').eq('module', 'geo_detection').eq('status', 'active')
      .filter('metadata->>alert_key', 'eq', alertKey).maybeSingle();
    if (existing) return; // alerte déjà ouverte
    await supabaseAdmin.from('system_alerts').insert({
      title: '[geo_detection] Taux de repli géo élevé',
      message: `${Math.round(rate * 100)}% des détections retombent sur le défaut GN/GNF/fr (${total} détections / 1 h). La géolocalisation IP est probablement défaillante — les visiteurs étrangers voient des prix en GNF.`,
      severity: 'high', module: 'geo_detection', status: 'active',
      suggested_fix: "Vérifier trust proxy + X-Forwarded-For sur le VPS et la fraîcheur de la base geoip-lite (GeoLite2).",
      metadata: { alert_key: alertKey, fallback_rate: Math.round(rate * 100) / 100, samples: total },
    });
    logger.warn(`[geo] alerte repli élevé: ${Math.round(rate * 100)}% sur ${total} détections`);
  } catch (e: any) { logger.warn(`[geo] alerte system_alerts échouée: ${e?.message || e}`); }
}

// Pays → langue par défaut (francophone / anglophone / lusophone / arabe / …).
const COUNTRY_LANG: Record<string, string> = {
  GN: 'fr', SN: 'fr', ML: 'fr', CI: 'fr', BF: 'fr', NE: 'fr', TG: 'fr', BJ: 'fr', MR: 'fr',
  CM: 'fr', CD: 'fr', CG: 'fr', GA: 'fr', TD: 'fr', CF: 'fr', DJ: 'fr', KM: 'fr', MG: 'fr', GQ: 'fr',
  NG: 'en', GH: 'en', KE: 'en', UG: 'en', TZ: 'en', ZA: 'en', ZM: 'en', ZW: 'en', LR: 'en',
  SL: 'en', GM: 'en', BW: 'en', RW: 'en', MW: 'en', NA: 'en',
  GW: 'pt', AO: 'pt', MZ: 'pt', CV: 'pt', ST: 'pt',
  MA: 'ar', DZ: 'ar', TN: 'ar', LY: 'ar', EG: 'ar', SD: 'ar', SA: 'ar', AE: 'ar', QA: 'ar',
  KW: 'ar', BH: 'ar', OM: 'ar', JO: 'ar', LB: 'ar', IQ: 'ar', YE: 'ar', SY: 'ar',
  FR: 'fr', BE: 'fr', LU: 'fr', CH: 'fr', US: 'en', GB: 'en', IE: 'en', CA: 'en', AU: 'en',
  DE: 'de', ES: 'es', PT: 'pt', IT: 'it', NL: 'nl', BR: 'pt', RU: 'ru', TR: 'tr', CN: 'zh',
};

// Repli intelligent : fuseau horaire IANA → pays (quand l'IP n'est pas résolue).
const TZ_COUNTRY: Record<string, string> = {
  'Africa/Conakry': 'GN', 'Africa/Dakar': 'SN', 'Africa/Bamako': 'ML', 'Africa/Abidjan': 'CI',
  'Africa/Ouagadougou': 'BF', 'Africa/Niamey': 'NE', 'Africa/Lome': 'TG', 'Africa/Porto-Novo': 'BJ',
  'Africa/Nouakchott': 'MR', 'Africa/Banjul': 'GM', 'Africa/Bissau': 'GW', 'Africa/Freetown': 'SL',
  'Africa/Monrovia': 'LR', 'Africa/Douala': 'CM', 'Africa/Lagos': 'NG', 'Africa/Accra': 'GH',
  'Africa/Kinshasa': 'CD', 'Africa/Brazzaville': 'CG', 'Africa/Libreville': 'GA', 'Africa/Ndjamena': 'TD',
  'Africa/Bangui': 'CF', 'Africa/Malabo': 'GQ', 'Africa/Luanda': 'AO', 'Africa/Nairobi': 'KE',
  'Africa/Kampala': 'UG', 'Africa/Dar_es_Salaam': 'TZ', 'Africa/Kigali': 'RW', 'Africa/Johannesburg': 'ZA',
  'Africa/Lusaka': 'ZM', 'Africa/Harare': 'ZW', 'Africa/Maputo': 'MZ', 'Africa/Casablanca': 'MA',
  'Africa/Algiers': 'DZ', 'Africa/Tunis': 'TN', 'Africa/Tripoli': 'LY', 'Africa/Cairo': 'EG',
  'Africa/Khartoum': 'SD', 'Europe/Paris': 'FR', 'Europe/Brussels': 'BE', 'Europe/London': 'GB',
  'Europe/Madrid': 'ES', 'Europe/Berlin': 'DE', 'Europe/Lisbon': 'PT', 'Europe/Rome': 'IT',
  'America/New_York': 'US', 'America/Chicago': 'US', 'America/Los_Angeles': 'US', 'America/Toronto': 'CA',
};

const SUPPORTED_LANGS = new Set(['fr', 'en', 'ar', 'pt', 'es', 'de', 'it', 'nl', 'ru', 'tr', 'zh']);

// Mapping pays → devise depuis la table `countries` (source PDG), caché en mémoire 1 h.
let currencyMap: Record<string, string> = {};
let currencyMapAt = 0;
async function countryCurrency(iso: string): Promise<string> {
  const now = Date.now();
  if (now - currencyMapAt > 3600_000) {
    try {
      const { data } = await supabaseAdmin.from('countries').select('country_code, currency_code');
      const m: Record<string, string> = {};
      for (const r of (data as any[]) || []) if (r.country_code && r.currency_code) m[r.country_code] = r.currency_code;
      if (Object.keys(m).length) { currencyMap = m; currencyMapAt = now; }
    } catch { /* on garde l'ancien cache / le défaut */ }
  }
  return currencyMap[iso] || 'GNF';
}

/** Dernier octet IPv4 (ou suffixe IPv6) masqué — jamais l'IP complète dans les logs. */
function anonymizeIp(ip: string): string {
  if (!ip) return '?';
  if (ip.includes('.')) return ip.replace(/\.\d+$/, '.0');
  if (ip.includes(':')) return ip.split(':').slice(0, 3).join(':') + '::';
  return '?';
}
/** Clé de cache par préfixe (agrège les IP proches, limite la cardinalité). */
function ipPrefix(ip: string): string {
  if (ip.includes('.')) return ip.split('.').slice(0, 3).join('.');
  if (ip.includes(':')) return ip.split(':').slice(0, 4).join(':');
  return ip || 'unknown';
}

router.get('/detect', async (req: Request, res: Response) => {
  const tz = typeof req.query.tz === 'string' ? req.query.tz : '';
  const browserLang = (typeof req.query.lang === 'string' ? req.query.lang : '').slice(0, 2).toLowerCase();

  // IP réelle du client (trust proxy activé). On ne renvoie/journalise jamais l'IP entière.
  const rawIp = (req.ip || (req.socket && req.socket.remoteAddress) || '').replace(/^::ffff:/, '');

  try {
    const key = `geo:${ipPrefix(rawIp)}:${tz}:${browserLang}`;
    const cached = await cache.get<any>(key);
    if (cached) { recordDetection(cached.detection_method); return ok(res, cached); }

    let country: string | null = null;
    let method = 'default';
    let confidence = 0;

    // a. GeoIP local (nominal)
    const hit = rawIp ? geoip.lookup(rawIp) : null;
    if (hit?.country && /^[A-Z]{2}$/.test(hit.country)) { country = hit.country; method = 'geoip'; confidence = 0.9; }

    // b. Repli fuseau horaire
    if (!country && tz && TZ_COUNTRY[tz]) { country = TZ_COUNTRY[tz]; method = 'timezone'; confidence = 0.5; }

    // c. Défaut
    if (!country) { country = 'GN'; method = 'default'; confidence = 0; }

    const currency = await countryCurrency(country);
    const language = COUNTRY_LANG[country] || (SUPPORTED_LANGS.has(browserLang) ? browserLang : 'fr');

    const result = {
      country, currency, language,
      timezone: tz || null, detection_method: method, confidence,
    };
    await cache.set(key, result, 24 * 3600);
    recordDetection(method);
    void maybeAlertFallback();
    logger.info(`[geo] ${anonymizeIp(rawIp)} → ${country}/${currency}/${language} (${method})`);
    return ok(res, result);
  } catch (err: any) {
    // Une erreur ne doit JAMAIS casser le chargement de l'app → défaut exploitable, 200.
    logger.warn(`[geo] échec détection (${anonymizeIp(rawIp)}): ${err?.message || err}`);
    return ok(res, {
      country: 'GN', currency: 'GNF', language: 'fr',
      timezone: tz || null, detection_method: 'default', confidence: 0,
    });
  }
});

// ── GET /api/geo/diagnostics : traçabilité PDG (répartition des méthodes + taux de repli) ──
router.get('/diagnostics', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  const { data: prof } = await supabaseAdmin.from('profiles').select('role').eq('id', req.user!.id).maybeSingle();
  if (!['pdg', 'admin', 'ceo'].includes(String((prof as any)?.role || '').toLowerCase())) {
    res.status(403).json({ success: false, error: 'PDG uniquement' });
    return;
  }
  const total = geoStats.geoip + geoStats.timezone + geoStats.default;
  ok(res, {
    window_started_at: geoStatsSince ? new Date(geoStatsSince).toISOString() : null,
    total,
    by_method: { ...geoStats },
    fallback_rate: total ? Math.round((geoStats.default / total) * 1000) / 1000 : 0,
    alert_threshold: FALLBACK_RATE_THRESHOLD,
    note: 'Compteur en mémoire par instance (VPS mono-instance), fenêtre glissante 1 h.',
  });
});

export default router;
