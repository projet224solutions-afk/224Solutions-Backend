/**
 * SOURCE UNIQUE DE VÉRITÉ — Configuration des devises
 * Toute logique de devise (arrondi, décimales, Stripe) DOIT importer d'ici.
 * Ne jamais redéfinir une liste ZERO_DECIMAL ailleurs.
 */

/**
 * Devises sans décimales (zero-decimal).
 * Liste complète et alignée sur la spec Stripe + devises africaines 224Solutions.
 * Source Stripe : https://stripe.com/docs/currencies#zero-decimal
 */
export const ZERO_DECIMAL_CURRENCIES = new Set<string>([
  // ── Devises africaines 224Solutions ──
  'GNF', 'XOF', 'XAF', 'BIF', 'DJF', 'KMF', 'MGA', 'RWF', 'UGX',
  // ── Zero-decimal Stripe internationales ──
  'CLP', 'JPY', 'KRW', 'PYG', 'VND', 'VUV', 'XPF',
]);

/**
 * Devises à 3 décimales (cas Stripe spécial — multiplier par 1000).
 * Rares mais présentes : dinar bahreïni, koweïtien, etc.
 */
export const THREE_DECIMAL_CURRENCIES = new Set<string>([
  'BHD', 'KWD', 'OMR', 'TND',
]);

/** Nombre de décimales pour une devise. */
export function getCurrencyDecimals(currency: string): number {
  const cur = (currency || 'GNF').toUpperCase();
  if (ZERO_DECIMAL_CURRENCIES.has(cur))  return 0;
  if (THREE_DECIMAL_CURRENCIES.has(cur)) return 3;
  return 2;
}

/**
 * Arrondi intelligent selon la devise.
 * GNF/XOF → entier. EUR/USD → 2 décimales. KWD → 3 décimales.
 */
export function smartRound(amount: number, currency: string): number {
  const decimals = getCurrencyDecimals(currency);
  const factor = Math.pow(10, decimals);
  return Math.round(amount * factor) / factor;
}

/**
 * Convertit un montant vers le format attendu par Stripe (plus petite unité).
 * GNF 5000 → 5000 (zero-decimal, pas de ×100)
 * EUR 50.00 → 5000 (×100)
 * KWD 5.000 → 5000 (×1000)
 */
export function toStripeAmount(amount: number, currency: string): number {
  const decimals = getCurrencyDecimals(currency);
  return Math.round(amount * Math.pow(10, decimals));
}

/** Inverse : montant Stripe → montant réel. */
export function fromStripeAmount(stripeAmount: number, currency: string): number {
  const decimals = getCurrencyDecimals(currency);
  return stripeAmount / Math.pow(10, decimals);
}
