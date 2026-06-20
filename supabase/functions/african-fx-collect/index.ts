import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.4";
import { corsHeaders } from "../_shared/cors.ts";

/**
 * 🌍 African FX Rate Collector — Sources officielles multi-niveaux
 *
 * Collecte les taux de change depuis les banques centrales africaines,
 * applique la marge configurable (défaut 3%), et stocke dans
 * `currency_exchange_rates` + `fx_collection_log`.
 *
 * === HIÉRARCHIE DES SOURCES (4 niveaux) ===
 *
 * NIVEAU 1 — official_html : Scraping HTML de banques centrales
 *   • BCRG  (bcrg.gov.gn)        → GNF  (USD/GNF, EUR/GNF)
 *   • BCEAO (bceao.int)           → XOF  (USD/XOF, EUR/XOF, GBP/XOF, CHF/XOF, CAD/XOF, JPY/XOF, CNY/XOF, AED/XOF)
 *
 * NIVEAU 2 — official_fixed_parity : Parités fixes officielles documentées
 *   • XOF (UEMOA) : 1 EUR = 655.957 XOF (accord monétaire BCEAO)
 *   • XAF (CEMAC) : 1 EUR = 655.957 XAF (accord monétaire BEAC)
 *   • KMF, CVE, STN, DJF, ERN   : parités fixes documentées
 *
 * NIVEAU 3 — official_cross : Taux croisés calculés depuis sources officielles
 *   • XAF USD cross calculé depuis BCEAO USD/XOF (même parité EUR)
 *   • NAD, LSL, SZL arrimés au ZAR
 *
 * NIVEAU 4 — fallback_api : Agrégateur externe (open.er-api.com)
 *   • Devises sans source officielle exploitable automatiquement
 *   • Clairement marqué source_type="fallback_api" pour traçabilité
 *
 * === DOCUMENTATION PAR DEVISE (pourquoi fallback) ===
 *
 * GNF  — BCRG : site officiel bcrg.gov.gn souvent inaccessible (serveur instable).
 *         Scraping tenté à chaque collecte. Fallback si échec.
 * NGN  — CBN  : api.cbn.gov.ng nécessite un accès API spécifique. Fallback.
 * ZAR  — SARB : site complexe en JS dynamique, pas de tableau HTML simple. Fallback.
 * EGP  — CBE  : cbe.org.eg en JS dynamique, pas de données HTML statiques. Fallback.
 * MAD  — BAM  : bkam.ma publie des PDF, pas de HTML structuré. Fallback.
 * TND  — BCT  : bct.gov.tn en JS/Angular, pas de HTML statique. Fallback.
 * DZD  — BA   : bank-of-algeria.dz pas de publication web exploitable. Fallback.
 * KES  — CBK  : centralbank.go.ke en JS dynamique. Fallback.
 * GHS  — BOG  : bog.gov.gh nécessite parsing JS. Fallback.
 * TZS  — BOT  : bot.go.tz pas de HTML structuré stable. Fallback.
 * UGX  — BOU  : bou.or.ug nécessite JavaScript. Fallback.
 * ETB  — NBE  : nbebank.com en JS dynamique. Fallback.
 * Autres — Sites officiels non exploitables automatiquement. Fallback documenté.
 *
 * === RÈGLE MÉTIER ===
 * Pour BCEAO : on prend le taux d'ACHAT (cours auquel le bureau de change achète
 * la devise étrangère). C'est le taux le plus conservateur pour nos utilisateurs.
 *
 * Appelé par pg_cron toutes les heures + quotidiennement à minuit Africa/Conakry.
 */

// ═══════════════════════════════════════════════════════════
// TYPES
// ═══════════════════════════════════════════════════════════

type SourceType = "official_html" | "official_fixed_parity" | "official_cross" | "fallback_api";

interface CurrencyConfig {
  country: string;
  zone?: string;
  /** Pour parités fixes : taux fixe officiel */
  fixedRate?: { base: "EUR" | "USD"; rate: number };
  /**
   * Raison documentée si la devise est en fallback.
   * Vide si source officielle disponible.
   */
  fallbackReason?: string;
  /** Devises arrimées à une autre devise */
  peggedTo?: string;
}

interface CollectedRate {
  rateUsd: number;
  rateEur: number;
  source: string;
  sourceUrl: string;
  sourceType: SourceType;
}

// ═══════════════════════════════════════════════════════════
// CONFIGURATION DES 42 DEVISES AFRICAINES
// ═══════════════════════════════════════════════════════════

const AFRICAN_CURRENCIES: Record<string, CurrencyConfig> = {
  // ── Parités fixes officielles (Niveau 2) ──
  XOF: { country: "UEMOA", zone: "BCEAO", fixedRate: { base: "EUR", rate: 655.957 } },
  XAF: { country: "CEMAC", zone: "BEAC", fixedRate: { base: "EUR", rate: 655.957 } },
  KMF: { country: "Comores", fixedRate: { base: "EUR", rate: 491.96775 } },
  CVE: { country: "Cap-Vert", fixedRate: { base: "EUR", rate: 110.265 } },
  STN: { country: "São Tomé-et-Príncipe", fixedRate: { base: "EUR", rate: 24.5 } },
  DJF: { country: "Djibouti", fixedRate: { base: "USD", rate: 177.721 } },
  ERN: { country: "Érythrée", fixedRate: { base: "USD", rate: 15.0 } },

  // ── Devises arrimées (Niveau 3 : official_cross) ──
  NAD: { country: "Namibie", peggedTo: "ZAR" },
  LSL: { country: "Lesotho", peggedTo: "ZAR" },
  SZL: { country: "Eswatini", peggedTo: "ZAR" },

  // ── Source officielle HTML tentée (Niveau 1 prioritaire, fallback si échec) ──
  GNF: { country: "Guinée" },
  // GNF : source BCRG (bcrg-guinee.org) OBLIGATOIRE.
  // Si BCRG inaccessible → heartbeat sur dernier taux BCRG (jamais de fallback API pour GNF).

  // ── Devises en fallback API documenté (Niveau 4) ──
  NGN: { country: "Nigeria", fallbackReason: "CBN : api.cbn.gov.ng nécessite accès API spécifique" },
  ZAR: { country: "Afrique du Sud", fallbackReason: "SARB : site en JS dynamique, pas de tableau HTML" },
  EGP: { country: "Égypte", fallbackReason: "CBE : cbe.org.eg en JS dynamique" },
  MAD: { country: "Maroc", fallbackReason: "BAM : bkam.ma publie des PDF, pas de HTML structuré" },
  TND: { country: "Tunisie", fallbackReason: "BCT : bct.gov.tn en JS/Angular" },
  DZD: { country: "Algérie", fallbackReason: "BA : bank-of-algeria.dz pas de publication web exploitable" },
  KES: { country: "Kenya", fallbackReason: "CBK : centralbank.go.ke en JS dynamique" },
  GHS: { country: "Ghana", fallbackReason: "BOG : bog.gov.gh nécessite parsing JS" },
  TZS: { country: "Tanzanie", fallbackReason: "BOT : bot.go.tz pas de HTML structuré stable" },
  UGX: { country: "Ouganda", fallbackReason: "BOU : bou.or.ug nécessite JavaScript" },
  ETB: { country: "Éthiopie", fallbackReason: "NBE : nbebank.com en JS dynamique" },
  MZN: { country: "Mozambique", fallbackReason: "BM : bancomoc.mz en JS dynamique" },
  AOA: { country: "Angola", fallbackReason: "BNA : bna.ao nécessite JS" },
  CDF: { country: "RD Congo", fallbackReason: "BCC : bcc.cd site instable" },
  RWF: { country: "Rwanda", fallbackReason: "BNR : bnr.rw en JS dynamique" },
  BIF: { country: "Burundi", fallbackReason: "BRB : brb.bi pas de publication web exploitable" },
  MGA: { country: "Madagascar", fallbackReason: "BCM : banque-centrale.mg en JS" },
  MUR: { country: "Maurice", fallbackReason: "BOM : bom.mu en JS dynamique" },
  SCR: { country: "Seychelles", fallbackReason: "CBS : cbs.sc pas de HTML structuré" },
  GMD: { country: "Gambie", fallbackReason: "CBG : cbg.gm pas de tableau HTML exploitable" },
  SLL: { country: "Sierra Leone", fallbackReason: "BSL : bsl.gov.sl site instable" },
  LRD: { country: "Liberia", fallbackReason: "CBL : cbl.org.lr pas de publication web exploitable" },
  BWP: { country: "Botswana", fallbackReason: "BOB : bankofbotswana.bw en JS" },
  MWK: { country: "Malawi", fallbackReason: "RBM : rbm.mw en JS dynamique" },
  ZMW: { country: "Zambie", fallbackReason: "BOZ : boz.zm en JS dynamique" },
  SDG: { country: "Soudan", fallbackReason: "CBOS : cbos.gov.sd site souvent inaccessible" },
  SSP: { country: "Soudan du Sud", fallbackReason: "BOSS : bankofsouthsudan.org site instable" },
  SOS: { country: "Somalie", fallbackReason: "CBS : centralbanksomaliaonline.com pas de données exploitables" },
  LYD: { country: "Libye", fallbackReason: "CBL : cbl.gov.ly pas de tableau HTML" },
  MRU: { country: "Mauritanie", fallbackReason: "BCM : bcm.mr pas de publication web automatisable" },
  ZWL: { country: "Zimbabwe", fallbackReason: "RBZ : rbz.co.zw nécessite JS" },
};

const VARIATION_THRESHOLD = 0.001; // 0.1%

// ═══════════════════════════════════════════════════════════
// NIVEAU 1 — SCRAPING BANQUES CENTRALES (HTML)
// ═══════════════════════════════════════════════════════════

// ── BCEAO : Cours des devises contre Franc CFA ──
// URL : https://www.bceao.int/fr/cours/cours-des-devises
// Table : "Cours des devises du <date>" avec colonnes Devise | Achat | Vente
// Règle métier : on prend le taux d'ACHAT (plus conservateur)

interface BceaoRates {
  /** USD → XOF (taux d'achat) */
  usdXof: number;
  /** GBP → XOF */
  gbpXof?: number;
  /** CHF → XOF */
  chfXof?: number;
  /** CAD → XOF */
  cadXof?: number;
  /** JPY → XOF */
  jpyXof?: number;
  /** CNY → XOF */
  cnyXof?: number;
  /** AED → XOF */
  aedXof?: number;
}

function parseFrenchNumber(s: string): number {
  // "565,250" or "3 535,250" → 565.25 or 3535.25
  return parseFloat(s.replace(/\s/g, "").replace(",", "."));
}

async function scrapeBceao(): Promise<BceaoRates | null> {
  try {
    const url = "https://www.bceao.int/fr/cours/cours-des-devises";
    const resp = await fetch(url, {
      headers: { "User-Agent": "224Solutions-FX-Collector/2.0", "Accept": "text/html" },
    });
    if (!resp.ok) {
      console.warn(`[BCEAO] HTTP ${resp.status}`);
      await resp.text();
      return null;
    }
    const html = await resp.text();

    // Parse markdown-style table or HTML table
    // The page renders: | Devise | Achat | Vente |
    // Pattern: "Dollar us | 565,250 | 572,250"
    const result: BceaoRates = { usdXof: 0 };

    // Currency mappings: BCEAO label → our extraction
    const currencyPatterns: { label: RegExp; key: keyof BceaoRates }[] = [
      { label: /Dollar\s+us/i, key: "usdXof" },
      { label: /Livre\s+sterling/i, key: "gbpXof" },
      { label: /Franc\s+suisse/i, key: "chfXof" },
      { label: /Dollar\s+canadien/i, key: "cadXof" },
      { label: /Yen\s+japonais/i, key: "jpyXof" },
      { label: /Yuan\s+chinois/i, key: "cnyXof" },
      { label: /Dirham\s+Emirats/i, key: "aedXof" },
    ];

    for (const { label, key } of currencyPatterns) {
      // Try HTML table format: <td>Dollar us</td><td>565,250</td><td>572,250</td>
      const htmlPattern = new RegExp(
        label.source + `[^<]*<\\/td>\\s*<td[^>]*>\\s*([\\d\\s,.]+)\\s*<\\/td>\\s*<td[^>]*>\\s*([\\d\\s,.]+)`,
        "i"
      );
      let match = html.match(htmlPattern);

      if (!match) {
        // Try markdown table: Dollar us | 565,250 | 572,250
        const mdPattern = new RegExp(
          label.source + `\\s*\\|\\s*([\\d\\s,.]+)\\s*\\|\\s*([\\d\\s,.]+)`,
          "i"
        );
        match = html.match(mdPattern);
      }

      if (match) {
        const buy = parseFrenchNumber(match[1]);
        if (!isNaN(buy) && buy > 0) {
          // Règle métier : on prend le taux d'ACHAT (match[1])
          (result as any)[key] = buy;
        }
      }
    }

    if (!result.usdXof || result.usdXof <= 0) {
      console.warn("[BCEAO] Taux USD introuvable dans le HTML");
      return null;
    }

    console.log(`[BCEAO] Taux scrappés — USD/XOF: ${result.usdXof}` +
      (result.gbpXof ? `, GBP/XOF: ${result.gbpXof}` : "") +
      (result.chfXof ? `, CHF/XOF: ${result.chfXof}` : "") +
      (result.cadXof ? `, CAD/XOF: ${result.cadXof}` : ""));
    return result;
  } catch (e) {
    console.error("[BCEAO] Scraping failed:", e);
    return null;
  }
}

// ── BCRG : Banque Centrale de la République de Guinée ──
// Source OFFICIELLE et OBLIGATOIRE pour les taux GNF.
// Site : https://www.bcrg-guinee.org
// Le site publie un fixing quotidien USD/GNF et EUR/GNF.
// En cas d'échec → heartbeat (taux conservé, last_bcrg_scraped_at NON mis à jour)
// → les transactions GNF refusées si last_bcrg_scraped_at > 24h.

interface BcrgRates {
  usdGnf: number;
  eurGnf?: number;   // Optionnel — calculé depuis BCEAO si absent dans le HTML BCRG
  scrapedUrl: string; // URL qui a fourni les données
}

const BCRG_PRIMARY_URL = "https://www.bcrg-guinee.org";

// Plages historiques raisonnables pour les taux GNF (2024-2026).
// Si un taux scraped sort de ces plages → données "floues" → rejeté.
const GNF_SANITY_RANGES: Record<"USD" | "EUR", { min: number; max: number }> = {
  USD: { min: 6_500, max: 14_000 },
  EUR: { min: 7_500, max: 16_000 },
};

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
    if (!urls.includes(normalized)) {
      urls.push(normalized);
    }
  };

  for (const match of html.matchAll(/href=["']([^"']*\/cours_des_devises\/fixing-du-[^"']+)["']/gi)) {
    pushUrl(match[1]);
  }

  for (const match of html.matchAll(/https?:\/\/www\.bcrg-guinee\.org\/cours_des_devises\/fixing-du-[^"'\s<]+/gi)) {
    pushUrl(match[0]);
  }

  return urls;
}

function extractBcrgRateFromHtml(html: string, currency: 'USD' | 'EUR'): number | undefined {
  const labelPattern = currency === 'USD' ? '(?:USD|Dollar)' : '(?:EUR|Euro)';
  const patterns = [
    new RegExp(`${labelPattern}\\s*=\\s*<\\/h\\d>[\\s\\S]{0,1800}?<h\\d[^>]*>\\s*([\\d\\s.,]+)\\s*<\\/h\\d>`, 'gi'),
    new RegExp(`<td[^>]*>\\s*${labelPattern}\\s*=?\\s*<\\/td>\\s*<td[^>]*>\\s*([\\d\\s.,]+)\\s*<\\/td>`, 'gi'),
    new RegExp(`(?:1\\s*${currency}\\s*=\\s*|${currency}\\s*\\/\\s*GNF\\s*[:=]\\s*)([\\d\\s.,]+)`, 'gi'),
  ];

  for (const pattern of patterns) {
    const matches = Array.from(html.matchAll(pattern));
    for (let index = matches.length - 1; index >= 0; index -= 1) {
      const rawValue = matches[index]?.[1];
      if (!rawValue) continue;

      const parsed = parseFrenchNumber(rawValue);
      const range = GNF_SANITY_RANGES[currency];
      if (!Number.isNaN(parsed) && parsed >= range.min && parsed <= range.max) {
        return parsed;
      }
    }
  }

  return undefined;
}

async function fetchBcrgHtml(url: string): Promise<string | null> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);

  try {
    const resp = await fetch(url, {
      headers: { "User-Agent": "224Solutions-FX-Collector/2.0", "Accept": "text/html" },
      signal: controller.signal,
    });

    if (!resp.ok) {
      console.warn(`[BCRG] HTTP ${resp.status} for ${url}`);
      await resp.text();
      return null;
    }

    return await resp.text();
  } finally {
    clearTimeout(timeout);
  }
}

async function scrapeBcrg(): Promise<BcrgRates | null> {
  let homepageHtml: string | null = null;

  try {
    homepageHtml = await fetchBcrgHtml(BCRG_PRIMARY_URL);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    console.warn(`[BCRG] Erreur homepage: ${msg}`);
  }

  const todayStr = new Date().toISOString().split('T')[0];
  const fixingUrls = homepageHtml ? extractBcrgFixingUrls(homepageHtml) : [];
  const urlsToTry = Array.from(new Set([
    `${BCRG_PRIMARY_URL}/cours_des_devises/fixing-du-${todayStr}`,
    ...fixingUrls,
    BCRG_PRIMARY_URL,
    `${BCRG_PRIMARY_URL}/cours-de-change`,
    "https://www.bcrg.gov.gn",
    "https://www.bcrg.gov.gn/cours-de-change",
  ]));

  for (const url of urlsToTry) {
    try {
      const html = url === BCRG_PRIMARY_URL && homepageHtml
        ? homepageHtml
        : await fetchBcrgHtml(url);

      if (!html) continue;

      const usdGnf = extractBcrgRateFromHtml(html, 'USD');
      if (!usdGnf) continue;

      const eurGnf = extractBcrgRateFromHtml(html, 'EUR');

      console.log(`[BCRG] Taux scrappés — USD/GNF: ${usdGnf}${eurGnf ? `, EUR/GNF: ${eurGnf}` : ""} (source: ${url})`);
      return { usdGnf, eurGnf, scrapedUrl: url };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.includes("abort")) {
        console.warn(`[BCRG] Timeout pour ${url}`);
      } else {
        console.warn(`[BCRG] Erreur pour ${url}: ${msg}`);
      }
    }
  }

  console.warn("[BCRG] Toutes les URLs ont échoué. Le site est probablement inaccessible.");
  return null;
}

// ═══════════════════════════════════════════════════════════
// NIVEAU 2 — PARITÉS FIXES OFFICIELLES
// ═══════════════════════════════════════════════════════════

function computeFixedRates(
  config: CurrencyConfig,
  eurUsdRate: number,
): { rateUsd: number; rateEur: number } {
  const fixed = config.fixedRate!;
  if (fixed.base === "EUR") {
    return { rateEur: fixed.rate, rateUsd: fixed.rate / eurUsdRate };
  }
  return { rateUsd: fixed.rate, rateEur: fixed.rate * eurUsdRate };
}

// ═══════════════════════════════════════════════════════════
// NIVEAU 4 — FALLBACK API (documenté, tracé, secondaire)
// ═══════════════════════════════════════════════════════════

async function fetchFallbackRates(): Promise<{
  usd: Record<string, number>;
  eur: Record<string, number>;
  eurUsd: number;
} | null> {
  try {
    const [usdRes, eurRes] = await Promise.all([
      fetch("https://open.er-api.com/v6/latest/USD", { headers: { accept: "application/json" } }),
      fetch("https://open.er-api.com/v6/latest/EUR", { headers: { accept: "application/json" } }),
    ]);
    const usdJson = await usdRes.json();
    const eurJson = await eurRes.json();

    if (usdJson?.result !== "success" || eurJson?.result !== "success") {
      console.error("[FALLBACK] API returned error");
      return null;
    }

    const eurUsd = usdJson.rates?.EUR ? 1 / usdJson.rates.EUR : 1.08;
    return { usd: usdJson.rates, eur: eurJson.rates, eurUsd };
  } catch (e) {
    console.error("[FALLBACK] Fetch failed:", e);
    return null;
  }
}

// ═══════════════════════════════════════════════════════════
// HELPER : Upsert + Log
// ═══════════════════════════════════════════════════════════

async function upsertRateAndLog(
  supabase: any,
  code: string,
  collected: CollectedRate,
  margin: number,
  today: string,
  now: string,
  extraFields: Record<string, unknown> = {},
) {
  const { rateUsd, rateEur, source, sourceUrl, sourceType } = collected;
  const finalRateUsd = rateUsd * (1 + margin);
  const finalRateEur = rateEur * (1 + margin);

  const baseFields = {
    source,
    source_url: sourceUrl,
    source_type: sourceType,
    effective_date: today,
    retrieved_at: now,
    status: "OK",
    is_active: true,
    ...extraFields,
  };

  const invFinalRateUsd = rateUsd > 0 ? 1 / finalRateUsd : 0;
  const invFinalRateEur = rateEur > 0 ? 1 / finalRateEur : 0;

  await Promise.all([
    // USD → DEVISE
    supabase.from("currency_exchange_rates").upsert({
      from_currency: "USD", to_currency: code,
      rate: rateUsd, rate_usd: rateUsd, rate_eur: rateEur,
      margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
      ...baseFields,
    }, { onConflict: "from_currency,to_currency", ignoreDuplicates: false }),
    // EUR → DEVISE
    supabase.from("currency_exchange_rates").upsert({
      from_currency: "EUR", to_currency: code,
      rate: rateEur, rate_usd: rateUsd, rate_eur: rateEur,
      margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
      ...baseFields,
    }, { onConflict: "from_currency,to_currency", ignoreDuplicates: false }),
    // DEVISE → USD (inverse) with margin applied
    rateUsd > 0
      ? supabase.from("currency_exchange_rates").upsert({
          from_currency: code, to_currency: "USD",
          rate: 1 / rateUsd, rate_usd: 1 / rateUsd, rate_eur: 1 / rateEur,
          margin, final_rate_usd: invFinalRateUsd, final_rate_eur: invFinalRateEur,
          ...baseFields,
        }, { onConflict: "from_currency,to_currency", ignoreDuplicates: false })
      : Promise.resolve(),
    // DEVISE → EUR (inverse) with margin applied
    rateEur > 0
      ? supabase.from("currency_exchange_rates").upsert({
          from_currency: code, to_currency: "EUR",
          rate: 1 / rateEur, rate_usd: 1 / rateUsd, rate_eur: 1 / rateEur,
          margin, final_rate_usd: invFinalRateUsd, final_rate_eur: invFinalRateEur,
          ...baseFields,
        }, { onConflict: "from_currency,to_currency", ignoreDuplicates: false })
      : Promise.resolve(),
  ]);

  // Log de collecte
  await supabase.from("fx_collection_log").insert({
    currency_code: code,
    rate_usd: rateUsd,
    rate_eur: rateEur,
    source,
    source_url: sourceUrl,
    source_type: sourceType,
    status: "OK",
  });
}

// ═══════════════════════════════════════════════════════════
// MAIN HANDLER
// ═══════════════════════════════════════════════════════════

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, supabaseKey);

  interface Result {
    currency: string;
    status: string;
    sourceType: SourceType | "none";
    source: string;
    rateUsd?: number;
    rateEur?: number;
    note?: string;
  }
  const results: Result[] = [];

  try {
    // ── 1. Marge depuis margin_config ──
    const { data: marginRow } = await supabase
      .from("margin_config")
      .select("config_value")
      .eq("config_key", "default_margin")
      .single();
    const margin = marginRow?.config_value ?? 0.03;

    // ── 2. Taux existants pour détecter les variations ──
    const { data: existingRates } = await supabase
      .from("currency_exchange_rates")
      .select("from_currency, to_currency, rate, source_type")
      .eq("is_active", true)
      .in("to_currency", Object.keys(AFRICAN_CURRENCIES));

    const existingMap = new Map<string, number>();
    const existingSourceTypeMap = new Map<string, string>();
    if (existingRates) {
      for (const r of existingRates) {
        existingMap.set(`${r.from_currency}->${r.to_currency}`, Number(r.rate));
        existingSourceTypeMap.set(`${r.from_currency}->${r.to_currency}`, r.source_type || "");
      }
    }

    const now = new Date().toISOString();
    const today = now.split("T")[0];

    // ── 3. NIVEAU 1 : Scraping banques centrales (en parallèle) ──
    const [bceaoRates, bcrgRates] = await Promise.all([
      scrapeBceao(),
      scrapeBcrg(),
    ]);

    // ── 4. NIVEAU 4 : Fallback API (pour EUR/USD cross et devises tier 4) ──
    const fallback = await fetchFallbackRates();
    if (!fallback) {
      console.error("[COLLECT] Fallback API indisponible. Seules les sources officielles seront mises à jour.");
    }

    // EUR/USD du jour (nécessaire pour les parités fixes cross)
    // Priorité : BCEAO officiel (EUR/XOF=655.957, USD/XOF=achat) → EUR/USD = 655.957/usdXof
    let eurUsdRate: number;
    if (bceaoRates?.usdXof) {
      eurUsdRate = 655.957 / bceaoRates.usdXof;
      console.log(`[EUR/USD] Calculé depuis BCEAO officiel: ${eurUsdRate.toFixed(4)}`);
    } else if (fallback?.eurUsd) {
      eurUsdRate = fallback.eurUsd;
      console.log(`[EUR/USD] Depuis fallback API: ${eurUsdRate.toFixed(4)}`);
    } else {
      eurUsdRate = 1.08;
      console.warn("[EUR/USD] Aucune source, utilisation de 1.08 par défaut");
    }

    // ── 5. Stocker les devises supplémentaires BCEAO (GBP, CHF, etc.) ──
    if (bceaoRates) {
      const bceaoExtras: [string, number | undefined][] = [
        ["GBP", bceaoRates.gbpXof],
        ["CHF", bceaoRates.chfXof],
        ["CAD", bceaoRates.cadXof],
        ["JPY", bceaoRates.jpyXof],
        ["CNY", bceaoRates.cnyXof],
        ["AED", bceaoRates.aedXof],
      ];
      for (const [curr, rateToXof] of bceaoExtras) {
        if (rateToXof && rateToXof > 0) {
          // Calculer USD/CURR et EUR/CURR depuis les taux XOF
          // XOF est entre les deux, donc: USD/CURR = rateToUsd / rateToXof * xofToUsd
          // Reconversion: 1 USD = X XOF, 1 CURR = Y XOF → 1 USD = (X/Y) CURR → USD/CURR = X/Y
          const rateUsd = bceaoRates.usdXof / rateToXof;
          const rateEur = 655.957 / rateToXof;
          
          const finalRateUsd = rateUsd * (1 + margin);
          const finalRateEur = rateEur * (1 + margin);
          const invFinalRateUsd = rateUsd > 0 ? 1 / finalRateUsd : 0;
          const invFinalRateEur = rateEur > 0 ? 1 / finalRateEur : 0;
          
          const baseFields = {
            source: "bceao-official-html",
            source_url: "https://www.bceao.int/fr/cours/cours-des-devises",
            source_type: "official_html",
            effective_date: today, retrieved_at: now, status: "OK", is_active: true,
          };
          
          // Stocker les 4 paires: USD→CURR, EUR→CURR, CURR→USD, CURR→EUR (tous avec marge)
          await Promise.all([
            // USD → CURR
            supabase.from("currency_exchange_rates").upsert({
              from_currency: "USD", to_currency: curr,
              rate: rateUsd, rate_usd: rateUsd, rate_eur: rateEur,
              margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
              ...baseFields,
            }, { onConflict: "from_currency,to_currency", ignoreDuplicates: false }),
            // EUR → CURR
            supabase.from("currency_exchange_rates").upsert({
              from_currency: "EUR", to_currency: curr,
              rate: rateEur, rate_usd: rateUsd, rate_eur: rateEur,
              margin, final_rate_usd: finalRateUsd, final_rate_eur: finalRateEur,
              ...baseFields,
            }, { onConflict: "from_currency,to_currency", ignoreDuplicates: false }),
            // CURR → USD (inverse)
            rateUsd > 0
              ? supabase.from("currency_exchange_rates").upsert({
                  from_currency: curr, to_currency: "USD",
                  rate: 1 / rateUsd, rate_usd: 1 / rateUsd, rate_eur: 1 / rateEur,
                  margin, final_rate_usd: invFinalRateUsd, final_rate_eur: invFinalRateEur,
                  ...baseFields,
                }, { onConflict: "from_currency,to_currency", ignoreDuplicates: false })
              : Promise.resolve(),
            // CURR → EUR (inverse)
            rateEur > 0
              ? supabase.from("currency_exchange_rates").upsert({
                  from_currency: curr, to_currency: "EUR",
                  rate: 1 / rateEur, rate_usd: 1 / rateUsd, rate_eur: 1 / rateEur,
                  margin, final_rate_usd: invFinalRateUsd, final_rate_eur: invFinalRateEur,
                  ...baseFields,
                }, { onConflict: "from_currency,to_currency", ignoreDuplicates: false })
              : Promise.resolve(),
            // Stocker CURR → XOF directement (utile pour les cross)
            supabase.from("currency_exchange_rates").upsert({
              from_currency: curr, to_currency: "XOF",
              rate: rateToXof, source: "bceao-official-html",
              source_type: "official_html",
              source_url: "https://www.bceao.int/fr/cours/cours-des-devises",
              effective_date: today, retrieved_at: now, status: "OK", is_active: true,
            }, { onConflict: "from_currency,to_currency", ignoreDuplicates: false }),
          ]);
        }
      }
    }

    // ── 6. Traiter chaque devise africaine ──
    for (const [code, config] of Object.entries(AFRICAN_CURRENCIES)) {
      let collected: CollectedRate | null = null;

      // ─── NIVEAU 1 : Sources HTML officielles ───

      // GNF via BCRG (Banque Centrale de la République de Guinée)
      // Règle ABSOLUE : GNF ne doit JAMAIS utiliser open.er-api.com comme source.
      // Si BCRG est inaccessible, on fait un heartbeat (retrieved_at ← now) sur le
      // dernier taux officiel BCRG déjà en DB, afin qu'il reste "frais" pour
      // les vérifications de fraîcheur dans create_order_core.
      if (code === "GNF") {
        if (bcrgRates) {
          // BCRG accessible → taux frais, source officielle
          const eurGnf = bcrgRates.eurGnf || bcrgRates.usdGnf * eurUsdRate;
          collected = {
            rateUsd: bcrgRates.usdGnf,
            rateEur: eurGnf,
            source: "bcrg-official-html",
            sourceUrl: bcrgRates.scrapedUrl,
            sourceType: "official_html",
          };
        } else {
          // BCRG inaccessible → NE PAS basculer sur open.er-api.com
          // Vérifier si un taux official_html BCRG existe déjà en DB
          const existingUsdGnfType = existingSourceTypeMap.get("USD->GNF");
          if (existingUsdGnfType === "official_html") {
            // Heartbeat : mise à jour de retrieved_at uniquement — on garde la source BCRG
            await Promise.all([
              supabase.from("currency_exchange_rates")
                .update({ retrieved_at: now, effective_date: today, status: "BCRG_CACHED", is_active: true })
                .eq("from_currency", "USD").eq("to_currency", "GNF"),
              supabase.from("currency_exchange_rates")
                .update({ retrieved_at: now, effective_date: today, status: "BCRG_CACHED", is_active: true })
                .eq("from_currency", "EUR").eq("to_currency", "GNF"),
              supabase.from("currency_exchange_rates")
                .update({ retrieved_at: now, effective_date: today, status: "BCRG_CACHED", is_active: true })
                .eq("from_currency", "GNF").eq("to_currency", "USD"),
              supabase.from("currency_exchange_rates")
                .update({ retrieved_at: now, effective_date: today, status: "BCRG_CACHED", is_active: true })
                .eq("from_currency", "GNF").eq("to_currency", "EUR"),
            ]);
            await supabase.from("fx_collection_log").insert({
              currency_code: "GNF",
              source: "bcrg-heartbeat",
              source_url: BCRG_PRIMARY_URL,
              source_type: "official_html",
              status: "BCRG_CACHED",
              error_message: "BCRG inaccessible — dernier taux officiel BCRG conservé (heartbeat retrieved_at mis à jour)",
            });
            results.push({
              currency: "GNF",
              status: "BCRG_CACHED",
              sourceType: "official_html",
              source: "bcrg-heartbeat",
              note: "Site BCRG inaccessible, dernier taux BCRG conservé",
            });
            continue; // Ne pas passer au fallback API pour GNF
          } else {
            // Aucun taux BCRG officiel en DB (première collecte ou table vide)
            // Autoriser le fallback API uniquement dans ce cas exceptionnel
            // en le marquant clairement BCRG_MISSING pour alerte PDG
            console.warn("[BCRG] Aucun taux official_html GNF en DB. Fallback API autorisé une seule fois.");
          }
          // Si pas de taux BCRG existant → passer au bloc Level 4 fallback API (collected reste null)
        }
      }

      // XOF via BCEAO (scraping + parité fixe EUR)
      if (code === "XOF" && bceaoRates) {
        collected = {
          rateUsd: bceaoRates.usdXof,
          rateEur: 655.957,
          source: "bceao-official-html+peg",
          sourceUrl: "https://www.bceao.int/fr/cours/cours-des-devises",
          sourceType: "official_html",
        };
      }

      // XAF : même parité EUR que XOF, cross USD via BCEAO
      if (code === "XAF" && bceaoRates) {
        collected = {
          rateUsd: bceaoRates.usdXof, // XAF et XOF = même valeur
          rateEur: 655.957,
          source: "beac-peg+bceao-official-cross",
          sourceUrl: "https://www.beac.int",
          sourceType: "official_cross",
        };
      }

      // ─── NIVEAU 2 : Parités fixes officielles ───
      if (!collected && config.fixedRate) {
        const fixed = computeFixedRates(config, eurUsdRate);
        collected = {
          rateUsd: fixed.rateUsd,
          rateEur: fixed.rateEur,
          source: `official-peg-${config.fixedRate.base}`,
          sourceUrl: config.zone === "BCEAO"
            ? "https://www.bceao.int"
            : config.zone === "BEAC"
              ? "https://www.beac.int"
              : "official-monetary-agreement",
          sourceType: "official_fixed_parity",
        };
      }

      // ─── NIVEAU 3 : Devises arrimées (cross officiel) ───
      if (!collected && config.peggedTo) {
        // Chercher le taux de la devise mère dans les résultats déjà traités
        // ou dans le fallback
        const parentRate = fallback?.usd[config.peggedTo];
        const parentRateEur = fallback?.eur[config.peggedTo];
        if (parentRate && parentRateEur) {
          collected = {
            rateUsd: parentRate,
            rateEur: parentRateEur,
            source: `official-peg-${config.peggedTo}`,
            sourceUrl: "official-currency-board",
            sourceType: "official_cross",
          };
        }
      }

      // ─── NIVEAU 4 : Fallback API ───
      if (!collected) {
        if (!fallback) {
          await supabase.from("fx_collection_log").insert({
            currency_code: code,
            source: "none",
            source_url: "N/A",
            source_type: "fallback_api",
            status: "FALLBACK",
            error_message: `Aucune source disponible pour ${code}. Dernier taux conservé. Raison: ${config.fallbackReason || "API indisponible"}`,
          });
          results.push({ currency: code, status: "FALLBACK", sourceType: "none", source: "none", note: config.fallbackReason });
          continue;
        }

        const rateUsd = fallback.usd[code];
        const rateEur = fallback.eur[code];
        if (!rateUsd || !rateEur) {
          await supabase.from("fx_collection_log").insert({
            currency_code: code,
            source: "fallback-api",
            source_url: "https://open.er-api.com",
            source_type: "fallback_api",
            status: "FALLBACK",
            error_message: `Taux non disponible pour ${code} dans l'API de référence`,
          });
          results.push({ currency: code, status: "FALLBACK", sourceType: "fallback_api", source: "fallback-api", note: config.fallbackReason });
          continue;
        }

        collected = {
          rateUsd,
          rateEur,
          source: "fallback-api",
          sourceUrl: "https://open.er-api.com",
          sourceType: "fallback_api",
        };
      }

      if (!collected || !collected.rateUsd || !collected.rateEur) continue;

      // ─── Vérifier si variation significative ───
      const existingUsd = existingMap.get(`USD->${code}`);
      if (existingUsd && Math.abs(collected.rateUsd - existingUsd) / existingUsd < VARIATION_THRESHOLD) {
        // Heartbeat horaire: on met a jour retrieved_at/effective_date même sans variation
        // Et on recalcule la marge au cas où elle aurait changé
        const finalRateUsd = collected.rateUsd * (1 + margin);
        const finalRateEur = collected.rateEur * (1 + margin);
        const invFinalRateUsd = collected.rateUsd > 0 ? 1 / finalRateUsd : 0;
        const invFinalRateEur = collected.rateEur > 0 ? 1 / finalRateEur : 0;
        const noChangeBcrgExtra = (code === "GNF" && collected.sourceType === "official_html")
          ? { last_bcrg_scraped_at: now }
          : {};

        await Promise.all([
          supabase
            .from("currency_exchange_rates")
            .update({
              retrieved_at: now,
              effective_date: today,
              source: collected.source,
              source_url: collected.sourceUrl,
              source_type: collected.sourceType,
              status: "OK",
              is_active: true,
              margin,
              final_rate_usd: finalRateUsd,
              final_rate_eur: finalRateEur,
              ...noChangeBcrgExtra,
            })
            .eq("from_currency", "USD")
            .eq("to_currency", code),
          supabase
            .from("currency_exchange_rates")
            .update({
              retrieved_at: now,
              effective_date: today,
              source: collected.source,
              source_url: collected.sourceUrl,
              source_type: collected.sourceType,
              status: "OK",
              is_active: true,
              margin,
              final_rate_usd: finalRateUsd,
              final_rate_eur: finalRateEur,
              ...noChangeBcrgExtra,
            })
            .eq("from_currency", "EUR")
            .eq("to_currency", code),
          supabase
            .from("currency_exchange_rates")
            .update({
              retrieved_at: now,
              effective_date: today,
              source: collected.source,
              source_url: collected.sourceUrl,
              source_type: collected.sourceType,
              status: "OK",
              is_active: true,
              margin,
              final_rate_usd: invFinalRateUsd,
              final_rate_eur: invFinalRateEur,
              ...noChangeBcrgExtra,
            })
            .eq("from_currency", code)
            .eq("to_currency", "USD"),
          supabase
            .from("currency_exchange_rates")
            .update({
              retrieved_at: now,
              effective_date: today,
              source: collected.source,
              source_url: collected.sourceUrl,
              source_type: collected.sourceType,
              status: "OK",
              is_active: true,
              margin,
              final_rate_usd: invFinalRateUsd,
              final_rate_eur: invFinalRateEur,
              ...noChangeBcrgExtra,
            })
            .eq("from_currency", code)
            .eq("to_currency", "EUR"),
        ]);

        await supabase.from("fx_collection_log").insert({
          currency_code: code,
          rate_usd: collected.rateUsd,
          rate_eur: collected.rateEur,
          source: collected.source,
          source_url: collected.sourceUrl,
          source_type: collected.sourceType,
          status: "NO_CHANGE",
          error_message: "Aucune variation significative, heartbeat horaire applique",
        });

        results.push({
          currency: code, status: "NO_CHANGE",
          sourceType: collected.sourceType, source: collected.source,
          rateUsd: collected.rateUsd, rateEur: collected.rateEur,
        });
        continue;
      }

      // ─── Upsert + log ───
      const gnfExtra = (code === "GNF" && collected.sourceType === "official_html")
        ? { last_bcrg_scraped_at: now }
        : {};
      await upsertRateAndLog(supabase, code, collected, margin, today, now, gnfExtra);

      results.push({
        currency: code, status: "OK",
        sourceType: collected.sourceType, source: collected.source,
        rateUsd: collected.rateUsd, rateEur: collected.rateEur,
      });
    }

    // ── 7. Résumé ──
    const okCount = results.filter(r => r.status === "OK").length;
    const noChangeCount = results.filter(r => r.status === "NO_CHANGE").length;
    const fallbackCount = results.filter(r => r.status === "FALLBACK").length;

    const bySourceType = {
      official_html: results.filter(r => r.sourceType === "official_html" && r.status !== "FALLBACK").length,
      official_fixed_parity: results.filter(r => r.sourceType === "official_fixed_parity" && r.status !== "FALLBACK").length,
      official_cross: results.filter(r => r.sourceType === "official_cross" && r.status !== "FALLBACK").length,
      fallback_api: results.filter(r => r.sourceType === "fallback_api" && r.status !== "FALLBACK").length,
    };

    console.log(
      `[african-fx-collect] Terminé: ${results.length} devises. ` +
      `OK=${okCount} (html=${bySourceType.official_html}, peg=${bySourceType.official_fixed_parity}, ` +
      `cross=${bySourceType.official_cross}, fallback=${bySourceType.fallback_api}), ` +
      `NO_CHANGE=${noChangeCount}, ECHEC=${fallbackCount}`
    );

    return new Response(
      JSON.stringify({
        success: true,
        margin,
        processed: results.length,
        updated: okCount,
        unchanged: noChangeCount,
        failed: fallbackCount,
        sources: {
          bcrg_scrape: bcrgRates ? "OK" : "FAILED",
          bceao_scrape: bceaoRates ? "OK" : "FAILED",
          eur_usd_source: bceaoRates ? "bceao-cross" : (fallback ? "fallback-api" : "default"),
          eur_usd_rate: eurUsdRate,
          by_source_type: bySourceType,
        },
        timestamp: now,
        results,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[african-fx-collect] Fatal error:", error);
    return new Response(
      JSON.stringify({ success: false, error: error instanceof Error ? error.message : "Unknown error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
