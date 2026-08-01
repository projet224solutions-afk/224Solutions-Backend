/**
 * 📱 SMS SERVICE — FAÇADE de la passerelle unique (services/sms/smsGateway.ts).
 *
 * ⛔ GELÉ POUR L'AUTHENTIFICATION (décision PDG 01/08/2026) : le canal téléphone de l'AUTH (inscription +
 *    connexion) passe désormais par WhatsApp (services/whatsappOtp.service.ts), repli email. Ce service
 *    N'EST PLUS appelé dans un parcours d'AUTH (garde-fou : *.antiSms.test.ts). Il reste vivant pour les
 *    usages LEGACY hors-auth (agent cash, campagnes). NE PAS le rebrancher dans l'auth sans décision PDG
 *    (réversible, comme PayPal). Les plafonds de coût SMS restent en place (défense en profondeur).
 *
 * RÈGLE UNIVERSELLE (décision PDG) : tout SMS de l'application part par `sendSms` → la
 * passerelle (registre de fournisseurs + routage PAR PAYS configurable en base
 * `sms_country_routing` + journal `sms_send_log`). AUCUN appel fournisseur direct ailleurs.
 *
 * Cette façade préserve la signature historique `sendSms(to, message, countryCode?)` pour
 * les ~10 points d'appel existants, et ajoute `usage` (signup | reset | agent_cash | test |
 * campaign | notification | other) pour la ventilation des coûts sur l'écran PDG.
 */

// Formatage E.164 pan-africain : logique pure dans phoneFormat.ts (testable sans env).
// Ré-exporté ici pour ne pas casser les imports existants (`from '../services/sms.service.js'`).
export {
  formatPhoneIntl,
  dialCodeForCountry,
  COUNTRY_DIAL_CODES,
  DEFAULT_COUNTRY_ISO,
} from './phoneFormat.js';

import { gatewaySend } from './sms/smsGateway.js';

export async function sendSms(
  to: string,
  message: string,
  countryCode?: string,
  usage?: string,
): Promise<{ ok: boolean; error?: string; provider?: string }> {
  return gatewaySend(to, message, countryCode, usage || 'other');
}
