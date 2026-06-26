/**
 * SERVICE DE CONVERSION CENTRALISÉ — Backend Node.js
 * Point d'entrée UNIQUE pour toute conversion de devise dans les transactions.
 * Lit currency_exchange_rates (taux BCRG officiel).
 */
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { smartRound } from '../config/currencyConfig.js';

interface ConversionResult {
  convertedAmount: number;
  rate:            number;
  source:          string;
  fetchedAt:       string;
}

/** Résout le taux stocké : priorité `rate` (net BCRG sans marge). */
function resolveStoredFxRate(
  row: { rate?: number | null; final_rate_usd?: number | null; final_rate_eur?: number | null } | null,
  base: string
): number {
  if (!row) return NaN;
  const directRate = Number(row.rate);
  if (Number.isFinite(directRate) && directRate > 0) return directRate;
  if (base === 'USD' && Number(row.final_rate_usd) > 0) return Number(row.final_rate_usd);
  if (base === 'EUR' && Number(row.final_rate_eur) > 0) return Number(row.final_rate_eur);
  return NaN;
}

/**
 * Obtient le taux de conversion (direct → inverse → pivot USD).
 * Throw si introuvable (jamais de fallback silencieux).
 */
export async function getConversionRate(from: string, to: string): Promise<{ rate: number; source: string; fetchedAt: string }> {
  const f = String(from || '').toUpperCase();
  const t = String(to || '').toUpperCase();
  if (f === t) return { rate: 1, source: 'identity', fetchedAt: new Date().toISOString() };

  // Direct
  const { data: direct } = await supabaseAdmin
    .from('currency_exchange_rates')
    .select('rate, final_rate_usd, final_rate_eur, retrieved_at')
    .eq('from_currency', f).eq('to_currency', t).eq('is_active', true)
    .order('retrieved_at', { ascending: false }).limit(1).maybeSingle();
  const directRate = resolveStoredFxRate(direct, f);
  if (Number.isFinite(directRate) && directRate > 0) {
    return { rate: directRate, source: 'table-direct', fetchedAt: direct?.retrieved_at || new Date().toISOString() };
  }

  // Inverse
  const { data: inverse } = await supabaseAdmin
    .from('currency_exchange_rates')
    .select('rate, final_rate_usd, final_rate_eur, retrieved_at')
    .eq('from_currency', t).eq('to_currency', f).eq('is_active', true)
    .order('retrieved_at', { ascending: false }).limit(1).maybeSingle();
  const inverseRate = resolveStoredFxRate(inverse, t);
  if (Number.isFinite(inverseRate) && inverseRate > 0) {
    return { rate: 1 / inverseRate, source: 'table-inverse', fetchedAt: inverse?.retrieved_at || new Date().toISOString() };
  }

  // Pivot USD
  const [{ data: usdToSource }, { data: usdToTarget }] = await Promise.all([
    supabaseAdmin.from('currency_exchange_rates').select('rate, final_rate_usd, retrieved_at')
      .eq('from_currency', 'USD').eq('to_currency', f).eq('is_active', true)
      .order('retrieved_at', { ascending: false }).limit(1).maybeSingle(),
    supabaseAdmin.from('currency_exchange_rates').select('rate, final_rate_usd, retrieved_at')
      .eq('from_currency', 'USD').eq('to_currency', t).eq('is_active', true)
      .order('retrieved_at', { ascending: false }).limit(1).maybeSingle(),
  ]);
  const srcViaUsd = resolveStoredFxRate(usdToSource, 'USD');
  const tgtViaUsd = resolveStoredFxRate(usdToTarget, 'USD');
  if (Number.isFinite(srcViaUsd) && srcViaUsd > 0 && Number.isFinite(tgtViaUsd) && tgtViaUsd > 0) {
    return { rate: tgtViaUsd / srcViaUsd, source: 'table-usd-pivot', fetchedAt: usdToTarget?.retrieved_at || new Date().toISOString() };
  }

  logger.warn(`[currencyConversion] Taux introuvable ${f}->${t}`);
  throw new Error(`Taux de change introuvable pour ${f}→${t}`);
}

/** Convertit un montant avec arrondi correct selon la devise cible. */
export async function convertAmount(amount: number, from: string, to: string): Promise<ConversionResult> {
  const { rate, source, fetchedAt } = await getConversionRate(from, to);
  const converted = smartRound(amount * rate, to);
  return { convertedAmount: converted, rate, source, fetchedAt };
}
