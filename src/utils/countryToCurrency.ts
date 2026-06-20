/**
 * Retourne la devise officielle (ISO 4217) selon le code pays (ISO 3166-1 alpha-2)
 * Par défaut: GNF (Franc Guinéen)
 */
const COUNTRY_CURRENCY_MAP: Record<string, string> = {
  // AFRIQUE DE L'OUEST
  GN: 'GNF', SN: 'XOF', ML: 'XOF', CI: 'XOF', BF: 'XOF',
  NE: 'XOF', TG: 'XOF', BJ: 'XOF', GW: 'XOF', SL: 'SLL',
  LR: 'LRD', GM: 'GMD', NG: 'NGN', GH: 'GHS', MR: 'MRU', CV: 'CVE',
  // AFRIQUE CENTRALE
  CM: 'XAF', GA: 'XAF', TD: 'XAF', CF: 'XAF', CG: 'XAF', GQ: 'XAF',
  CD: 'CDF', ST: 'STN',
  // AFRIQUE DU NORD
  MA: 'MAD', DZ: 'DZD', TN: 'TND', EG: 'EGP', LY: 'LYD',
  // AFRIQUE DE L'EST
  KE: 'KES', TZ: 'TZS', UG: 'UGX', RW: 'RWF', ET: 'ETB',
  // AFRIQUE AUSTRALE
  ZA: 'ZAR', NA: 'NAD', BW: 'BWP', ZM: 'ZMW', MZ: 'MZN', AO: 'AOA',
  // OCÉAN INDIEN
  MG: 'MGA', MU: 'MUR', KM: 'KMF',
  // EUROPE — ZONE EURO
  FR: 'EUR', DE: 'EUR', IT: 'EUR', ES: 'EUR', PT: 'EUR', BE: 'EUR',
  NL: 'EUR', AT: 'EUR', IE: 'EUR', FI: 'EUR', GR: 'EUR', LU: 'EUR',
  MT: 'EUR', CY: 'EUR', SK: 'EUR', SI: 'EUR', EE: 'EUR', LV: 'EUR',
  LT: 'EUR', HR: 'EUR', ME: 'EUR', XK: 'EUR',
  // EUROPE — HORS EURO
  GB: 'GBP', CH: 'CHF', NO: 'NOK', SE: 'SEK', DK: 'DKK',
  PL: 'PLN', CZ: 'CZK', HU: 'HUF', RO: 'RON', RU: 'RUB', TR: 'TRY', UA: 'UAH',
  // AMÉRIQUE DU NORD
  US: 'USD', CA: 'CAD', MX: 'MXN',
  // AMÉRIQUE DU SUD
  BR: 'BRL', AR: 'ARS', CL: 'CLP', CO: 'COP', PE: 'PEN',
  // MOYEN-ORIENT
  AE: 'AED', SA: 'SAR', QA: 'QAR', KW: 'KWD',
  // ASIE
  CN: 'CNY', JP: 'JPY', KR: 'KRW', IN: 'INR', SG: 'SGD', MY: 'MYR', TH: 'THB',
  // OCÉANIE
  AU: 'AUD', NZ: 'NZD',
};

export function countryToCurrency(countryCode: string | null | undefined): string {
  if (!countryCode) return 'GNF';
  return COUNTRY_CURRENCY_MAP[countryCode.toUpperCase().trim()] ?? 'GNF';
}
