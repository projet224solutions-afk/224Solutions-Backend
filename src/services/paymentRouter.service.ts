import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

/**
 * ROUTEUR DE PAIEMENT — le prestataire est choisi selon la ZONE DU BÉNÉFICIAIRE (RÈGLE 1),
 * jamais celle du payeur. L'argent atterrit toujours dans la zone où il devra ressortir.
 *   zone 'west'   → Stripe (carte uniquement)
 *   zone 'africa' → method momo → Djomy ; method carte → CinetPay
 * Interdits : géo-IP / BIN ne décident jamais. Le routeur ne débite rien ; il journalise chaque
 * décision. Pays absent de la config `payment_zones` → ZONE_INCONNUE (refus + alerte PDG).
 * Ce MÊME service sert aussi la résolution des RETRAITS (cohérence in/out par zone).
 */

export type PayMethod = 'card' | 'orange_money' | 'mtn_momo' | 'wave';
export type Provider = 'stripe' | 'djomy' | 'cinetpay' | 'wave';
export interface RouterDecision {
  ok: boolean;
  provider?: Provider;
  zone?: 'africa' | 'west';
  countryCode?: string | null;
  reason: string;
  error_code?: string;
}

/** Zone du bénéficiaire ('africa'|'west'|null). Sert à n'afficher que les rails de la zone. */
export async function resolveZone(beneficiaryUserId: string): Promise<'africa' | 'west' | null> {
  const cc = await beneficiaryCountry(beneficiaryUserId);
  const { data } = await supabaseAdmin.rpc('resolve_payment_zone', { p_country_code: cc || '' });
  return (data as 'africa' | 'west' | null) || null;
}

/** Résout le pays du bénéficiaire (commerçant/prestataire → vendors, sinon profil). */
async function beneficiaryCountry(beneficiaryUserId: string): Promise<string | null> {
  const { data: v } = await supabaseAdmin.from('vendors')
    .select('country_code').eq('user_id', beneficiaryUserId).not('country_code', 'is', null)
    .order('created_at', { ascending: true }).limit(1).maybeSingle();
  if (v && (v as any).country_code) return String((v as any).country_code);
  const { data: p } = await supabaseAdmin.from('profiles')
    .select('country_code, country').eq('id', beneficiaryUserId).maybeSingle();
  return (p as any)?.country_code || (p as any)?.country || null;
}

async function journal(entry: {
  beneficiaryUserId: string; method: string; countryCode: string | null;
  zone: string | null; provider: string | null; reason: string;
}): Promise<void> {
  try {
    await supabaseAdmin.from('payment_router_log').insert({
      beneficiary_user_id: entry.beneficiaryUserId, method: entry.method,
      country_code: entry.countryCode, zone: entry.zone, provider: entry.provider, reason: entry.reason,
    });
  } catch (e: any) { logger.warn(`[router] journal échoué: ${e?.message}`); }
}

async function alertUnknownZone(beneficiaryUserId: string, countryCode: string | null): Promise<void> {
  try {
    await supabaseAdmin.from('system_alerts').insert({
      severity: 'warning', module: 'payment_router', title: 'Zone de paiement inconnue',
      message: `Bénéficiaire ${beneficiaryUserId} : pays « ${countryCode ?? 'NULL'} » absent de payment_zones — paiement refusé.`,
      metadata: { beneficiary_user_id: beneficiaryUserId, country_code: countryCode },
    });
  } catch (e: any) { logger.warn(`[router] alerte zone échouée: ${e?.message}`); }
}

/**
 * Décide du prestataire pour créditer `beneficiaryUserId` via `method`. Journalise TOUJOURS.
 */
export async function resolveProvider(params: {
  beneficiaryUserId: string; method: PayMethod;
}): Promise<RouterDecision> {
  const { beneficiaryUserId, method } = params;
  const countryCode = await beneficiaryCountry(beneficiaryUserId);

  const { data: zRow } = await supabaseAdmin.rpc('resolve_payment_zone', { p_country_code: countryCode || '' });
  const zone = (zRow as 'africa' | 'west' | null) || null;

  if (!zone) {
    await journal({ beneficiaryUserId, method, countryCode, zone: null, provider: null, reason: 'ZONE_INCONNUE' });
    await alertUnknownZone(beneficiaryUserId, countryCode);
    return { ok: false, reason: 'ZONE_INCONNUE', error_code: 'ZONE_INCONNUE', countryCode };
  }

  let provider: Provider | null = null;
  let reason = '';
  if (zone === 'west') {
    if (method === 'card') { provider = 'stripe'; reason = 'west→stripe(card)'; }
    else { reason = 'west n’accepte que la carte (Stripe)'; }
  } else { // africa
    if (method === 'orange_money' || method === 'mtn_momo') { provider = 'djomy'; reason = 'africa→djomy(momo)'; }
    else if (method === 'card') { provider = 'cinetpay'; reason = 'africa→cinetpay(card)'; }
    else if (method === 'wave') { provider = 'wave'; reason = 'africa→wave'; } // Wave = Afrique uniquement (jamais west)
  }

  await journal({ beneficiaryUserId, method, countryCode, zone, provider, reason: provider ? reason : `REFUS:${reason}` });

  if (!provider) return { ok: false, zone, countryCode, reason, error_code: 'METHODE_INDISPONIBLE_ZONE' };
  return { ok: true, provider, zone, countryCode, reason };
}
