/**
 * 🌍 SUBSCRIPTION PRICING SERVICE — prix d'abonnement par PAYS VERROUILLÉ.
 *
 * Source de vérité : la table `subscription_prices` (grilles fixées par l'admin, PAS une
 * conversion FX). Le pays est lu sur `profiles.country_code` (verrouillé à l'inscription) :
 * voyager ne change pas les prix. Le client ne voit JAMAIS le prix d'un autre pays.
 *
 * Cache Redis (best-effort, fallback DB direct) : prices:${countryCode}:${serviceType}.
 */

import { supabaseAdmin } from '../config/supabase.js';
import { cache } from '../config/redis.js';
import { logger } from '../config/logger.js';

const PRICE_TTL = 86400; // 24 h

export type CountryPrice = {
  country_code: string;
  service_type: string;
  plan_code: string;
  price: number;
  currency_code: string;
  currency_symbol: string;
  flag_emoji: string | null;
  commission_rate: number;
  billing_cycle: string;
};

/** Pays verrouillé d'un utilisateur (null si non défini). */
export async function getUserCountry(userId: string): Promise<string | null> {
  const { data, error } = await supabaseAdmin
    .from('profiles').select('country_code').eq('id', userId).maybeSingle();
  if (error) { logger.warn('getUserCountry error', { userId, error: error.message }); return null; }
  return (data?.country_code as string) || null;
}

/**
 * Toute la grille d'un (pays, service) — mise en cache 24 h. Tarification par ZONE-DEVISE :
 * on lit les prix de zone (country_code NULL) de la devise du pays + d'éventuels overrides
 * propres au pays (qui priment). Tous les pays d'une même devise → même prix. Cache par devise.
 */
export async function getCountryServicePrices(countryCode: string, serviceType: string): Promise<CountryPrice[]> {
  if (!countryCode) return [];
  const { data: country } = await supabaseAdmin.from('countries')
    .select('currency_code, currency_symbol, flag_emoji').eq('country_code', countryCode).maybeSingle();
  const currency = (country as any)?.currency_code as string | undefined;
  if (!currency) return [];

  const key = `prices:${currency}:${serviceType}`;
  const zone = await cache.getOrSet<CountryPrice[]>(key, PRICE_TTL, async () => {
    const { data, error } = await supabaseAdmin.from('subscription_prices')
      .select('country_code, service_type, plan_code, price, currency_code, commission_rate, billing_cycle')
      .eq('currency_code', currency).is('country_code', null)
      .eq('service_type', serviceType).eq('is_active', true);
    if (error) { logger.warn('getCountryServicePrices zone error', { currency, serviceType, error: error.message }); return []; }
    return (data || []) as CountryPrice[];
  });

  // Overrides propres au pays (rares) — non cachés, priment sur la zone.
  const { data: overrides } = await supabaseAdmin.from('subscription_prices')
    .select('country_code, service_type, plan_code, price, currency_code, commission_rate, billing_cycle')
    .eq('country_code', countryCode).eq('service_type', serviceType).eq('is_active', true);

  const byPlan = new Map<string, CountryPrice>();
  for (const z of zone) byPlan.set(`${z.plan_code}:${z.billing_cycle}`, z);
  for (const o of (overrides || []) as CountryPrice[]) byPlan.set(`${o.plan_code}:${o.billing_cycle}`, o);

  return [...byPlan.values()].map((p) => ({
    ...p,
    currency_symbol: (country as any)?.currency_symbol || p.currency_code,
    flag_emoji: (country as any)?.flag_emoji || null,
  }));
}

/**
 * Prix d'UN plan pour l'utilisateur (par son pays verrouillé). Utilise le résolveur SQL
 * SECURITY DEFINER (jamais le prix client). Renvoie null si pas de pays / pas de grille.
 */
export async function getSubscriptionPrice(
  userId: string, serviceType: string, plan: string, cycle: string = 'monthly'
): Promise<CountryPrice | null> {
  const { data, error } = await supabaseAdmin.rpc('get_subscription_price_by_country', {
    p_user_id: userId, p_service_type: serviceType, p_plan: plan, p_cycle: cycle,
  });
  if (error) { logger.warn('getSubscriptionPrice rpc error', { userId, serviceType, plan, error: error.message }); return null; }
  if (!data || (data as any).found !== true) return null;
  const d = data as any;
  return {
    country_code: d.country_code, service_type: d.service_type, plan_code: d.plan_code,
    price: Number(d.price), currency_code: d.currency_code, currency_symbol: d.currency_symbol,
    flag_emoji: d.flag_emoji ?? null, commission_rate: Number(d.commission_rate), billing_cycle: d.billing_cycle,
  };
}

/** Libellé d'affichage : « 🇬🇳 Plan Pro — 25 000 GNF/mois ». */
export function formatPriceLabel(p: CountryPrice, planDisplay?: string): string {
  const amount = p.price % 1 === 0 ? p.price.toLocaleString('fr-FR') : p.price.toLocaleString('fr-FR', { minimumFractionDigits: 2 });
  const cycle = p.billing_cycle === 'yearly' ? 'an' : 'mois';
  const flag = p.flag_emoji ? `${p.flag_emoji} ` : '';
  const name = planDisplay || `Plan ${p.plan_code}`;
  return `${flag}${name} — ${amount} ${p.currency_code}/${cycle}`;
}

/** Invalide le cache de la ZONE-devise du pays après un changement admin. */
export async function invalidateCountryPriceCache(countryCode: string, serviceType?: string): Promise<void> {
  const { data } = await supabaseAdmin.from('countries')
    .select('currency_code').eq('country_code', countryCode).maybeSingle();
  const currency = (data as any)?.currency_code as string | undefined;
  if (!currency) { await cache.invalidatePattern(`prices:*`); return; }
  if (serviceType) await cache.del(`prices:${currency}:${serviceType}`);
  else await cache.invalidatePattern(`prices:${currency}:*`);
}
