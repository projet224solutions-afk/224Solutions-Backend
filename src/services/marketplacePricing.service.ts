/**
 * MARKETPLACE PRICING SERVICE
 * Service centralisé pour la logique de prix et devises du marketplace.
 *
 * Réutilise EXCLUSIVEMENT le système FX interne existant :
 *   - table currency_exchange_rates (alimentée par african-fx-collect)
 *   - getInternalFxRate() de supabase/functions/_shared/fx-internal.ts
 *   - marge 3% déjà incluse dans les taux de la table
 *
 * Ne crée PAS un deuxième système de taux.
 * Ne fait PAS d'appels API externes.
 * Le backend recalcule TOUJOURS les prix depuis la DB (ne jamais faire confiance au frontend).
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { cache } from '../config/redis.js';

// ─────────────────────────────────────────────────────────────────
// TYPES
// ─────────────────────────────────────────────────────────────────

export interface FxResult {
  rate: number;
  source: 'identity' | 'table-direct' | 'table-inverse' | 'table-usd-pivot' | 'table-gnf-pivot' | 'table-eur-via-usd-gnf' | 'table-eur-via-usd-gnf-inverse';
  fetched_at: string;
}

export interface ConvertedPrice {
  originalAmount: number;
  originalCurrency: string;
  convertedAmount: number;
  convertedCurrency: string;
  rate: number;
  rateSource: string;
  rateFetchedAt: string;
  isConverted: boolean;
  isEstimated: boolean;
}

export interface ProductOriginalPrice {
  productId: string;
  amount: number;
  currency: string;
  comparePrice: number | null;
  vendorId: string;
  vendorCurrency: string;
  productType: 'physical' | 'digital' | 'service';
}

export interface CommissionResult {
  grossAmount: number;
  currency: string;
  feePercent: number;
  feeAmount: number;
  netAmount: number;
}

export interface CheckoutRateLock {
  id: string;
  fromCurrency: string;
  toCurrency: string;
  originalAmount: number;
  convertedAmount: number;
  rate: number;
  rateSource: string;
  lockedAt: string;
  expiresAt: string;
  isExpired: boolean;
  remainingMs: number;
}

export interface OrderFinancialSummary {
  // Côté vendeur (devise originale)
  sellerCurrency: string;
  totalOriginalAmount: number;
  platformFeePercent: number;
  platformFeeAmount: number;
  sellerNetAmount: number;
  // Côté acheteur
  buyerCurrency: string;
  totalPaidAmount: number;
  // FX
  isCrossCurrency: boolean;
  exchangeRate: number;
  exchangeRateSource: string;
  rateFetchedAt: string | null;
  rateLockExpiresAt: string | null;
}

// Commission VENDEUR par type de produit (%).
// MODÈLE « frais acheteur » (validé PDG, 2026-06-18) : la plateforme se rémunère via le FRAIS
// ACHETEUR (system_settings.purchase_fee_percent = 5%), prélevé EN PLUS sur l'acheteur. Le VENDEUR
// reçoit donc l'INTÉGRAL du prix produit → commission vendeur = 0. (Remettre une valeur > 0 ici
// rétablirait un prélèvement côté vendeur.)
export const PLATFORM_FEE_RATES: Record<string, number> = {
  physical: 0,
  digital:  0,
  service:  0,
  default:  0,
};

// Durée de validité d'un taux verrouillé (ms)
const RATE_LOCK_DURATION_MS = 8 * 60 * 1000; // 8 minutes

// Devises sans décimales
const NO_DECIMAL_CURRENCIES = new Set(['GNF', 'XOF', 'XAF', 'JPY', 'KRW', 'VND', 'CLP']);

// Devise du PAYS du vendeur = source FIABLE du prix produit (Guinée→GNF, Sénégal/UEMOA→XOF,
// CEMAC→XAF). Le champ `currency`/`seller_currency` du produit vaut toujours GNF par défaut, et
// `shop_currency` est parfois faux (ex. vendeur Guinée avec shop=EUR) → on déduit du pays.
// ⚠️ DOIT rester synchronisé avec le frontend `getCurrencyForCountry` (src/data/countryMappings.ts)
// ET la fonction SQL `resolve_country_currency` (migration 20260607180000). Les trois donnent le
// MÊME résultat pour que affichage = stockage = achat ne divergent jamais.
const COUNTRY_TO_CURRENCY: Record<string, string> = {
  'guinée': 'GNF', 'guinee': 'GNF', 'guinea': 'GNF', 'gn': 'GNF',
  'sénégal': 'XOF', 'senegal': 'XOF', 'sn': 'XOF',
  'mali': 'XOF', 'ml': 'XOF', "côte d'ivoire": 'XOF', "cote d'ivoire": 'XOF', 'ivory coast': 'XOF', 'ci': 'XOF',
  'burkina faso': 'XOF', 'bf': 'XOF', 'niger': 'XOF', 'ne': 'XOF', 'togo': 'XOF', 'tg': 'XOF',
  'bénin': 'XOF', 'benin': 'XOF', 'bj': 'XOF', 'guinée-bissau': 'XOF', 'guinea-bissau': 'XOF', 'gw': 'XOF',
  'cameroun': 'XAF', 'cameroon': 'XAF', 'cm': 'XAF', 'gabon': 'XAF', 'ga': 'XAF', 'tchad': 'XAF', 'chad': 'XAF', 'td': 'XAF',
  'congo': 'XAF', 'cg': 'XAF', 'centrafrique': 'XAF', 'cf': 'XAF', 'guinée équatoriale': 'XAF', 'guinee equatoriale': 'XAF', 'gq': 'XAF',
  'sierra leone': 'SLL', 'sl': 'SLL', 'liberia': 'LRD', 'libéria': 'LRD', 'lr': 'LRD',
  'gambie': 'GMD', 'gambia': 'GMD', 'gm': 'GMD', 'nigeria': 'NGN', 'nigéria': 'NGN', 'ng': 'NGN', 'ghana': 'GHS', 'gh': 'GHS',
  'rd congo': 'CDF', 'rdc': 'CDF', 'congo-kinshasa': 'CDF', 'cd': 'CDF',
  'maroc': 'MAD', 'morocco': 'MAD', 'ma': 'MAD', 'tunisie': 'TND', 'tunisia': 'TND', 'tn': 'TND',
  'algérie': 'DZD', 'algeria': 'DZD', 'dz': 'DZD', 'égypte': 'EGP', 'egypt': 'EGP', 'eg': 'EGP',
  'kenya': 'KES', 'ke': 'KES', 'tanzanie': 'TZS', 'tanzania': 'TZS', 'tz': 'TZS',
  'ouganda': 'UGX', 'uganda': 'UGX', 'ug': 'UGX', 'rwanda': 'RWF', 'rw': 'RWF',
  'éthiopie': 'ETB', 'ethiopia': 'ETB', 'et': 'ETB', 'afrique du sud': 'ZAR', 'south africa': 'ZAR', 'za': 'ZAR',
  'france': 'EUR', 'fr': 'EUR', 'belgique': 'EUR', 'belgium': 'EUR', 'be': 'EUR',
  'suisse': 'CHF', 'switzerland': 'CHF', 'ch': 'CHF', 'canada': 'CAD', 'ca': 'CAD',
  'états-unis': 'USD', 'united states': 'USD', 'usa': 'USD', 'us': 'USD',
  'royaume-uni': 'GBP', 'united kingdom': 'GBP', 'uk': 'GBP', 'gb': 'GBP',
  'chine': 'CNY', 'china': 'CNY', 'cn': 'CNY', 'japon': 'JPY', 'japan': 'JPY', 'jp': 'JPY',
  'inde': 'INR', 'india': 'INR', 'in': 'INR', 'brésil': 'BRL', 'brazil': 'BRL', 'br': 'BRL',
  'turquie': 'TRY', 'turkey': 'TRY', 'tr': 'TRY',
};
function currencyFromCountry(country?: string | null): string {
  return COUNTRY_TO_CURRENCY[String(country || '').trim().toLowerCase()] || 'GNF';
}

// ─────────────────────────────────────────────────────────────────
// FX INTERNE — réutilise la même logique que wallet-transfer
// ─────────────────────────────────────────────────────────────────

/**
 * Récupère le taux de change depuis la table currency_exchange_rates.
 * Marge 3% déjà incluse. Aucun appel API externe.
 * Supporte: direct, inverse, pivot USD.
 */
/**
 * Lecture des taux AVEC cache (couche scalabilité). Les taux changent au plus toutes les
 * ~5 min (refreshBcrgOnly) — un cache court (45s) supprime des milliers de lectures DB
 * répétées (prix, conversions) à grande échelle, sans risque : la prise de taux MONÉTAIRE
 * réelle reste l'RPC atomique create_order_core (qui relit + vérifie la fraîcheur BCRG).
 * Best-effort : si Redis est absent, lecture DB directe (comportement inchangé).
 */
export async function getInternalFxRate(from: string, to: string): Promise<FxResult> {
  const f = from.toUpperCase();
  const t = to.toUpperCase();
  if (f === t) return { rate: 1, source: 'identity', fetched_at: new Date().toISOString() };
  return cache.getOrSet(`fx:${f}:${t}`, 45, () => getInternalFxRateUncached(f, t));
}

async function getInternalFxRateUncached(
  from: string,
  to: string,
): Promise<FxResult> {
  const f = from.toUpperCase();
  const t = to.toUpperCase();

  if (f === t) {
    return { rate: 1, source: 'identity', fetched_at: new Date().toISOString() };
  }

  // 1. Paire directe
  const { data: direct } = await supabaseAdmin
    .from('currency_exchange_rates')
    .select('rate, retrieved_at')
    .eq('from_currency', f)
    .eq('to_currency', t)
    .eq('is_active', true)
    .maybeSingle();

  if (direct?.rate && Number(direct.rate) > 0) {
    return {
      rate: Number(direct.rate),
      source: 'table-direct',
      fetched_at: direct.retrieved_at || new Date().toISOString(),
    };
  }

  // 2. Paire inverse
  const { data: inverse } = await supabaseAdmin
    .from('currency_exchange_rates')
    .select('rate, retrieved_at')
    .eq('from_currency', t)
    .eq('to_currency', f)
    .eq('is_active', true)
    .maybeSingle();

  if (inverse?.rate && Number(inverse.rate) > 0) {
    return {
      rate: 1 / Number(inverse.rate),
      source: 'table-inverse',
      fetched_at: inverse.retrieved_at || new Date().toISOString(),
    };
  }

  // 3. Pivot USD: (USD→to) / (USD→from)
  const [{ data: fromUsd }, { data: toUsd }] = await Promise.all([
    supabaseAdmin.from('currency_exchange_rates')
      .select('rate, final_rate_eur').eq('from_currency', 'USD').eq('to_currency', f).eq('is_active', true)
      .order('retrieved_at', { ascending: false }).maybeSingle(),
    supabaseAdmin.from('currency_exchange_rates')
      .select('rate, final_rate_eur').eq('from_currency', 'USD').eq('to_currency', t).eq('is_active', true)
      .order('retrieved_at', { ascending: false }).maybeSingle(),
  ]);

  if (fromUsd?.rate && Number(fromUsd.rate) > 0 && toUsd?.rate && Number(toUsd.rate) > 0) {
    return {
      rate: Number(toUsd.rate) / Number(fromUsd.rate),
      source: 'table-usd-pivot',
      fetched_at: new Date().toISOString(),
    };
  }

  // 3.5. Pivot EUR via final_rate_eur stocké dans le row USD→GNF (collecté par BCRG)
  // Utilisé quand EUR→GNF direct manque mais que BCRG a stocké final_rate_eur dans le row USD/GNF
  if (t === 'GNF' && f === 'EUR') {
    const { data: usdToGnfRow } = await supabaseAdmin.from('currency_exchange_rates')
      .select('final_rate_eur, retrieved_at')
      .eq('from_currency', 'USD').eq('to_currency', 'GNF').eq('is_active', true)
      .order('retrieved_at', { ascending: false }).maybeSingle();
    if (usdToGnfRow?.final_rate_eur && Number(usdToGnfRow.final_rate_eur) > 0) {
      return {
        rate: Number(usdToGnfRow.final_rate_eur),
        source: 'table-eur-via-usd-gnf',
        fetched_at: usdToGnfRow.retrieved_at || new Date().toISOString(),
      };
    }
  }
  if (f === 'GNF' && t === 'EUR') {
    const { data: usdToGnfRow } = await supabaseAdmin.from('currency_exchange_rates')
      .select('final_rate_eur, retrieved_at')
      .eq('from_currency', 'USD').eq('to_currency', 'GNF').eq('is_active', true)
      .order('retrieved_at', { ascending: false }).maybeSingle();
    if (usdToGnfRow?.final_rate_eur && Number(usdToGnfRow.final_rate_eur) > 0) {
      return {
        rate: 1 / Number(usdToGnfRow.final_rate_eur),
        source: 'table-eur-via-usd-gnf-inverse',
        fetched_at: usdToGnfRow.retrieved_at || new Date().toISOString(),
      };
    }
  }

  // 4. GNF bridge: f→GNF→t (fallback pour les devises sans taux USD, ex: SLL)
  if (f !== 'GNF' && t !== 'GNF') {
    const [
      { data: fToGnf },
      { data: gnfToF },
      { data: gnfToT },
      { data: tToGnf },
    ] = await Promise.all([
      supabaseAdmin.from('currency_exchange_rates').select('rate').eq('from_currency', f).eq('to_currency', 'GNF').eq('is_active', true).maybeSingle(),
      supabaseAdmin.from('currency_exchange_rates').select('rate').eq('from_currency', 'GNF').eq('to_currency', f).eq('is_active', true).maybeSingle(),
      supabaseAdmin.from('currency_exchange_rates').select('rate').eq('from_currency', 'GNF').eq('to_currency', t).eq('is_active', true).maybeSingle(),
      supabaseAdmin.from('currency_exchange_rates').select('rate').eq('from_currency', t).eq('to_currency', 'GNF').eq('is_active', true).maybeSingle(),
    ]);

    const fromToGnfRate = fToGnf?.rate && Number(fToGnf.rate) > 0
      ? Number(fToGnf.rate)
      : gnfToF?.rate && Number(gnfToF.rate) > 0
        ? 1 / Number(gnfToF.rate)
        : null;

    const gnfToToRate = gnfToT?.rate && Number(gnfToT.rate) > 0
      ? Number(gnfToT.rate)
      : tToGnf?.rate && Number(tToGnf.rate) > 0
        ? 1 / Number(tToGnf.rate)
        : null;

    if (fromToGnfRate !== null && gnfToToRate !== null) {
      return {
        rate: fromToGnfRate * gnfToToRate,
        source: 'table-gnf-pivot',
        fetched_at: new Date().toISOString(),
      };
    }
  }

  throw new Error(`Taux de change introuvable pour ${f}→${t}. Vérifiez que les taux sont collectés.`);
}

// ─────────────────────────────────────────────────────────────────
// 1. getBuyerCurrency — devise de l'acheteur
// ─────────────────────────────────────────────────────────────────

/**
 * Retourne la devise verrouillée de l'acheteur depuis son wallet actif ou son profil.
 * Source de vérité : DB. Ne jamais faire confiance au frontend.
 */
export async function getBuyerCurrency(userId: string): Promise<string> {
  try {
    // Priorité 1: wallet actif
    const { data: wallet } = await supabaseAdmin
      .from('wallets')
      .select('currency')
      .eq('user_id', userId)
      .eq('wallet_status', 'active')
      .maybeSingle();

    if (wallet?.currency) return wallet.currency;

    // Priorité 2: profil
    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('detected_currency, detected_country, country')
      .eq('id', userId)
      .maybeSingle();

    if (profile?.detected_currency && profile.detected_currency !== '') {
      return profile.detected_currency;
    }

    // Fallback GNF
    return 'GNF';
  } catch (err) {
    logger.warn(`getBuyerCurrency: erreur pour ${userId}:`, err);
    return 'GNF';
  }
}

// ─────────────────────────────────────────────────────────────────
// 2. getSellerCurrency — devise du vendeur/boutique
// ─────────────────────────────────────────────────────────────────

/**
 * Retourne la devise verrouillée de la boutique.
 * Source de vérité : vendors.shop_currency (jamais le frontend).
 */
export async function getSellerCurrency(vendorId: string): Promise<string> {
  try {
    const { data: vendor } = await supabaseAdmin
      .from('vendors')
      .select('shop_currency, country, seller_country_code')
      .eq('id', vendorId)
      .eq('is_active', true)
      .maybeSingle();

    if (vendor?.shop_currency) return vendor.shop_currency;

    // Fallback depuis le pays
    const countryCode = vendor?.seller_country_code
      || (vendor?.country && vendor.country.length <= 3 ? vendor.country : null);

    if (countryCode) {
      const { data: fn } = await supabaseAdmin
        .rpc('get_currency_for_country', { p_country_code: countryCode });
      if (fn) return fn as string;
    }

    return 'GNF';
  } catch (err) {
    logger.warn(`getSellerCurrency: erreur pour ${vendorId}:`, err);
    return 'GNF';
  }
}

// ─────────────────────────────────────────────────────────────────
// 3. getProductOriginalPrice — prix original depuis la DB
// ─────────────────────────────────────────────────────────────────

/**
 * Retourne le prix original du produit DEPUIS LA DB.
 * Ne jamais faire confiance au prix envoyé par le frontend.
 */
export async function getProductOriginalPrice(productId: string): Promise<ProductOriginalPrice | null> {
  try {
    // LEFT JOIN sur vendors (pas !inner) : un produit valide ne doit pas échouer
    // simplement parce que son vendeur manque dans la table vendors.
    const { data, error } = await supabaseAdmin
      .from('products')
      .select(`
        id, price, compare_price,
        original_price_currency, seller_currency,
        vendor_id, is_active,
        vendors(shop_currency, country, seller_country_code)
      `)
      .eq('id', productId)
      .maybeSingle();

    if (error) {
      logger.error(`getProductOriginalPrice: erreur DB pour ${productId}: ${error.message}`);
      return null;
    }

    if (!data) {
      logger.warn(`[PRICING] Produit ${productId} supprimé ou inexistant`);
      return null;
    }

    if (!data.is_active) {
      logger.warn(`[PRICING] Produit ${productId} existe mais est inactif (is_active=false)`);
      return null;
    }

    const vendor = Array.isArray((data as any).vendors)
      ? (data as any).vendors[0]
      : (data as any).vendors;

    const sellerCurrency = data.seller_currency
      || vendor?.shop_currency
      || 'GNF';

    if (!vendor) {
      logger.warn(`[PRICING] Produit ${productId} : vendeur ${data.vendor_id} absent de la table vendors — devise fallback: ${sellerCurrency}`);
    }

    const productType: 'physical' | 'digital' | 'service' = 'physical';

    // DEVISE DU PRIX = devise du PAYS du vendeur (source fiable) : Guinée→GNF, Sénégal→XOF.
    // PAS shop_currency (parfois faux, ex. Fusion=EUR) NI le champ produit (toujours GNF). Ainsi
    // l'ACHAT débite le bon montant, cohérent avec l'affichage. Conversion → devise acheteur au BCRG.
    const priceCurrency = currencyFromCountry(vendor?.country);

    return {
      productId: data.id,
      amount: Number(data.price),
      currency: priceCurrency,
      comparePrice: data.compare_price ? Number(data.compare_price) : null,
      vendorId: data.vendor_id,
      vendorCurrency: sellerCurrency,
      productType,
    };
  } catch (err: any) {
    logger.error(`getProductOriginalPrice: exception pour ${productId}: ${err.message}`);
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────
// 4. convertPriceForBuyer — conversion FX
// ─────────────────────────────────────────────────────────────────

/**
 * Convertit un prix de la devise vendeur vers la devise acheteur.
 * Si même devise → pas de conversion, taux = 1.
 * Utilise getInternalFxRate() = même logique que wallet-transfer.
 */
export async function convertPriceForBuyer(
  amount: number,
  fromCurrency: string,
  buyerCurrency: string,
): Promise<ConvertedPrice> {
  const from = fromCurrency.toUpperCase();
  const to   = buyerCurrency.toUpperCase();

  if (from === to) {
    return {
      originalAmount:    amount,
      originalCurrency:  from,
      convertedAmount:   amount,
      convertedCurrency: to,
      rate:              1,
      rateSource:        'identity',
      rateFetchedAt:     new Date().toISOString(),
      isConverted:       false,
      isEstimated:       false,
    };
  }

  try {
    const fx = await getInternalFxRate(from, to);
    const rawConverted = amount * fx.rate;
    const convertedAmount = NO_DECIMAL_CURRENCIES.has(to)
      ? Math.round(rawConverted)
      : Math.round(rawConverted * 100) / 100;

    return {
      originalAmount:    amount,
      originalCurrency:  from,
      convertedAmount,
      convertedCurrency: to,
      rate:              fx.rate,
      rateSource:        fx.source,
      rateFetchedAt:     fx.fetched_at,
      isConverted:       true,
      isEstimated:       true, // indicatif jusqu'au paiement
    };
  } catch (err: any) {
    // Aucun taux disponible → pas de conversion, signaler au frontend
    logger.warn(`convertPriceForBuyer: taux ${from}→${to} introuvable: ${err.message}`);
    throw new Error(`Conversion ${from}→${to} indisponible: aucun taux dans la base`);
  }
}

// ─────────────────────────────────────────────────────────────────
// 5. buildDisplayPrice — données complètes pour l'interface
// ─────────────────────────────────────────────────────────────────

/**
 * Retourne toutes les données de prix pour l'affichage d'un produit.
 * Appelé par le endpoint GET /api/marketplace/price-preview.
 */
export async function buildDisplayPrice(
  productId: string,
  buyerUserId?: string,
): Promise<{
  originalAmount: number;
  originalCurrency: string;
  displayAmount: number;
  displayCurrency: string;
  comparePrice: number | null;
  isConverted: boolean;
  isEstimated: boolean;
  rate: number;
  rateSource: string;
  rateFetchedAt: string;
  noRateAvailable: boolean;
}> {
  const product = await getProductOriginalPrice(productId);

  if (!product) {
    throw new Error('Produit introuvable');
  }

  const buyerCurrency = buyerUserId
    ? await getBuyerCurrency(buyerUserId)
    : product.currency;

  try {
    const converted = await convertPriceForBuyer(
      product.amount,
      product.currency,
      buyerCurrency,
    );

    return {
      originalAmount:    converted.originalAmount,
      originalCurrency:  converted.originalCurrency,
      displayAmount:     converted.convertedAmount,
      displayCurrency:   converted.convertedCurrency,
      comparePrice:      product.comparePrice,
      isConverted:       converted.isConverted,
      isEstimated:       converted.isEstimated,
      rate:              converted.rate,
      rateSource:        converted.rateSource,
      rateFetchedAt:     converted.rateFetchedAt,
      noRateAvailable:   false,
    };
  } catch {
    // Pas de taux → afficher le prix original, désactiver paiement international
    return {
      originalAmount:    product.amount,
      originalCurrency:  product.currency,
      displayAmount:     product.amount,
      displayCurrency:   product.currency,
      comparePrice:      product.comparePrice,
      isConverted:       false,
      isEstimated:       false,
      rate:              1,
      rateSource:        'unavailable',
      rateFetchedAt:     new Date().toISOString(),
      noRateAvailable:   true,
    };
  }
}

// ─────────────────────────────────────────────────────────────────
// 6. lockCheckoutRate — verrouillage du taux au paiement
// ─────────────────────────────────────────────────────────────────

/**
 * Verrouille le taux au moment du checkout (8 minutes).
 * Retourne le lock créé ou le lock actif existant.
 */
export async function lockCheckoutRate(
  buyerId: string,
  vendorId: string,
  fromCurrency: string,
  toCurrency: string,
  originalAmount: number,
): Promise<CheckoutRateLock> {
  const from = fromCurrency.toUpperCase();
  const to   = toCurrency.toUpperCase();

  // Vérifier si un lock actif existe déjà pour ce couple
  const { data: existing } = await supabaseAdmin
    .from('checkout_rate_locks')
    .select('*')
    .eq('buyer_id', buyerId)
    .eq('vendor_id', vendorId)
    .eq('from_currency', from)
    .eq('to_currency', to)
    .eq('status', 'active')
    .gt('expires_at', new Date().toISOString())
    .maybeSingle();

  if (existing) {
    const remainingMs = new Date(existing.expires_at).getTime() - Date.now();
    return {
      id:              existing.id,
      fromCurrency:    existing.from_currency,
      toCurrency:      existing.to_currency,
      originalAmount:  Number(existing.original_amount),
      convertedAmount: Number(existing.converted_amount),
      rate:            Number(existing.exchange_rate),
      rateSource:      existing.rate_source || '',
      lockedAt:        existing.locked_at,
      expiresAt:       existing.expires_at,
      isExpired:       false,
      remainingMs,
    };
  }

  // Obtenir le taux actuel
  const fx = await getInternalFxRate(from, to);
  const rawConverted = originalAmount * fx.rate;
  const convertedAmount = NO_DECIMAL_CURRENCIES.has(to)
    ? Math.round(rawConverted)
    : Math.round(rawConverted * 100) / 100;

  const now      = new Date();
  const expiresAt = new Date(now.getTime() + RATE_LOCK_DURATION_MS);

  const { data: lock, error } = await supabaseAdmin
    .from('checkout_rate_locks')
    .insert({
      buyer_id:        buyerId,
      vendor_id:       vendorId,
      from_currency:   from,
      to_currency:     to,
      original_amount: originalAmount,
      converted_amount: convertedAmount,
      exchange_rate:   fx.rate,
      rate_source:     fx.source,
      rate_fetched_at: fx.fetched_at,
      locked_at:       now.toISOString(),
      expires_at:      expiresAt.toISOString(),
      status:          'active',
    })
    .select()
    .single();

  if (error) {
    logger.error('lockCheckoutRate: erreur création lock:', error);
    throw new Error('Impossible de verrouiller le taux de change');
  }

  return {
    id:              lock.id,
    fromCurrency:    lock.from_currency,
    toCurrency:      lock.to_currency,
    originalAmount:  Number(lock.original_amount),
    convertedAmount: Number(lock.converted_amount),
    rate:            Number(lock.exchange_rate),
    rateSource:      lock.rate_source || '',
    lockedAt:        lock.locked_at,
    expiresAt:       lock.expires_at,
    isExpired:       false,
    remainingMs:     RATE_LOCK_DURATION_MS,
  };
}

/**
 * Invalide un lock après utilisation.
 */
export async function markRateLockUsed(lockId: string, orderId: string): Promise<void> {
  await supabaseAdmin
    .from('checkout_rate_locks')
    .update({ status: 'used', order_id: orderId, updated_at: new Date().toISOString() })
    .eq('id', lockId);
}

// ─────────────────────────────────────────────────────────────────
// 7. calculateMarketplaceCommission — commission plateforme
// ─────────────────────────────────────────────────────────────────

/**
 * Calcule la commission plateforme dans la devise du vendeur.
 * - Produit physique : 5%
 * - Produit digital  : 10%
 * - Service          : 7%
 */
export function calculateMarketplaceCommission(
  grossAmount: number,
  currency: string,
  productType: 'physical' | 'digital' | 'service' | string,
): CommissionResult {
  const feePercent = PLATFORM_FEE_RATES[productType] ?? PLATFORM_FEE_RATES.default;
  const rawFee = grossAmount * (feePercent / 100);
  const feeAmount = NO_DECIMAL_CURRENCIES.has(currency.toUpperCase())
    ? Math.round(rawFee)
    : Math.round(rawFee * 100) / 100;
  const netAmount = grossAmount - feeAmount;

  return { grossAmount, currency, feePercent, feeAmount, netAmount };
}

// ─────────────────────────────────────────────────────────────────
// 8. buildOrderFinancialSummary — résumé financier complet
// ─────────────────────────────────────────────────────────────────

/**
 * Construit le résumé financier d'une commande DEPUIS LA DB.
 * Recalcule tout côté backend (ne jamais faire confiance au frontend).
 */
export async function buildOrderFinancialSummary(params: {
  buyerUserId:  string;
  vendorId:     string;
  items: Array<{ productId: string; quantity: number }>;
  productType?: 'physical' | 'digital' | 'service';
}): Promise<OrderFinancialSummary> {
  const [buyerCurrency, sellerCurrency] = await Promise.all([
    getBuyerCurrency(params.buyerUserId),
    getSellerCurrency(params.vendorId),
  ]);

  // Calculer le total original dans la devise RÉELLE du produit (pas la devise shop du vendeur)
  // Ex: produit à 25 000 GNF d'un vendeur GBP → priceCurrency = 'GNF', pas 'GBP'
  let totalOriginal = 0;
  let priceCurrency: string = sellerCurrency; // fallback si liste vide
  const productType = params.productType || 'physical';

  for (const item of params.items) {
    const product = await getProductOriginalPrice(item.productId);
    if (!product) {
      throw new Error(`Produit ${item.productId} introuvable ou inactif`);
    }
    // Les prix sont TOUJOURS lus depuis la DB (pas le frontend)
    priceCurrency = product.currency; // devise réelle du prix (priorité absolue sur shop_currency)
    totalOriginal += product.amount * item.quantity;
  }

  // Commission dans la devise du prix produit
  const commission = calculateMarketplaceCommission(totalOriginal, priceCurrency, productType);

  // Conversion vers la devise acheteur — comparaison sur la devise PRIX (product.currency)
  // Si le produit est en GNF et l'acheteur paie en GNF → isCross = false, pas de conversion
  const isCross = priceCurrency.toUpperCase() !== buyerCurrency.toUpperCase();
  let totalPaid    = totalOriginal;
  let fxRate       = 1;
  let fxSource     = 'identity';
  let fxFetchedAt  = new Date().toISOString();
  let rateLockExp: string | null = null;

  if (isCross) {
    const fx = await getInternalFxRate(priceCurrency, buyerCurrency);
    fxRate      = fx.rate;
    fxSource    = fx.source;
    fxFetchedAt = fx.fetched_at;

    const rawTotal = totalOriginal * fxRate;
    totalPaid = NO_DECIMAL_CURRENCIES.has(buyerCurrency)
      ? Math.round(rawTotal)
      : Math.round(rawTotal * 100) / 100;

    rateLockExp = new Date(Date.now() + RATE_LOCK_DURATION_MS).toISOString();
  }

  return {
    sellerCurrency:      priceCurrency, // devise réelle du prix produit (pas nécessairement shop_currency)
    totalOriginalAmount:  totalOriginal,
    platformFeePercent:  commission.feePercent,
    platformFeeAmount:   commission.feeAmount,
    sellerNetAmount:     commission.netAmount,
    buyerCurrency,
    totalPaidAmount:     totalPaid,
    isCrossCurrency:     isCross,
    exchangeRate:        fxRate,
    exchangeRateSource:  fxSource,
    rateFetchedAt:       fxFetchedAt,
    rateLockExpiresAt:   rateLockExp,
  };
}
