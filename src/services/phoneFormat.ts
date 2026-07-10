/**
 * 🌍 FORMATAGE TÉLÉPHONE E.164 (pan-africain) — module PUR (aucune dépendance env/DB),
 * pour être testable isolément (vitest) et réutilisable partout (SMS, backfill auth, etc.).
 *
 * NB : il n'existe PAS de `src/services/regions.ts` dans ce backend (la table pays du
 * frontend vit dans `vista-flows/src/utils/phoneData.ts`) — cette table est donc la SOURCE
 * unique côté backend pour dériver un indicatif depuis un code pays ISO-2.
 */
import { logger } from '../config/logger.js';

/**
 * INDICATIFS PAYS (ISO-2 → indicatif E.164, SANS le « + »). Afrique de l'Ouest d'abord
 * (pays cibles 224Solutions), puis reste de l'Afrique et international courant. EXTENSIBLE :
 * ajouter une ligne suffit.
 */
export const COUNTRY_DIAL_CODES: Record<string, string> = {
  // Afrique de l'Ouest (cibles principales)
  GN: '224', SN: '221', CI: '225', ML: '223', LR: '231', SL: '232', GW: '245',
  BF: '226', NE: '227', TG: '228', BJ: '229', MR: '222', GM: '220', CV: '238',
  GH: '233', NG: '234',
  // Afrique centrale
  CM: '237', GA: '241', CG: '242', CD: '243', CF: '236', TD: '235', GQ: '240', ST: '239',
  // Afrique du Nord
  MA: '212', DZ: '213', TN: '216', LY: '218', EG: '20',
  // Afrique de l'Est / australe
  KE: '254', TZ: '255', UG: '256', RW: '250', ET: '251', ZA: '27',
  // International courant
  FR: '33', BE: '32', CH: '41', US: '1', CA: '1', GB: '44', DE: '49', ES: '34',
  IT: '39', PT: '351', CN: '86', TR: '90', AE: '971', SA: '966',
};

/** Pays utilisant un « 0 » interurbain (trunk) à retirer avant de préfixer l'indicatif. */
const TRUNK_ZERO_ISO = new Set(['FR', 'BE', 'CH', 'GB', 'DE', 'IT', 'ES', 'PT', 'TR']);

/** Pays par défaut quand aucun `countryCode` n'est fourni (historique 224Solutions = Guinée). */
export const DEFAULT_COUNTRY_ISO = 'GN';

/** Indicatif E.164 (sans +) pour un code pays ISO-2, ou undefined si inconnu. */
export function dialCodeForCountry(countryCode?: string): string | undefined {
  const iso = String(countryCode || '').trim().toUpperCase();
  return iso ? COUNTRY_DIAL_CODES[iso] : undefined;
}

/**
 * Normalise un numéro au format E.164 selon un PAYS EXPLICITE (ISO-2).
 *
 * - Nettoie espaces/tirets/points/parenthèses.
 * - Un numéro déjà en `+…` (ou `00…`) est CONSERVÉ (juste nettoyé) — l'indicatif prime.
 * - Sinon on préfixe l'indicatif du `countryCode` (ex : `SN` → +221). Si le numéro contient
 *   déjà son indicatif (ex : `224612…`), on ne le double pas.
 * - Sans `countryCode` (ou pays inconnu) : repli sur la Guinée (GN / +224) + WARNING logué —
 *   le pan-africain EXIGE de passer le pays, sinon un numéro sénégalais serait mal formé.
 *
 * @param raw          numéro brut (local ou international)
 * @param countryCode  ISO-2 du pays (ex : 'GN', 'SN', 'CI'). Optionnel (repli GN + warn).
 */
export function formatPhoneIntl(raw: string, countryCode?: string): string {
  const phone = String(raw || '').replace(/[\s().-]/g, '').trim();
  if (!phone) return phone;

  // Déjà international : l'indicatif présent fait foi, on conserve tel quel.
  if (phone.startsWith('+')) return phone;
  if (phone.startsWith('00')) return `+${phone.slice(2)}`;

  const iso = String(countryCode || '').trim().toUpperCase();
  let dial = iso ? COUNTRY_DIAL_CODES[iso] : undefined;
  let effectiveIso = iso;

  if (!dial) {
    // Aucun pays exploitable → repli Guinée + WARNING explicite.
    effectiveIso = DEFAULT_COUNTRY_ISO;
    dial = COUNTRY_DIAL_CODES[DEFAULT_COUNTRY_ISO];
    logger.warn(
      `[SMS] formatPhoneIntl: aucun pays exploitable (countryCode=${countryCode ?? 'undefined'}) pour « ${raw} » ` +
      `→ repli ${DEFAULT_COUNTRY_ISO} (+${dial}). Passer un countryCode ISO-2 pour le pan-africain.`,
    );
  }

  // Le numéro contient déjà son indicatif national (ex : 224612345678) → ne pas le doubler.
  if (phone.startsWith(dial) && phone.length >= dial.length + 7) {
    return `+${phone}`;
  }

  // Retirer un « 0 » interurbain de tête pour les pays qui en utilisent un (FR, GB…).
  let local = phone;
  if (TRUNK_ZERO_ISO.has(effectiveIso)) local = local.replace(/^0+/, '');

  return `+${dial}${local}`;
}
