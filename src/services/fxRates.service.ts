/**
 * 🌍 FX RATES SERVICE — Sources officielles multi-niveaux
 *
 * Migré depuis l'Edge Function supabase/functions/african-fx-collect.
 * Collecte les taux de change depuis les banques centrales africaines,
 * applique la marge configurable (depuis margin_config), et stocke dans
 * `currency_exchange_rates` + `fx_collection_log`.
 *
 * === HIÉRARCHIE DES SOURCES (4 niveaux) ===
 *
 * NIVEAU 1 — official_html : Scraping HTML de banques centrales
 *   • BCRG  (bcrg-guinee.org) → GNF  (USD/GNF, EUR/GNF)
 *   • BCEAO (bceao.int)       → XOF  (USD/XOF + GBP/CHF/CAD/JPY/CNY/AED/XOF)
 *
 * NIVEAU 2 — official_fixed_parity : Parités fixes officielles documentées
 *   • XOF, XAF, KMF, CVE, STN, DJF, ERN
 *
 * NIVEAU 3 — official_cross : Taux croisés (NAD, LSL, SZL arrimés ZAR)
 *
 * NIVEAU 4 — fallback_api : open.er-api.com
 *   • Uniquement pour devises sans source officielle HTML
 *   • Jamais pour GNF (règle métier absolue)
 *
 * === RÈGLE BCRG ===
 * GNF NE DOIT JAMAIS utiliser open.er-api.com.
 * Si BCRG est inaccessible → heartbeat : retrieved_at mis à jour mais PAS
 * last_bcrg_scraped_at. Les transactions GNF sont refusées si
 * last_bcrg_scraped_at > 24h (vérifiée dans create_order_core).
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

// ═══════════════════════════════════════════════════════════
// TYPES
// ═══════════════════════════════════════════════════════════

type SourceType = 'official_html' | 'official_fixed_parity' | 'official_cross' | 'fallback_api';

interface CurrencyConfig {
  country: string;
  zone?: string;
  fixedRate?: { base: 'EUR' | 'USD'; rate: number };
  fallbackReason?: string;
  peggedTo?: string;
}

interface CollectedRate {
  rateUsd: number;
  rateEur: number;
  source: string;
  sourceUrl: string;
  sourceType: SourceType;
}

interface BceaoRates {
  usdXof: number;
  gbpXof?: number;
  chfXof?: number;
  cadXof?: number;
  jpyXof?: number;
  cnyXof?: number;
  aedXof?: number;
}

interface BcrgRates {
  usdGnf: number;
  eurGnf?: number;
  cadGnf?: number;
  gbpGnf?: number;
  chfGnf?: number;
  jpyGnf?: number;
  cnyGnf?: number;
  dkkGnf?: number;
  nokGnf?: number;
  sekGnf?: number;
  sarGnf?: number;
  xofGnf?: number;
  dtsGnf?: number;
  ucaGnf?: number;
  scrapedUrl: string;
}

// ═══════════════════════════════════════════════════════════
// CONFIGURATION DES 42 DEVISES AFRICAINES
// ═══════════════════════════════════════════════════════════

const AFRICAN_CURRENCIES: Record<string, CurrencyConfig> = {
  XOF: { country: 'UEMOA', zone: 'BCEAO', fixedRate: { base: 'EUR', rate: 655.957 } },
  XAF: { country: 'CEMAC', zone: 'BEAC', fixedRate: { base: 'EUR', rate: 655.957 } },
  KMF: { country: 'Comores', fixedRate: { base: 'EUR', rate: 491.96775 } },
  CVE: { country: 'Cap-Vert', fixedRate: { base: 'EUR', rate: 110.265 } },
  STN: { country: 'São Tomé-et-Príncipe', fixedRate: { base: 'EUR', rate: 24.5 } },
  DJF: { country: 'Djibouti', fixedRate: { base: 'USD', rate: 177.721 } },
  ERN: { country: 'Érythrée', fixedRate: { base: 'USD', rate: 15.0 } },
  NAD: { country: 'Namibie', peggedTo: 'ZAR' },
  LSL: { country: 'Lesotho', peggedTo: 'ZAR' },
  SZL: { country: 'Eswatini', peggedTo: 'ZAR' },
  GNF: { country: 'Guinée' },
  NGN: { country: 'Nigeria', fallbackReason: 'CBN : api.cbn.gov.ng nécessite accès API spécifique' },
  ZAR: { country: 'Afrique du Sud', fallbackReason: 'SARB : site en JS dynamique' },
  EGP: { country: 'Égypte', fallbackReason: 'CBE : cbe.org.eg en JS dynamique' },
  MAD: { country: 'Maroc', fallbackReason: 'BAM : bkam.ma publie des PDF' },
  TND: { country: 'Tunisie', fallbackReason: 'BCT : bct.gov.tn en JS/Angular' },
  DZD: { country: 'Algérie', fallbackReason: 'BA : bank-of-algeria.dz pas de publication web' },
  KES: { country: 'Kenya', fallbackReason: 'CBK : centralbank.go.ke en JS dynamique' },
  GHS: { country: 'Ghana', fallbackReason: 'BOG : bog.gov.gh nécessite parsing JS' },
  TZS: { country: 'Tanzanie', fallbackReason: 'BOT : bot.go.tz pas de HTML structuré stable' },
  UGX: { country: 'Ouganda', fallbackReason: 'BOU : bou.or.ug nécessite JavaScript' },
  ETB: { country: 'Éthiopie', fallbackReason: 'NBE : nbebank.com en JS dynamique' },
  MZN: { country: 'Mozambique', fallbackReason: 'BM : bancomoc.mz en JS dynamique' },
  AOA: { country: 'Angola', fallbackReason: 'BNA : bna.ao nécessite JS' },
  CDF: { country: 'RD Congo', fallbackReason: 'BCC : bcc.cd site instable' },
  RWF: { country: 'Rwanda', fallbackReason: 'BNR : bnr.rw en JS dynamique' },
  BIF: { country: 'Burundi', fallbackReason: 'BRB : brb.bi pas de publication web' },
  MGA: { country: 'Madagascar', fallbackReason: 'BCM : banque-centrale.mg en JS' },
  MUR: { country: 'Maurice', fallbackReason: 'BOM : bom.mu en JS dynamique' },
  SCR: { country: 'Seychelles', fallbackReason: 'CBS : cbs.sc pas de HTML structuré' },
  GMD: { country: 'Gambie', fallbackReason: 'CBG : cbg.gm pas de tableau HTML' },
  SLL: { country: 'Sierra Leone', fallbackReason: 'BSL : bsl.gov.sl site instable' },
  LRD: { country: 'Liberia', fallbackReason: 'CBL : cbl.org.lr pas de publication web' },
  BWP: { country: 'Botswana', fallbackReason: 'BOB : bankofbotswana.bw en JS' },
  MWK: { country: 'Malawi', fallbackReason: 'RBM : rbm.mw en JS dynamique' },
  ZMW: { country: 'Zambie', fallbackReason: 'BOZ : boz.zm en JS dynamique' },
  SDG: { country: 'Soudan', fallbackReason: 'CBOS : cbos.gov.sd site souvent inaccessible' },
  SSP: { country: 'Soudan du Sud', fallbackReason: 'BOSS : bankofsouthsudan.org site instable' },
  SOS: { country: 'Somalie', fallbackReason: 'CBS : centralbanksomaliaonline.com pas de données' },
  LYD: { country: 'Libye', fallbackReason: 'CBL : cbl.gov.ly pas de tableau HTML' },
  MRU: { country: 'Mauritanie', fallbackReason: 'BCM : bcm.mr pas de publication web automatisable' },
  ZWL: { country: 'Zimbabwe', fallbackReason: 'RBZ : rbz.co.zw nécessite JS' },
};

const VARIATION_THRESHOLD = 0.001; // 0.1 %

const BCRG_PRIMARY_URL = 'https://www.bcrg-guinee.org';

// ── SSE clients connectés — broadcast instantané quand les taux changent ──
type SseWriter = { write: (data: string) => boolean; writableEnded: boolean };
export const bcrgSseClients = new Set<SseWriter>();

// ── Fingerprint HTTP de la homepage BCRG pour le HEAD check ──
let _bcrgFingerprint: { etag: string | null; lastModified: string | null; contentLength: string | null } | null = null;

/**
 * HEAD request légère vers la homepage BCRG.
 * Retourne true si la page a changé depuis le dernier appel (ou si c'est le premier).
 * Permet d'éviter un GET complet quand la page est identique.
 */
export async function checkBcrgHeadChanged(): Promise<boolean> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 6_000);
  try {
    const resp = await fetch(BCRG_PRIMARY_URL, {
      method: 'HEAD',
      headers: { 'User-Agent': '224Solutions-FX-Watcher/2.0', 'Cache-Control': 'no-cache, no-store', Pragma: 'no-cache' },
      signal: controller.signal,
    });
    clearTimeout(timeout);
    if (!resp.ok) return true; // Inaccessible → tenter quand même le GET

    const etag = resp.headers.get('etag');
    const lastModified = resp.headers.get('last-modified');
    const contentLength = resp.headers.get('content-length');

    if (!_bcrgFingerprint) {
      // Premier appel → mémoriser et forcer un GET complet
      _bcrgFingerprint = { etag, lastModified, contentLength };
      return true;
    }

    // Comparer dans l'ordre de fiabilité : ETag > Last-Modified > Content-Length
    if (etag && _bcrgFingerprint.etag !== null) {
      const changed = etag !== _bcrgFingerprint.etag;
      _bcrgFingerprint.etag = etag;
      return changed;
    }
    if (lastModified && _bcrgFingerprint.lastModified !== null) {
      const changed = lastModified !== _bcrgFingerprint.lastModified;
      _bcrgFingerprint.lastModified = lastModified;
      return changed;
    }
    if (contentLength && _bcrgFingerprint.contentLength !== null) {
      const changed = contentLength !== _bcrgFingerprint.contentLength;
      _bcrgFingerprint.contentLength = contentLength;
      return changed;
    }
    // Aucun header fiable → toujours faire le GET complet
    return true;
  } catch {
    clearTimeout(timeout);
    return true; // Sur erreur → tenter le GET complet
  }
}

const GNF_SANITY_RANGES: Record<string, { min: number; max: number }> = {
  USD: { min: 6_500, max: 14_000 },
  EUR: { min: 7_500, max: 16_000 },
  GBP: { min: 8_000, max: 18_000 },
  CHF: { min: 8_000, max: 18_000 },
  CAD: { min: 4_500, max: 12_000 },
  CNY: { min: 800,   max: 2_500 },
  JPY: { min: 30,    max: 200 },
  DKK: { min: 900,   max: 2_500 },
  NOK: { min: 500,   max: 2_000 },
  SEK: { min: 500,   max: 2_000 },
  SAR: { min: 1_500, max: 5_000 },
  XOF: { min: 8,     max: 30 },
  DTS: { min: 8_000, max: 18_000 },
  UCA: { min: 8_000, max: 18_000 },
};

// ═══════════════════════════════════════════════════════════
// NIVEAU 1 — BCEAO
// ═══════════════════════════════════════════════════════════

function parseFrenchNumber(s: string): number {
  return parseFloat(s.replace(/\s/g, '').replace(',', '.'));
}

async function scrapeBceao(): Promise<BceaoRates | null> {
  const url = 'https://www.bceao.int/fr/cours/cours-des-devises';
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15_000);
    let html: string;
    try {
      const resp = await fetch(url, {
        headers: { 'User-Agent': '224Solutions-FX-Collector/2.0', Accept: 'text/html' },
        signal: controller.signal,
      });
      if (!resp.ok) {
        logger.warn(`[BCEAO] HTTP ${resp.status}`);
        await resp.text();
        return null;
      }
      html = await resp.text();
    } finally {
      clearTimeout(timeout);
    }

    const result: BceaoRates = { usdXof: 0 };
    const currencyPatterns: { label: RegExp; key: keyof BceaoRates }[] = [
      { label: /Dollar\s+us/i, key: 'usdXof' },
      { label: /Livre\s+sterling/i, key: 'gbpXof' },
      { label: /Franc\s+suisse/i, key: 'chfXof' },
      { label: /Dollar\s+canadien/i, key: 'cadXof' },
      { label: /Yen\s+japonais/i, key: 'jpyXof' },
      { label: /Yuan\s+chinois/i, key: 'cnyXof' },
      { label: /Dirham\s+Emirats/i, key: 'aedXof' },
    ];

    for (const { label, key } of currencyPatterns) {
      const htmlPattern = new RegExp(
        label.source + `[^<]*<\\/td>\\s*<td[^>]*>\\s*([\\d\\s,.]+)\\s*<\\/td>\\s*<td[^>]*>\\s*([\\d\\s,.]+)`,
        'i',
      );
      let match = html.match(htmlPattern);
      if (!match) {
        const mdPattern = new RegExp(
          label.source + `\\s*\\|\\s*([\\d\\s,.]+)\\s*\\|\\s*([\\d\\s,.]+)`,
          'i',
        );
        match = html.match(mdPattern);
      }
      if (match) {
        const buy = parseFrenchNumber(match[1]);
        if (!isNaN(buy) && buy > 0) {
          (result as any)[key] = buy;
        }
      }
    }

    if (!result.usdXof || result.usdXof <= 0) {
      logger.warn('[BCEAO] Taux USD introuvable dans le HTML');
      return null;
    }

    logger.info(`[BCEAO] Taux scrappés — USD/XOF: ${result.usdXof}` +
      (result.gbpXof ? `, GBP/XOF: ${result.gbpXof}` : '') +
      (result.chfXof ? `, CHF/XOF: ${result.chfXof}` : ''));
    return result;
  } catch (e: any) {
    logger.error(`[BCEAO] Scraping failed: ${e.message}`);
    return null;
  }
}

// ═══════════════════════════════════════════════════════════
// NIVEAU 1 — BCRG
// ═══════════════════════════════════════════════════════════

function normalizeBcrgUrl(rawUrl: string): string {
  try {
    return new URL(rawUrl, BCRG_PRIMARY_URL).toString();
  } catch {
    return rawUrl;
  }
}

function extractBcrgFixingUrls(html: string): string[] {
  const urls: string[] = [];
  const pushUrl = (value: string) => {
    const normalized = normalizeBcrgUrl(value);
    if (!normalized.includes('/cours_des_devises/fixing-du-')) return;
    if (!urls.includes(normalized)) urls.push(normalized);
  };
  for (const match of html.matchAll(/href=["']([^"']*\/cours_des_devises\/fixing-du-[^"']+)["']/gi)) {
    pushUrl(match[1]);
  }
  for (const match of html.matchAll(/https?:\/\/www\.bcrg-guinee\.org\/cours_des_devises\/fixing-du-[^"'\s<]+/gi)) {
    pushUrl(match[0]);
  }
  return urls;
}

function extractBcrgRateFromHtml(html: string, currency: string): number | undefined {
  const code = currency.toUpperCase();
  const labelPattern = code === 'USD' ? '(?:USD|Dollar)' :
                       code === 'EUR' ? '(?:EUR|Euro)' :
                       code;
  // SOURCE OFFICIELLE = le WIDGET « <h2>usd =</h2> … <h2>8725.1731</h2> » de la home BCRG
  // (confirmé par la BCRG : ce sont les taux du jour officiels affichés sur bcrg-guinee.org).
  // ⚠️ La même page contient AUSSI une table TablePress avec d'AUTRES valeurs (comptables/anciennes)
  // qu'il NE FAUT PAS utiliser. On lit donc UNIQUEMENT le widget ; si une devise n'y figure pas
  // (ex. XAF), on renvoie undefined → rien n'est affiché (règle « n'afficher que ce qui existe »).
  const num = '([\\d\\s\\u00a0.,]+)';
  const patterns = [
    // 1) Widget officiel BCRG : <hN>USD =</hN> … <hN>valeur</hN> (la valeur suit ~250c après le label).
    new RegExp(`${labelPattern}\\s*=\\s*<\\/h\\d>[\\s\\S]{0,600}?<h\\d[^>]*>\\s*${num}\\s*<\\/h\\d>`, 'gi'),
    // 2) Forme textuelle alternative « 1 USD = … » / « USD/GNF : … » (si la structure du widget change).
    new RegExp(`(?:1\\s*${currency}\\s*=\\s*|${currency}\\s*\\/\\s*GNF\\s*[:=]\\s*)${num}`, 'gi'),
  ];
  for (const pattern of patterns) {
    const matches = Array.from(html.matchAll(pattern));
    for (let i = matches.length - 1; i >= 0; i--) {
      const rawValue = matches[i]?.[1];
      if (!rawValue) continue;
      const parsed = parseFrenchNumber(rawValue);
      const range = GNF_SANITY_RANGES[code] ?? { min: 0, max: 1_000_000 };
      if (!Number.isNaN(parsed) && parsed >= range.min && parsed <= range.max) {
        return parsed;
      }
    }
  }
  return undefined;
}

async function fetchBcrgHtml(url: string): Promise<string | null> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12_000);
  try {
    const resp = await fetch(url, {
      headers: {
        'User-Agent': '224Solutions-FX-Collector/2.0',
        Accept: 'text/html',
        'Cache-Control': 'no-cache, no-store',
        Pragma: 'no-cache',
      },
      signal: controller.signal,
    });
    if (!resp.ok) {
      logger.warn(`[BCRG] HTTP ${resp.status} for ${url}`);
      await resp.text();
      return null;
    }
    return await resp.text();
  } catch (e: any) {
    if (e.name === 'AbortError') logger.warn(`[BCRG] Timeout pour ${url}`);
    else logger.warn(`[BCRG] Erreur pour ${url}: ${e.message}`);
    return null;
  } finally {
    clearTimeout(timeout);
  }
}

async function scrapeBcrg(): Promise<BcrgRates | null> {
  let homepageHtml: string | null = null;
  try {
    homepageHtml = await fetchBcrgHtml(BCRG_PRIMARY_URL);
  } catch (e: any) {
    logger.warn(`[BCRG] Erreur homepage: ${e.message}`);
  }

  const _d = new Date();
  const _dd = String(_d.getDate()).padStart(2, '0');
  const _mm = String(_d.getMonth() + 1).padStart(2, '0');
  const _yyyy = _d.getFullYear();
  const todayStr = `${_dd}-${_mm}-${_yyyy}`; // Format BCRG : DD-MM-YYYY (ex: 18-05-2026)
  const fixingUrls = homepageHtml ? extractBcrgFixingUrls(homepageHtml) : [];
  const urlsToTry = Array.from(new Set([
    BCRG_PRIMARY_URL, // ← homepage en premier — widget Elementor toujours à jour
    `${BCRG_PRIMARY_URL}/cours_des_devises/fixing-du-${todayStr}`,
    ...fixingUrls,
    `${BCRG_PRIMARY_URL}/cours-de-change`,
    'https://www.bcrg.gov.gn',
    'https://www.bcrg.gov.gn/cours-de-change',
  ]));

  for (const url of urlsToTry) {
    try {
      const html = url === BCRG_PRIMARY_URL && homepageHtml
        ? homepageHtml
        : await fetchBcrgHtml(url);
      if (!html) continue;

      const usdGnf = extractBcrgRateFromHtml(html, 'USD');
      if (!usdGnf) continue;

      const result: BcrgRates = {
        usdGnf,
        eurGnf: extractBcrgRateFromHtml(html, 'EUR'),
        cadGnf: extractBcrgRateFromHtml(html, 'CAD'),
        gbpGnf: extractBcrgRateFromHtml(html, 'GBP'),
        chfGnf: extractBcrgRateFromHtml(html, 'CHF'),
        jpyGnf: extractBcrgRateFromHtml(html, 'JPY'),
        cnyGnf: extractBcrgRateFromHtml(html, 'CNY'),
        dkkGnf: extractBcrgRateFromHtml(html, 'DKK'),
        nokGnf: extractBcrgRateFromHtml(html, 'NOK'),
        sekGnf: extractBcrgRateFromHtml(html, 'SEK'),
        sarGnf: extractBcrgRateFromHtml(html, 'SAR'),
        xofGnf: extractBcrgRateFromHtml(html, 'XOF'),
        dtsGnf: extractBcrgRateFromHtml(html, 'DTS'),
        ucaGnf: extractBcrgRateFromHtml(html, 'UCA'),
        scrapedUrl: url,
      };
      const extras = (['EUR','CAD','GBP','CHF','JPY','CNY','DKK','NOK','SEK','SAR'] as const)
        .filter(c => (result as any)[`${c.toLowerCase()}Gnf`]).join(',');
      logger.info(`[BCRG] USD/GNF: ${usdGnf}, devises extraites: ${extras || 'USD seulement'} (source: ${url})`);
      return result;
    } catch (e: any) {
      logger.warn(`[BCRG] Erreur pour ${url}: ${e.message}`);
    }
  }

  logger.warn('[BCRG] Toutes les URLs ont échoué. Site probablement inaccessible.');
  return null;
}

// ═══════════════════════════════════════════════════════════
// NIVEAU 2 — PARITÉS FIXES
// ═══════════════════════════════════════════════════════════

function computeFixedRates(
  config: CurrencyConfig,
  eurUsdRate: number,
): { rateUsd: number; rateEur: number } {
  const fixed = config.fixedRate!;
  if (fixed.base === 'EUR') {
    return { rateEur: fixed.rate, rateUsd: fixed.rate / eurUsdRate };
  }
  return { rateUsd: fixed.rate, rateEur: fixed.rate * eurUsdRate };
}

// ═══════════════════════════════════════════════════════════
// NIVEAU 4 — FALLBACK API
// ═══════════════════════════════════════════════════════════

async function fetchFallbackRates(): Promise<{
  usd: Record<string, number>;
  eur: Record<string, number>;
  eurUsd: number;
} | null> {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15_000);
    try {
      const [usdRes, eurRes] = await Promise.all([
        fetch('https://open.er-api.com/v6/latest/USD', { headers: { accept: 'application/json' }, signal: controller.signal }),
        fetch('https://open.er-api.com/v6/latest/EUR', { headers: { accept: 'application/json' }, signal: controller.signal }),
      ]);
      const usdJson = await usdRes.json();
      const eurJson = await eurRes.json();
      if (usdJson?.result !== 'success' || eurJson?.result !== 'success') {
        logger.error('[FALLBACK] API returned error');
        return null;
      }
      const eurUsd = usdJson.rates?.EUR ? 1 / usdJson.rates.EUR : 1.08;
      return { usd: usdJson.rates, eur: eurJson.rates, eurUsd };
    } finally {
      clearTimeout(timeout);
    }
  } catch (e: any) {
    logger.error(`[FALLBACK] Fetch failed: ${e.message}`);
    return null;
  }
}

// ═══════════════════════════════════════════════════════════
// HELPER — Upsert + Log
// ═══════════════════════════════════════════════════════════

async function upsertRateAndLog(
  code: string,
  collected: CollectedRate,
  margin: number,
  today: string,
  now: string,
  extraFields: Record<string, unknown> = {},
): Promise<void> {
  const { rateUsd, rateEur, source, sourceUrl, sourceType } = collected;
  const finalRateUsd = rateUsd * (1 + margin);
  const finalRateEur = rateEur * (1 + margin);
  const invFinalRateUsd = rateUsd > 0 ? 1 / finalRateUsd : 0;
  const invFinalRateEur = rateEur > 0 ? 1 / finalRateEur : 0;

  const baseFields = {
    source,
    source_url: sourceUrl,
    source_type: sourceType,
    effective_date: today,
    retrieved_at: now,
    status: 'OK',
    is_active: true,
    ...extraFields,
  };

  // ÉCRITURE ATOMIQUE : les 4 lignes (USD↔code, EUR↔code) en UN seul upsert = 1 transaction.
  // Tout-ou-rien : un cross-rate (code via USD/EUR) ne lit jamais un mélange ancien/nouveau.
  const rows: any[] = [
    {
      from_currency: 'USD', to_currency: code,
      rate: rateUsd, rate_usd: rateUsd, rate_eur: rateEur,
      margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
      ...baseFields,
    },
    {
      from_currency: 'EUR', to_currency: code,
      rate: rateEur, rate_usd: rateUsd, rate_eur: rateEur,
      margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
      ...baseFields,
    },
  ];
  if (rateUsd > 0) rows.push({
    from_currency: code, to_currency: 'USD',
    rate: 1 / rateUsd, rate_usd: 1 / rateUsd, rate_eur: 1 / rateEur,
    margin, final_rate_usd: invFinalRateUsd, final_rate_eur: invFinalRateEur,
    ...baseFields,
  });
  if (rateEur > 0) rows.push({
    from_currency: code, to_currency: 'EUR',
    rate: 1 / rateEur, rate_usd: 1 / rateUsd, rate_eur: 1 / rateEur,
    margin, final_rate_usd: invFinalRateUsd, final_rate_eur: invFinalRateEur,
    ...baseFields,
  });
  await supabaseAdmin.from('currency_exchange_rates').upsert(rows, { onConflict: 'from_currency,to_currency', ignoreDuplicates: false });

  await supabaseAdmin.from('fx_collection_log').insert({
    currency_code: code,
    rate_usd: rateUsd,
    rate_eur: rateEur,
    source,
    source_url: sourceUrl,
    source_type: sourceType,
    status: 'OK',
  });
}

// ═══════════════════════════════════════════════════════════
// COLLECTE PRINCIPALE
// ═══════════════════════════════════════════════════════════

export interface FxCollectResult {
  currency: string;
  status: string;
  sourceType: SourceType | 'none';
  source: string;
  rateUsd?: number;
  rateEur?: number;
  note?: string;
}

/**
 * Lance la collecte complète de tous les taux africains.
 * Appeler depuis le job BullMQ `fx.african-rates-refresh` (toutes les heures).
 */
export async function collectAfricanRates(): Promise<{
  results: FxCollectResult[];
  ok: number;
  fallback: number;
  cached: number;
  failed: number;
  durationMs: number;
}> {
  const startMs = Date.now();
  const results: FxCollectResult[] = [];

  // ── 1. Marge depuis margin_config ──
  const { data: marginRow } = await supabaseAdmin
    .from('margin_config')
    .select('config_value')
    .eq('config_key', 'default_margin')
    .maybeSingle();
  const margin: number = marginRow?.config_value ?? 0.03;

  // ── 2. Taux existants pour détecter les variations ──
  const { data: existingRates } = await supabaseAdmin
    .from('currency_exchange_rates')
    .select('from_currency, to_currency, rate, source_type')
    .eq('is_active', true)
    .in('to_currency', Object.keys(AFRICAN_CURRENCIES));

  const existingMap = new Map<string, number>();
  const existingSourceTypeMap = new Map<string, string>();
  if (existingRates) {
    for (const r of existingRates) {
      existingMap.set(`${r.from_currency}->${r.to_currency}`, Number(r.rate));
      existingSourceTypeMap.set(`${r.from_currency}->${r.to_currency}`, r.source_type || '');
    }
  }

  const now = new Date().toISOString();
  const today = now.split('T')[0];

  // ── 3. Scraping banques centrales (en parallèle) ──
  const [bceaoRates, bcrgRates] = await Promise.all([scrapeBceao(), scrapeBcrg()]);

  // ── 4. Fallback API ──
  const fallbackRates = await fetchFallbackRates();
  if (!fallbackRates) {
    logger.warn('[COLLECT] Fallback API indisponible. Seules les sources officielles seront mises à jour.');
  }

  // ── EUR/USD cross (priorité : BCEAO officiel) ──
  let eurUsdRate: number;
  if (bceaoRates?.usdXof) {
    eurUsdRate = 655.957 / bceaoRates.usdXof;
  } else if (fallbackRates?.eurUsd) {
    eurUsdRate = fallbackRates.eurUsd;
  } else {
    eurUsdRate = 1.08;
    logger.warn('[EUR/USD] Aucune source, utilisation de 1.08 par défaut');
  }

  // ── 5. Devises supplémentaires BCEAO (GBP, CHF, CAD, JPY, CNY, AED) ──
  if (bceaoRates) {
    const bceaoExtras: [string, number | undefined][] = [
      ['GBP', bceaoRates.gbpXof],
      ['CHF', bceaoRates.chfXof],
      ['CAD', bceaoRates.cadXof],
      ['JPY', bceaoRates.jpyXof],
      ['CNY', bceaoRates.cnyXof],
      ['AED', bceaoRates.aedXof],
    ];
    for (const [curr, rateToXof] of bceaoExtras) {
      if (!rateToXof || rateToXof <= 0) continue;
      const rateUsd = bceaoRates.usdXof / rateToXof;
      const rateEur = 655.957 / rateToXof;
      const finalRateUsd = rateUsd * (1 + margin);
      const finalRateEur = rateEur * (1 + margin);
      const invFinalRateUsd = rateUsd > 0 ? 1 / finalRateUsd : 0;
      const invFinalRateEur = rateEur > 0 ? 1 / finalRateEur : 0;
      const baseFields = {
        source: 'bceao-official-html',
        source_url: 'https://www.bceao.int/fr/cours/cours-des-devises',
        source_type: 'official_html',
        effective_date: today,
        retrieved_at: now,
        status: 'OK',
        is_active: true,
      };
      // ÉCRITURE ATOMIQUE : les lignes USD/EUR↔curr en UN seul upsert (1 transaction, tout-ou-rien
      // → un cross-rate ne lit jamais un mélange). La paire curr→XOF (autre forme) reste séparée.
      const bceaoRows: any[] = [
        {
          from_currency: 'USD', to_currency: curr,
          rate: rateUsd, rate_usd: rateUsd, rate_eur: rateEur,
          margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
          ...baseFields,
        },
        {
          from_currency: 'EUR', to_currency: curr,
          rate: rateEur, rate_usd: rateUsd, rate_eur: rateEur,
          margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
          ...baseFields,
        },
      ];
      if (rateUsd > 0) bceaoRows.push({
        from_currency: curr, to_currency: 'USD',
        rate: 1 / rateUsd, rate_usd: 1 / rateUsd, rate_eur: 1 / rateEur,
        margin, final_rate_usd: invFinalRateUsd, final_rate_eur: invFinalRateEur,
        ...baseFields,
      });
      if (rateEur > 0) bceaoRows.push({
        from_currency: curr, to_currency: 'EUR',
        rate: 1 / rateEur, rate_usd: 1 / rateUsd, rate_eur: 1 / rateEur,
        margin, final_rate_usd: invFinalRateUsd, final_rate_eur: invFinalRateEur,
        ...baseFields,
      });
      await Promise.all([
        supabaseAdmin.from('currency_exchange_rates').upsert(bceaoRows, { onConflict: 'from_currency,to_currency', ignoreDuplicates: false }),
        supabaseAdmin.from('currency_exchange_rates').upsert({
          from_currency: curr, to_currency: 'XOF',
          rate: rateToXof, source: 'bceao-official-html',
          source_type: 'official_html',
          source_url: 'https://www.bceao.int/fr/cours/cours-des-devises',
          effective_date: today, retrieved_at: now, status: 'OK', is_active: true,
        }, { onConflict: 'from_currency,to_currency', ignoreDuplicates: false }),
      ]);
    }
  }

  // ── 5b. BCRG cross rates — taux croisés vs GNF pour devises non-africaines ──
  // La BCRG publie quotidiennement 14 cours vs GNF. On les stocke directement,
  // plus précis que les taux croisés via BCEAO/XOF.
  if (bcrgRates) {
    const eurGnfForCross = bcrgRates.eurGnf ?? (bcrgRates.usdGnf * eurUsdRate);
    const bcrgCrossMap: Array<[string, number | undefined]> = [
      ['CAD', bcrgRates.cadGnf],
      ['GBP', bcrgRates.gbpGnf],
      ['CHF', bcrgRates.chfGnf],
      ['JPY', bcrgRates.jpyGnf],
      ['CNY', bcrgRates.cnyGnf],
      ['DKK', bcrgRates.dkkGnf],
      ['NOK', bcrgRates.nokGnf],
      ['SEK', bcrgRates.sekGnf],
      ['SAR', bcrgRates.sarGnf],
    ];
    for (const [curr, crossGnf] of bcrgCrossMap) {
      if (!crossGnf || crossGnf <= 0) continue;
      // Taux croisés exprimés en unités de `curr` par USD/EUR
      const rateUsd = bcrgRates.usdGnf / crossGnf;
      const rateEur = eurGnfForCross / crossGnf;
      const finalRateUsd = rateUsd * (1 + margin);
      const finalRateEur = rateEur * (1 + margin);
      const baseFields = {
        source: 'bcrg-official-html',
        source_url: bcrgRates.scrapedUrl,
        source_type: 'official_html' as const,
        effective_date: today,
        retrieved_at: now,
        status: 'OK',
        is_active: true,
      };
      // ÉCRITURE ATOMIQUE : les 6 lignes (USD↔curr, EUR↔curr, curr↔GNF) en UN seul upsert
      // = 1 transaction. Tout-ou-rien : un cross-rate (curr via USD/EUR) ne lit jamais un mélange.
      await supabaseAdmin.from('currency_exchange_rates').upsert([
        {
          from_currency: 'USD', to_currency: curr,
          rate: rateUsd, rate_usd: rateUsd, rate_eur: rateEur,
          margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
          ...baseFields,
        },
        {
          from_currency: 'EUR', to_currency: curr,
          rate: rateEur, rate_usd: rateUsd, rate_eur: rateEur,
          margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
          ...baseFields,
        },
        {
          from_currency: curr, to_currency: 'USD',
          rate: 1 / rateUsd, rate_usd: 1 / rateUsd, rate_eur: 1 / rateEur,
          margin, final_rate_usd: 1 / finalRateUsd, final_rate_eur: 1 / finalRateEur,
          ...baseFields,
        },
        {
          from_currency: curr, to_currency: 'EUR',
          rate: 1 / rateEur, rate_usd: 1 / rateUsd, rate_eur: 1 / rateEur,
          margin, final_rate_usd: 1 / finalRateUsd, final_rate_eur: 1 / finalRateEur,
          ...baseFields,
        },
        // Paires directes avec GNF
        {
          from_currency: curr, to_currency: 'GNF',
          rate: crossGnf, rate_usd: rateUsd, rate_eur: rateEur,
          margin, final_rate_usd: crossGnf * (1 + margin), final_rate_eur: crossGnf * (1 + margin),
          ...baseFields,
        },
        {
          from_currency: 'GNF', to_currency: curr,
          rate: 1 / crossGnf, rate_usd: 1 / rateUsd, rate_eur: 1 / rateEur,
          margin, final_rate_usd: 1 / (crossGnf * (1 + margin)), final_rate_eur: 1 / (crossGnf * (1 + margin)),
          ...baseFields,
        },
      ], { onConflict: 'from_currency,to_currency', ignoreDuplicates: false });
    }
    logger.info(`[BCRG-CROSS] Taux croisés BCRG stockés: ${bcrgCrossMap.filter(([, v]) => v).map(([c]) => c).join(', ')}`);
  }

  // ── 6. Boucle principale sur chaque devise africaine ──
  for (const [code, config] of Object.entries(AFRICAN_CURRENCIES)) {
    let collected: CollectedRate | null = null;

    // NIVEAU 1 : GNF via BCRG (règle absolue — jamais de fallback API)
    if (code === 'GNF') {
      if (bcrgRates) {
        const eurGnf = bcrgRates.eurGnf || bcrgRates.usdGnf * eurUsdRate;
        collected = {
          rateUsd: bcrgRates.usdGnf,
          rateEur: eurGnf,
          source: 'bcrg-official-html',
          sourceUrl: bcrgRates.scrapedUrl,
          sourceType: 'official_html',
        };
      } else {
        const existingType = existingSourceTypeMap.get('USD->GNF');
        if (existingType === 'official_html') {
          // Heartbeat : retrieved_at mis à jour, last_bcrg_scraped_at conservé
          await Promise.all([
            supabaseAdmin.from('currency_exchange_rates')
              .update({ retrieved_at: now, effective_date: today, status: 'BCRG_CACHED', is_active: true })
              .eq('from_currency', 'USD').eq('to_currency', 'GNF'),
            supabaseAdmin.from('currency_exchange_rates')
              .update({ retrieved_at: now, effective_date: today, status: 'BCRG_CACHED', is_active: true })
              .eq('from_currency', 'EUR').eq('to_currency', 'GNF'),
            supabaseAdmin.from('currency_exchange_rates')
              .update({ retrieved_at: now, effective_date: today, status: 'BCRG_CACHED', is_active: true })
              .eq('from_currency', 'GNF').eq('to_currency', 'USD'),
            supabaseAdmin.from('currency_exchange_rates')
              .update({ retrieved_at: now, effective_date: today, status: 'BCRG_CACHED', is_active: true })
              .eq('from_currency', 'GNF').eq('to_currency', 'EUR'),
          ]);
          await supabaseAdmin.from('fx_collection_log').insert({
            currency_code: 'GNF',
            source: 'bcrg-heartbeat',
            source_url: BCRG_PRIMARY_URL,
            source_type: 'official_html',
            status: 'BCRG_CACHED',
            error_message: 'BCRG inaccessible — dernier taux officiel BCRG conservé (heartbeat)',
          });
          results.push({ currency: 'GNF', status: 'BCRG_CACHED', sourceType: 'official_html', source: 'bcrg-heartbeat', note: 'Site BCRG inaccessible, dernier taux conservé' });
          continue;
        } else {
          logger.warn('[BCRG] Aucun taux official_html GNF en DB. Fallback API autorisé exceptionnellement.');
        }
      }
    }

    // NIVEAU 1 : XOF via BCEAO
    if (code === 'XOF' && bceaoRates) {
      collected = {
        rateUsd: bceaoRates.usdXof,
        rateEur: 655.957,
        source: 'bceao-official-html+peg',
        sourceUrl: 'https://www.bceao.int/fr/cours/cours-des-devises',
        sourceType: 'official_html',
      };
    }

    // NIVEAU 1 : XAF via BCEAO cross
    if (code === 'XAF' && bceaoRates) {
      collected = {
        rateUsd: bceaoRates.usdXof,
        rateEur: 655.957,
        source: 'beac-peg+bceao-official-cross',
        sourceUrl: 'https://www.beac.int',
        sourceType: 'official_cross',
      };
    }

    // NIVEAU 2 : Parités fixes
    if (!collected && config.fixedRate) {
      const fixed = computeFixedRates(config, eurUsdRate);
      collected = {
        rateUsd: fixed.rateUsd,
        rateEur: fixed.rateEur,
        source: `official-peg-${config.fixedRate.base}`,
        sourceUrl: config.zone === 'BCEAO'
          ? 'https://www.bceao.int'
          : config.zone === 'BEAC'
            ? 'https://www.beac.int'
            : 'official-monetary-agreement',
        sourceType: 'official_fixed_parity',
      };
    }

    // NIVEAU 3 : Devises arrimées (cross)
    if (!collected && config.peggedTo) {
      const parentRate = fallbackRates?.usd[config.peggedTo];
      const parentRateEur = fallbackRates?.eur[config.peggedTo];
      if (parentRate && parentRateEur) {
        collected = {
          rateUsd: parentRate,
          rateEur: parentRateEur,
          source: `official-peg-${config.peggedTo}`,
          sourceUrl: 'official-currency-board',
          sourceType: 'official_cross',
        };
      }
    }

    // NIVEAU 4 : Fallback API
    if (!collected) {
      if (!fallbackRates) {
        await supabaseAdmin.from('fx_collection_log').insert({
          currency_code: code,
          source: 'none',
          source_url: 'N/A',
          source_type: 'fallback_api',
          status: 'FALLBACK',
          error_message: `Aucune source disponible pour ${code}. Raison: ${config.fallbackReason || 'API indisponible'}`,
        });
        results.push({ currency: code, status: 'FALLBACK', sourceType: 'none', source: 'none', note: config.fallbackReason });
        continue;
      }
      const rateUsd = fallbackRates.usd[code];
      const rateEur = fallbackRates.eur[code];
      if (!rateUsd || !rateEur) {
        await supabaseAdmin.from('fx_collection_log').insert({
          currency_code: code,
          source: 'fallback-api',
          source_url: 'https://open.er-api.com',
          source_type: 'fallback_api',
          status: 'FALLBACK',
          error_message: `Taux non disponible pour ${code} dans l'API de référence`,
        });
        results.push({ currency: code, status: 'FALLBACK', sourceType: 'fallback_api', source: 'fallback-api', note: config.fallbackReason });
        continue;
      }
      collected = {
        rateUsd,
        rateEur,
        source: 'fallback-api',
        sourceUrl: 'https://open.er-api.com',
        sourceType: 'fallback_api',
      };
    }

    if (!collected?.rateUsd || !collected?.rateEur) continue;

    // BCRG (GNF officiel) : toujours upsert complet — tout changement, même infime, doit être enregistré
    const isBcrgOfficial = collected.sourceType === 'official_html' && collected.source.includes('bcrg');
    // Pour les autres sources : ignorer les variations < 0.1%
    const existingUsd = existingMap.get(`USD->${code}`);
    if (!isBcrgOfficial && existingUsd && Math.abs(collected.rateUsd - existingUsd) / existingUsd < VARIATION_THRESHOLD) {
      const finalRateUsd = collected.rateUsd * (1 + margin);
      const finalRateEur = collected.rateEur * (1 + margin);
      const invFinalRateUsd = collected.rateUsd > 0 ? 1 / finalRateUsd : 0;
      const invFinalRateEur = collected.rateEur > 0 ? 1 / finalRateEur : 0;
      const noChangeBcrgExtra = (code === 'GNF' && collected.sourceType === 'official_html')
        ? { last_bcrg_scraped_at: now }
        : {};

      await Promise.all([
        supabaseAdmin.from('currency_exchange_rates').update({
          rate: collected.rateUsd,
          retrieved_at: now, effective_date: today,
          source: collected.source, source_url: collected.sourceUrl, source_type: collected.sourceType,
          status: 'OK', is_active: true, margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
          ...noChangeBcrgExtra,
        }).eq('from_currency', 'USD').eq('to_currency', code),
        supabaseAdmin.from('currency_exchange_rates').update({
          rate: collected.rateEur,
          retrieved_at: now, effective_date: today,
          source: collected.source, source_url: collected.sourceUrl, source_type: collected.sourceType,
          status: 'OK', is_active: true, margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
          ...noChangeBcrgExtra,
        }).eq('from_currency', 'EUR').eq('to_currency', code),
        supabaseAdmin.from('currency_exchange_rates').update({
          rate: collected.rateUsd > 0 ? 1 / collected.rateUsd : undefined,
          retrieved_at: now, effective_date: today,
          source: collected.source, source_url: collected.sourceUrl, source_type: collected.sourceType,
          status: 'OK', is_active: true, margin, final_rate_usd: invFinalRateUsd, final_rate_eur: invFinalRateEur,
          ...noChangeBcrgExtra,
        }).eq('from_currency', code).eq('to_currency', 'USD'),
        supabaseAdmin.from('currency_exchange_rates').update({
          rate: collected.rateEur > 0 ? 1 / collected.rateEur : undefined,
          retrieved_at: now, effective_date: today,
          source: collected.source, source_url: collected.sourceUrl, source_type: collected.sourceType,
          status: 'OK', is_active: true, margin, final_rate_usd: invFinalRateUsd, final_rate_eur: invFinalRateEur,
          ...noChangeBcrgExtra,
        }).eq('from_currency', code).eq('to_currency', 'EUR'),
      ]);

      await supabaseAdmin.from('fx_collection_log').insert({
        currency_code: code,
        rate_usd: collected.rateUsd,
        rate_eur: collected.rateEur,
        source: collected.source,
        source_url: collected.sourceUrl,
        source_type: collected.sourceType,
        status: 'NO_CHANGE',
        error_message: 'Aucune variation significative, heartbeat horaire appliqué',
      });

      results.push({ currency: code, status: 'NO_CHANGE', sourceType: collected.sourceType, source: collected.source, rateUsd: collected.rateUsd, rateEur: collected.rateEur });
      continue;
    }

    // Upsert complet avec last_bcrg_scraped_at si GNF officiel
    const gnfExtra = (code === 'GNF' && collected.sourceType === 'official_html')
      ? { last_bcrg_scraped_at: now }
      : {};
    await upsertRateAndLog(code, collected, margin, today, now, gnfExtra);

    results.push({ currency: code, status: 'OK', sourceType: collected.sourceType, source: collected.source, rateUsd: collected.rateUsd, rateEur: collected.rateEur });
  }

  const durationMs = Date.now() - startMs;
  const ok = results.filter(r => r.status === 'OK').length;
  const fallback = results.filter(r => r.status === 'FALLBACK').length;
  const cached = results.filter(r => r.status === 'BCRG_CACHED' || r.status === 'NO_CHANGE').length;
  const failed = results.filter(r => !['OK', 'FALLBACK', 'BCRG_CACHED', 'NO_CHANGE'].includes(r.status)).length;

  logger.info(`[FX] Collecte terminée — OK: ${ok}, NO_CHANGE: ${results.filter(r => r.status === 'NO_CHANGE').length}, BCRG_CACHED: ${results.filter(r => r.status === 'BCRG_CACHED').length}, FALLBACK: ${fallback}, durée: ${durationMs}ms`);

  return { results, ok, fallback, cached, failed, durationMs };
}

// ═══════════════════════════════════════════════════════════
// SURVEILLANCE BCRG EN TEMPS RÉEL (toutes les 5 minutes)
// ═══════════════════════════════════════════════════════════

export interface BcrgRefreshResult {
  changed: boolean;
  changedPairs: string[];
  usdGnf: number | null;
  eurGnf: number | null;
  durationMs: number;
}

/**
 * Snapshot en mémoire du dernier scraping BCRG réussi.
 * Mis à jour par refreshBcrgOnly() à chaque détection de changement.
 * Accessible via GET /admin/fx-rates-check sans scraping supplémentaire.
 */
export let bcrgLastSnapshot: {
  changedAt: string;
  checkedAt: string;
  usdGnf: number;
  eurGnf: number | null;
  cadGnf: number | null;
  gbpGnf: number | null;
  chfGnf: number | null;
  changedPairs: string[];
  sourceUrl: string;
} | null = null;

/**
 * Scrape uniquement la page d'accueil BCRG et met à jour la base immédiatement
 * si le moindre taux a changé. Conçu pour être appelé toutes les 5 minutes.
 * Ne touche pas BCEAO ni l'API fallback.
 */
export async function refreshBcrgOnly(): Promise<BcrgRefreshResult> {
  const startMs = Date.now();
  const bcrgRates = await scrapeBcrg().catch(() => null);

  if (!bcrgRates) {
    logger.warn('[BCRG-LIVE] Scraping échoué (site inaccessible ?)');
    return { changed: false, changedPairs: [], usdGnf: null, eurGnf: null, durationMs: Date.now() - startMs };
  }

  const { data: marginRow } = await supabaseAdmin
    .from('margin_config').select('config_value').eq('config_key', 'default_margin').maybeSingle();
  const margin = Number(marginRow?.config_value ?? 0.03);

  const now = new Date().toISOString();
  const today = now.split('T')[0];

  // Récupérer les taux courants en DB pour détecter les changements
  const { data: existingRows } = await supabaseAdmin
    .from('currency_exchange_rates')
    .select('from_currency, to_currency, rate')
    .eq('is_active', true)
    .eq('to_currency', 'GNF')
    .in('from_currency', ['USD', 'EUR', 'CAD', 'GBP', 'CHF', 'JPY', 'CNY', 'DKK', 'NOK', 'SEK', 'SAR', 'XOF']);

  const dbRates = new Map<string, number>();
  for (const r of existingRows ?? []) dbRates.set(r.from_currency, Number(r.rate));

  const pairs: Array<[string, number | undefined]> = [
    ['USD', bcrgRates.usdGnf],
    ['EUR', bcrgRates.eurGnf],
    ['CAD', bcrgRates.cadGnf],
    ['GBP', bcrgRates.gbpGnf],
    ['CHF', bcrgRates.chfGnf],
    ['JPY', bcrgRates.jpyGnf],
    ['CNY', bcrgRates.cnyGnf],
    ['DKK', bcrgRates.dkkGnf],
    ['NOK', bcrgRates.nokGnf],
    ['SEK', bcrgRates.sekGnf],
    ['SAR', bcrgRates.sarGnf],
    ['XOF', bcrgRates.xofGnf],
  ];

  const changedPairs: string[] = [];
  const rowsToUpsert: any[] = [];
  const baseFields = {
    source: 'bcrg-live-check',
    source_url: bcrgRates.scrapedUrl,
    source_type: 'official_html',
    effective_date: today,
    retrieved_at: now,
    // Toutes les devises BCRG reçoivent last_bcrg_scraped_at — requis par create_order_core Phase -1
    last_bcrg_scraped_at: now,
    status: 'OK',
    is_active: true,
  };

  for (const [curr, crossGnf] of pairs) {
    if (!crossGnf || crossGnf <= 0) continue;
    const prev = dbRates.get(curr);
    if (prev !== crossGnf) changedPairs.push(`${curr}/GNF`);

    const finalRate = crossGnf * (1 + margin);
    rowsToUpsert.push(
      {
        from_currency: curr, to_currency: 'GNF',
        rate: crossGnf, margin, final_rate_usd: finalRate, final_rate_eur: finalRate,
        ...baseFields,
      },
      {
        from_currency: 'GNF', to_currency: curr,
        rate: 1 / crossGnf, margin, final_rate_usd: 1 / finalRate, final_rate_eur: 1 / finalRate,
        ...baseFields,
      },
    );
  }

  // ÉCRITURE ATOMIQUE : un SEUL upsert de tout le lot = un seul INSERT … ON CONFLICT (1 transaction
  // PostgREST). Tout-ou-rien : un lecteur (conversion / cross-rate via USD-EUR) ne voit JAMAIS un
  // mélange ancien/nouveau taux. Avant : 24 upserts séparés (24 transactions) = état incohérent possible.
  if (rowsToUpsert.length > 0) {
    const { error: upsertError } = await supabaseAdmin
      .from('currency_exchange_rates')
      .upsert(rowsToUpsert, { onConflict: 'from_currency,to_currency', ignoreDuplicates: false });
    if (upsertError) {
      logger.error(`[BCRG-LIVE] Échec upsert atomique des taux (aucune écriture appliquée): ${upsertError.message}`);
      return { changed: false, changedPairs: [], usdGnf: null, eurGnf: null, durationMs: Date.now() - startMs };
    }
  }

  // Mise à jour du snapshot en mémoire — accessible via /admin/fx-rates-check sans scraping
  const checkedAt = now;
  if (changedPairs.length > 0) {
    bcrgLastSnapshot = {
      changedAt: now,
      checkedAt,
      usdGnf: bcrgRates.usdGnf,
      eurGnf: bcrgRates.eurGnf ?? null,
      cadGnf: bcrgRates.cadGnf ?? null,
      gbpGnf: bcrgRates.gbpGnf ?? null,
      chfGnf: bcrgRates.chfGnf ?? null,
      changedPairs,
      sourceUrl: bcrgRates.scrapedUrl,
    };
    logger.info(`[BCRG-LIVE] Changements détectés: ${changedPairs.join(', ')} | USD/GNF=${bcrgRates.usdGnf} EUR/GNF=${bcrgRates.eurGnf ?? '?'}`);

    // Broadcast SSE instantané vers tous les clients PDG connectés
    if (bcrgSseClients.size > 0) {
      const payload = `data: ${JSON.stringify(bcrgLastSnapshot)}\n\n`;
      const dead: SseWriter[] = [];
      for (const client of bcrgSseClients) {
        if (client.writableEnded) { dead.push(client); continue; }
        try { client.write(payload); } catch { dead.push(client); }
      }
      for (const c of dead) bcrgSseClients.delete(c);
      if (bcrgSseClients.size > 0) logger.info(`[BCRG-LIVE] Broadcast SSE → ${bcrgSseClients.size} client(s)`);
    }

    await Promise.resolve(supabaseAdmin.from('fx_collection_log').insert({
      currency_code: 'GNF',
      rate_usd: bcrgRates.usdGnf,
      rate_eur: bcrgRates.eurGnf ?? null,
      source: 'bcrg-live-check',
      source_url: bcrgRates.scrapedUrl,
      source_type: 'official_html',
      status: 'OK',
      error_message: `Taux modifiés: ${changedPairs.join(', ')}`,
    })).catch(() => {});
  } else if (bcrgLastSnapshot) {
    // Mise à jour de checkedAt même sans changement (fraîcheur du poll)
    bcrgLastSnapshot = { ...bcrgLastSnapshot, checkedAt };
  } else {
    // Premier scraping réussi — on initialise le snapshot
    bcrgLastSnapshot = {
      changedAt: now,
      checkedAt,
      usdGnf: bcrgRates.usdGnf,
      eurGnf: bcrgRates.eurGnf ?? null,
      cadGnf: bcrgRates.cadGnf ?? null,
      gbpGnf: bcrgRates.gbpGnf ?? null,
      chfGnf: bcrgRates.chfGnf ?? null,
      changedPairs: [],
      sourceUrl: bcrgRates.scrapedUrl,
    };
  }

  return {
    changed: changedPairs.length > 0,
    changedPairs,
    usdGnf: bcrgRates.usdGnf,
    eurGnf: bcrgRates.eurGnf ?? null,
    durationMs: Date.now() - startMs,
  };
}
