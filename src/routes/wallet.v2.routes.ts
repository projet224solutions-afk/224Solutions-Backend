/**
 * 💰 WALLET v2 ROUTES - Backend Node.js centralisé
 *
 * Tables utilisées :
 *   - `wallets`, `wallet_transactions`, `wallet_idempotency_keys`
 *
 * Endpoints :
 *   - GET /balance, /transactions, /status (lecture)
 *   - POST /initialize (creation)
 *   - POST /deposit  — crédit wallet (migré depuis wallet-operations Edge Function)
 *   - POST /withdraw — débit wallet (migré depuis wallet-operations Edge Function)
 *   - POST /transfer — transfert P2P (migré depuis wallet-operations / wallet-transfer Edge Function)
 *   - POST /credit   — crédit admin/interne (service rôle)
 *
 * ⚠️ Route montée sur /api/v2/wallet (séparée du legacy /api/wallet)
 */

import { Router, Response } from 'express';
import crypto from 'crypto';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import { requirePermissionOrRole } from '../middlewares/permissions.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { AFRICAN_BANK_SOURCE_URLS, isAfricanBankSourceUrl } from '../constants/africanBankSources.js';
import { creditWallet, debitWallet, transferBetweenWallets } from '../services/wallet.service.js';
import { createNotification } from '../services/notification.service.js';
import { triggerAffiliateCommission } from '../services/commission.service.js';
import { changeWalletPin, ensureWalletExistsForPin, getWalletPinPolicy, getWalletPinState, resetWalletPinWithPassword, setupWalletPin, verifyWalletPin } from '../services/walletPin.service.js';
import { emitCoreFeatureEvent } from '../services/coreFeatureEvents.service.js';

const router = Router();

async function ignoreSupabaseError(operation: PromiseLike<unknown> | unknown): Promise<void> {
  await Promise.resolve(operation).catch(() => undefined);
}

const SYSTEM_USER_ID = '00000000-0000-0000-0000-000000000000';
const BCRG_OFFICIAL_URL = 'https://www.bcrg-guinee.org';
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface ResolvedRecipient {
  userId: string;
  query: string;
  matchedBy: 'uuid' | 'user_ids.custom_id' | 'profiles.public_id' | 'profiles.custom_id' | 'profiles.email' | 'profiles.phone' | 'auth.users.email' | 'auth.users.phone';
  displayName: string | null;
  email: string | null;
  phone: string | null;
  publicId: string | null;
  customId: string | null;
}

function isFxSuccessStatus(status: string | null | undefined): boolean {
  const normalized = (status || '').toLowerCase();
  return normalized === 'success' || normalized === 'completed' || normalized === 'ok';
}

function hasWalletPinEnabled(walletPinState: { pin_enabled?: boolean | null; pin_hash?: string | null } | null | undefined): boolean {
  return Boolean(walletPinState?.pin_enabled ?? walletPinState?.pin_hash);
}

async function requireValidTransactionPin(userId: string, pin: unknown): Promise<{ ok: boolean; error?: string; lockedUntil?: string | null }> {
  const walletPinState = await getWalletPinState(userId);
  const pinEnabled = hasWalletPinEnabled(walletPinState);

  // Compatibility mode: if PIN is not configured yet, keep operations available.
  if (!pinEnabled) {
    return { ok: true };
  }

  if (typeof pin !== 'string') {
    return { ok: false, error: 'Code PIN requis pour confirmer cette opération' };
  }

  const verification = await verifyWalletPin(userId, pin);
  if (!verification.valid) {
    return { ok: false, error: verification.error, lockedUntil: verification.lockedUntil };
  }

  return { ok: true };
}

function normalizePhoneCandidates(raw: string): string[] {
  const compact = raw.replace(/[\s\-()]/g, '');
  const digits = compact.replace(/[^\d]/g, '');
  const withPlus = digits ? `+${digits}` : '';
  const localNoPrefix = digits.startsWith('00') ? digits.slice(2) : digits;
  return Array.from(new Set([raw, compact, digits, withPlus, localNoPrefix].filter(Boolean)));
}

const CURRENCY_TO_COUNTRY: Record<string, string> = {
  GNF: 'Guinee',
  XOF: 'UEMOA',
  XAF: 'CEMAC',
  NGN: 'Nigeria',
  GHS: 'Ghana',
  KES: 'Kenya',
  UGX: 'Uganda',
  ZAR: 'Afrique du Sud',
  MAD: 'Maroc',
  TND: 'Tunisie',
  EGP: 'Egypte',
  ZMW: 'Zambie',
  RWF: 'Rwanda',
  TZS: 'Tanzanie',
  BWP: 'Botswana',
  MZN: 'Mozambique',
  EUR: 'Zone Euro',
  USD: 'Etats-Unis',
};

function mapCurrencyToCountry(currency: string | null | undefined): string {
  if (!currency) return 'Inconnu';
  return CURRENCY_TO_COUNTRY[String(currency).toUpperCase()] || String(currency).toUpperCase();
}

const ZERO_DECIMAL_TRANSFER_CURRENCIES = new Set([
  'GNF', 'XOF', 'XAF', 'VND', 'IDR', 'KRW', 'JPY', 'CLP', 'UGX', 'RWF',
  'PYG', 'COP', 'HUF', 'ISK', 'BIF', 'DJF', 'KMF', 'MGA', 'VUV',
]);

function smartRoundCurrencyAmount(amount: number, currency: string): number {
  if (!Number.isFinite(amount)) return 0;
  return ZERO_DECIMAL_TRANSFER_CURRENCIES.has(String(currency || '').toUpperCase())
    ? Math.round(amount)
    : Math.round(amount * 100) / 100;
}

function resolveStoredFxRate(
  row: { rate?: number | null; final_rate_usd?: number | null; final_rate_eur?: number | null; retrieved_at?: string | null } | null | undefined,
  baseCurrency: string,
): number {
  if (!row) return Number.NaN;

  // TAUX NET DU JOUR (brut BCRG, SANS la marge plateforme). La marge/commission
  // est désormais prélevée SÉPARÉMENT comme commission explicite (cf. getFxCommissionRate),
  // et non plus intégrée au taux du destinataire (final_rate). Le destinataire reçoit
  // donc TOUJOURS au taux net du jour, de façon cohérente sur tous les corridors.
  const base = String(baseCurrency || '').toUpperCase();
  const directRate = Number(row.rate);
  if (Number.isFinite(directRate) && directRate > 0) {
    return directRate;
  }

  // Fallback uniquement si `rate` (net) est absent : on retombe sur final_rate_*
  // (qui peut contenir la marge — dégradé acceptable car cas rare).
  if (base === 'USD' && Number.isFinite(Number(row.final_rate_usd)) && Number(row.final_rate_usd) > 0) {
    return Number(row.final_rate_usd);
  }
  if (base === 'EUR' && Number.isFinite(Number(row.final_rate_eur)) && Number(row.final_rate_eur) > 0) {
    return Number(row.final_rate_eur);
  }

  const fallbackUsd = Number(row.final_rate_usd);
  if (Number.isFinite(fallbackUsd) && fallbackUsd > 0) {
    return fallbackUsd;
  }

  const fallbackEur = Number(row.final_rate_eur);
  if (Number.isFinite(fallbackEur) && fallbackEur > 0) {
    return fallbackEur;
  }

  return Number.NaN;
}

async function getInternalFxRateFromTable(from: string, to: string): Promise<{ rate: number; source: string; fetchedAt: string }> {
  const sourceCurrency = String(from || '').toUpperCase();
  const targetCurrency = String(to || '').toUpperCase();

  if (sourceCurrency === targetCurrency) {
    return { rate: 1, source: 'identity', fetchedAt: new Date().toISOString() };
  }

  const { data: direct } = await supabaseAdmin
    .from('currency_exchange_rates')
    .select('rate, final_rate_usd, final_rate_eur, retrieved_at')
    .eq('from_currency', sourceCurrency)
    .eq('to_currency', targetCurrency)
    .eq('is_active', true)
    .order('retrieved_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const directRate = resolveStoredFxRate(direct, sourceCurrency);
  if (Number.isFinite(directRate) && directRate > 0) {
    return { rate: directRate, source: 'table-direct', fetchedAt: direct?.retrieved_at || new Date().toISOString() };
  }

  const { data: inverse } = await supabaseAdmin
    .from('currency_exchange_rates')
    .select('rate, final_rate_usd, final_rate_eur, retrieved_at')
    .eq('from_currency', targetCurrency)
    .eq('to_currency', sourceCurrency)
    .eq('is_active', true)
    .order('retrieved_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const inverseRate = resolveStoredFxRate(inverse, targetCurrency);
  if (Number.isFinite(inverseRate) && inverseRate > 0) {
    return {
      rate: 1 / inverseRate,
      source: 'table-inverse',
      fetchedAt: inverse?.retrieved_at || new Date().toISOString(),
    };
  }

  const [{ data: usdToSource }, { data: usdToTarget }] = await Promise.all([
    supabaseAdmin
      .from('currency_exchange_rates')
      .select('rate, final_rate_usd, retrieved_at')
      .eq('from_currency', 'USD')
      .eq('to_currency', sourceCurrency)
      .eq('is_active', true)
      .order('retrieved_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabaseAdmin
      .from('currency_exchange_rates')
      .select('rate, final_rate_usd, retrieved_at')
      .eq('from_currency', 'USD')
      .eq('to_currency', targetCurrency)
      .eq('is_active', true)
      .order('retrieved_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);

  const sourceViaUsd = resolveStoredFxRate(usdToSource, 'USD');
  const targetViaUsd = resolveStoredFxRate(usdToTarget, 'USD');

  if (Number.isFinite(sourceViaUsd) && sourceViaUsd > 0 && Number.isFinite(targetViaUsd) && targetViaUsd > 0) {
    return {
      rate: targetViaUsd / sourceViaUsd,
      source: 'table-usd-pivot',
      fetchedAt: usdToTarget?.retrieved_at || usdToSource?.retrieved_at || new Date().toISOString(),
    };
  }

  throw new Error(`Taux de change introuvable pour ${sourceCurrency}→${targetCurrency}`);
}

/**
 * Taux de commission FX de la plateforme (fraction, ex: 0.05 = 5%).
 * Cette commission est prélevée EN PLUS sur l'expéditeur lors d'un transfert international ;
 * le destinataire reçoit au taux NET du jour. Défaut 5% si non réglé.
 *
 * SOURCE PRIORITAIRE : `system_settings.transfer_fee_percent` (en POURCENTAGE) — c'est CE que le
 * SOURCE PRIORITAIRE : `margin_config.default_margin` — c'est CE que le PDG règle dans **PDGFinance**
 * (champ « marge de conversion FX »), déjà stocké en FRACTION (0.01 = 1%). Repli : l'UI alternative
 * `system_settings.transfer_fee_percent` (en POURCENTAGE), puis 5%. AUCUN cache : la valeur est relue
 * à chaque preview/transfert → toute modif PDG s'applique IMMÉDIATEMENT.
 */
const DEFAULT_FX_COMMISSION = 0.05;
async function getFxCommissionRate(): Promise<number> {
  // 1) Source PDG officielle : margin_config.default_margin (PDGFinance — déjà une FRACTION).
  try {
    const { data } = await supabaseAdmin
      .from('margin_config')
      .select('config_value')
      .eq('config_key', 'default_margin')
      .maybeSingle();
    const v = Number(data?.config_value);
    if (Number.isFinite(v) && v >= 0 && v <= 0.3) return v;
  } catch {
    // ignore — repli ci-dessous
  }
  // 2) Repli : system_settings.transfer_fee_percent (TransferFeeSettings — en POURCENTAGE).
  try {
    const { data } = await supabaseAdmin
      .from('system_settings')
      .select('setting_value')
      .eq('setting_key', 'transfer_fee_percent')
      .maybeSingle();
    const pct = Number(data?.setting_value);
    if (Number.isFinite(pct) && pct >= 0 && pct <= 30) return pct / 100;
  } catch {
    // ignore — fallback défaut
  }
  return DEFAULT_FX_COMMISSION;
}

/**
 * Bornes min/max par transfert (en GNF), pilotées par le PDG via `pdg_settings`
 * (`min_transfer_amount` / `max_transfer_amount`, écrites par PDGTransferLimits sous {value}).
 * Repli sur les défauts si non configurées. Relu à chaque appel → modif PDG immédiate.
 * AVANT : ces bornes étaient codées en dur → l'interface PDG était cosmétique.
 */
const DEFAULT_MIN_TRANSFER_GNF = 100;
const DEFAULT_MAX_TRANSFER_GNF = 50_000_000;
const DEFAULT_MIN_INTL_TRANSFER_GNF = 500;
const DEFAULT_MAX_INTL_TRANSFER_GNF = 50_000_000;

/**
 * Bornes effectives min/max (en GNF) selon national vs international, pilotées par le PDG via
 * `pdg_settings` (PDGTransferLimits). National : min/max_transfer_amount. International :
 * min/max_international_transfer_amount. Repli : défauts ; l'international retombe sur les défauts
 * internationaux. Relu à chaque appel → modif PDG immédiate.
 */
async function getTransferBoundsGnf(isInternational: boolean): Promise<{ min: number; max: number }> {
  try {
    const { data } = await supabaseAdmin
      .from('pdg_settings')
      .select('setting_key, setting_value')
      .in('setting_key', ['min_transfer_amount', 'max_transfer_amount', 'min_international_transfer_amount', 'max_international_transfer_amount']);
    const read = (key: string, def: number): number => {
      const row = (data || []).find((d: any) => d.setting_key === key);
      const raw = (row?.setting_value as any)?.value ?? row?.setting_value;
      const n = Number(raw);
      return Number.isFinite(n) && n > 0 ? n : def;
    };
    let min: number; let max: number;
    if (isInternational) {
      min = read('min_international_transfer_amount', DEFAULT_MIN_INTL_TRANSFER_GNF);
      max = read('max_international_transfer_amount', DEFAULT_MAX_INTL_TRANSFER_GNF);
      return max > min ? { min, max } : { min: DEFAULT_MIN_INTL_TRANSFER_GNF, max: DEFAULT_MAX_INTL_TRANSFER_GNF };
    }
    min = read('min_transfer_amount', DEFAULT_MIN_TRANSFER_GNF);
    max = read('max_transfer_amount', DEFAULT_MAX_TRANSFER_GNF);
    return max > min ? { min, max } : { min: DEFAULT_MIN_TRANSFER_GNF, max: DEFAULT_MAX_TRANSFER_GNF };
  } catch {
    return isInternational
      ? { min: DEFAULT_MIN_INTL_TRANSFER_GNF, max: DEFAULT_MAX_INTL_TRANSFER_GNF }
      : { min: DEFAULT_MIN_TRANSFER_GNF, max: DEFAULT_MAX_TRANSFER_GNF };
  }
}

function isAfricanBankRow(row: { source_url?: string | null; source?: string | null; source_type?: string | null }): boolean {
  if (row?.source_url && isAfricanBankSourceUrl(row.source_url)) {
    return true;
  }

  const source = String(row?.source || '').toLowerCase();
  const sourceType = String(row?.source_type || '').toLowerCase();
  const text = `${source} ${sourceType}`;

  if (sourceType === 'official_fixed_parity' || sourceType === 'official_cross' || sourceType === 'official_html') {
    return true;
  }

  return /bcrg|bceao|beac|cbn|sarb|ecobank|orabank|afreximbank|banque|bank|afric/i.test(text);
}

function resolveOfficialBankSourceUrl(row: { source_url?: string | null; source?: string | null; source_type?: string | null }): string | null {
  if (row?.source_url) return row.source_url;

  const text = `${String(row?.source || '').toLowerCase()} ${String(row?.source_type || '').toLowerCase()}`;

  if (/bcrg|banque centrale de guinee|banque centrale de guinée/.test(text)) {
    return BCRG_OFFICIAL_URL;
  }

  return null;
}

function parseFxRateNumber(rawValue: string): number {
  const parsed = Number.parseFloat(String(rawValue || '').replace(/\u00a0/g, ' ').replace(/\s/g, '').replace(/,/g, '.'));
  return Number.isFinite(parsed) ? parsed : Number.NaN;
}

function extractBcrgWidgetRate(html: string, currency: 'USD' | 'EUR'): number | null {
  const labelPattern = currency === 'USD' ? '(?:USD|Dollar)' : '(?:EUR|Euro)';
  // SOURCE OFFICIELLE = le widget « <h2>usd =</h2> … <h2>8725.1731</h2> » de bcrg-guinee.org.
  // La table TablePress de la même page affiche d'AUTRES valeurs (à ne pas utiliser). On lit le widget.
  const num = '([\\d\\s\\u00a0.,]+)';
  const patterns = [
    new RegExp(`${labelPattern}\\s*=\\s*<\\/h\\d>[\\s\\S]{0,600}?<h\\d[^>]*>\\s*${num}\\s*<\\/h\\d>`, 'gi'),
    new RegExp(`(?:1\\s*${currency}\\s*=\\s*|${currency}\\s*\\/\\s*GNF\\s*[:=]\\s*)${num}`, 'gi'),
  ];

  for (const pattern of patterns) {
    const matches = Array.from(html.matchAll(pattern));
    for (let index = matches.length - 1; index >= 0; index -= 1) {
      const parsed = parseFxRateNumber(matches[index]?.[1] || '');
      if (Number.isFinite(parsed) && parsed > 1000 && parsed < 25000) {
        return parsed;
      }
    }
  }

  return null;
}

async function fetchLiveBcrgUsdGnf(): Promise<{ usdGnf: number; eurGnf: number | null; retrievedAt: string } | null> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);

  try {
    const response = await fetch(BCRG_OFFICIAL_URL, {
      headers: {
        'User-Agent': '224Solutions-FX-Monitor/2.0',
        Accept: 'text/html',
      },
      signal: controller.signal,
    });

    if (!response.ok) {
      return null;
    }

    const html = await response.text();
    const usdGnf = extractBcrgWidgetRate(html, 'USD');
    if (!usdGnf) {
      return null;
    }

    return {
      usdGnf,
      eurGnf: extractBcrgWidgetRate(html, 'EUR'),
      retrievedAt: new Date().toISOString(),
    };
  } catch {
    return null;
  } finally {
    clearTimeout(timeout);
  }
}

function buildAfricanFxCollectPayload(source: string, actorId: string | null) {
  return {
    source,
    actor_id: actorId,
    strict_african_sources: true,
    include_all_african_banks: true,
    primary_source_url: BCRG_OFFICIAL_URL,
    preferred_currency_pairs: [
      { from: 'USD', to: 'GNF' },
      { from: 'EUR', to: 'GNF' },
    ],
    bcrg_source_urls: [BCRG_OFFICIAL_URL],
    preferred_source_urls: AFRICAN_BANK_SOURCE_URLS,
  };
}

async function triggerAfricanFxCollection(source: string, actorId: string | null, timeoutMs = 3500): Promise<{ ok: boolean; status: number | null; payload: any; timedOut: boolean }> {
  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    logger.warn('FX collect trigger skipped: Supabase env manquante');
    return {
      ok: false,
      status: null,
      payload: { message: 'Configuration Supabase manquante' },
      timedOut: false,
    };
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(`${process.env.SUPABASE_URL}/functions/v1/african-fx-collect`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`,
        apikey: process.env.SUPABASE_SERVICE_ROLE_KEY,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(buildAfricanFxCollectPayload(source, actorId)),
      signal: controller.signal,
    });

    const raw = await response.text();
    let payload: any = null;
    try {
      payload = raw ? JSON.parse(raw) : null;
    } catch {
      payload = raw ? { raw } : null;
    }

    return {
      ok: response.ok,
      status: response.status,
      payload,
      timedOut: false,
    };
  } catch (error: any) {
    if (error?.name === 'AbortError') {
      return {
        ok: true,
        status: 202,
        payload: { queued: true, message: 'Collecte FX lancée en arrière-plan.' },
        timedOut: true,
      };
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

async function resolveRecipient(rawRecipient: string): Promise<ResolvedRecipient | null> {
  const candidate = String(rawRecipient || '').trim();
  if (!candidate) return null;

  if (UUID_REGEX.test(candidate)) {
    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('id, email, phone, first_name, last_name, public_id, custom_id')
      .eq('id', candidate)
      .maybeSingle();

    const displayName = profile
      ? `${String((profile as any).first_name || '').trim()} ${String((profile as any).last_name || '').trim()}`.trim() || null
      : null;

    return {
      userId: candidate,
      query: candidate,
      matchedBy: 'uuid',
      displayName,
      email: profile ? String((profile as any).email || '') || null : null,
      phone: profile ? String((profile as any).phone || '') || null : null,
      publicId: profile ? String((profile as any).public_id || '') || null : null,
      customId: profile ? String((profile as any).custom_id || '') || null : null,
    };
  }

  const normalizedId = candidate.toUpperCase();

  const { data: fromUserIds } = await supabaseAdmin
    .from('user_ids')
    .select('user_id')
    .eq('custom_id', normalizedId)
    .maybeSingle();

  if (fromUserIds?.user_id) {
    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('id, email, phone, first_name, last_name, public_id, custom_id')
      .eq('id', fromUserIds.user_id)
      .maybeSingle();

    const displayName = profile
      ? `${String((profile as any).first_name || '').trim()} ${String((profile as any).last_name || '').trim()}`.trim() || null
      : null;

    return {
      userId: fromUserIds.user_id,
      query: candidate,
      matchedBy: 'user_ids.custom_id',
      displayName,
      email: profile ? String((profile as any).email || '') || null : null,
      phone: profile ? String((profile as any).phone || '') || null : null,
      publicId: profile ? String((profile as any).public_id || '') || null : null,
      customId: profile ? String((profile as any).custom_id || '') || null : null,
    };
  }

  const { data: fromProfileIds } = await supabaseAdmin
    .from('profiles')
    .select('id, email, phone, first_name, last_name, public_id, custom_id')
    .or(`public_id.eq.${normalizedId},custom_id.eq.${normalizedId}`)
    .maybeSingle();

  if (fromProfileIds?.id) {
    const matchedBy = String((fromProfileIds as any).public_id || '').toUpperCase() === normalizedId
      ? 'profiles.public_id'
      : 'profiles.custom_id';
    const displayName = `${String((fromProfileIds as any).first_name || '').trim()} ${String((fromProfileIds as any).last_name || '').trim()}`.trim() || null;
    return {
      userId: fromProfileIds.id,
      query: candidate,
      matchedBy,
      displayName,
      email: String((fromProfileIds as any).email || '') || null,
      phone: String((fromProfileIds as any).phone || '') || null,
      publicId: String((fromProfileIds as any).public_id || '') || null,
      customId: String((fromProfileIds as any).custom_id || '') || null,
    };
  }

  const normalizedEmail = candidate.toLowerCase();
  if (normalizedEmail.includes('@')) {
    const { data: fromEmail } = await supabaseAdmin
      .from('profiles')
      .select('id, email, phone, first_name, last_name, public_id, custom_id')
      .eq('email', normalizedEmail)
      .maybeSingle();

    if (fromEmail?.id) {
      const displayName = `${String((fromEmail as any).first_name || '').trim()} ${String((fromEmail as any).last_name || '').trim()}`.trim() || null;
      return {
        userId: fromEmail.id,
        query: candidate,
        matchedBy: 'profiles.email',
        displayName,
        email: String((fromEmail as any).email || '') || null,
        phone: String((fromEmail as any).phone || '') || null,
        publicId: String((fromEmail as any).public_id || '') || null,
        customId: String((fromEmail as any).custom_id || '') || null,
      };
    }

    const { data: authUser } = await supabaseAdmin
      .schema('auth')
      .from('users')
      .select('id, email, phone')
      .eq('email', normalizedEmail)
      .maybeSingle();

    if (authUser?.id) {
      return {
        userId: authUser.id,
        query: candidate,
        matchedBy: 'auth.users.email',
        displayName: null,
        email: String((authUser as any).email || '') || null,
        phone: String((authUser as any).phone || '') || null,
        publicId: null,
        customId: null,
      };
    }
  }

  const phoneCandidates = normalizePhoneCandidates(candidate);
  if (phoneCandidates.length > 0) {
    const phoneFilter = phoneCandidates.map((p) => `phone.eq.${p}`).join(',');
    const { data: fromPhone } = await supabaseAdmin
      .from('profiles')
      .select('id, email, phone, first_name, last_name, public_id, custom_id')
      .or(phoneFilter)
      .limit(1)
      .maybeSingle();

    if (fromPhone?.id) {
      const displayName = `${String((fromPhone as any).first_name || '').trim()} ${String((fromPhone as any).last_name || '').trim()}`.trim() || null;
      return {
        userId: fromPhone.id,
        query: candidate,
        matchedBy: 'profiles.phone',
        displayName,
        email: String((fromPhone as any).email || '') || null,
        phone: String((fromPhone as any).phone || '') || null,
        publicId: String((fromPhone as any).public_id || '') || null,
        customId: String((fromPhone as any).custom_id || '') || null,
      };
    }

    const authPhoneFilter = phoneCandidates.map((p) => `phone.eq.${p}`).join(',');
    const { data: authPhone } = await supabaseAdmin
      .schema('auth')
      .from('users')
      .select('id, email, phone')
      .or(authPhoneFilter)
      .limit(1)
      .maybeSingle();

    if (authPhone?.id) {
      return {
        userId: authPhone.id,
        query: candidate,
        matchedBy: 'auth.users.phone',
        displayName: null,
        email: String((authPhone as any).email || '') || null,
        phone: String((authPhone as any).phone || '') || null,
        publicId: null,
        customId: null,
      };
    }
  }

  return null;
}

async function resolveRecipientUserId(rawRecipient: string): Promise<string | null> {
  const resolved = await resolveRecipient(rawRecipient);
  return resolved?.userId || null;
}

router.get('/recipient/resolve', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const query = String(req.query.q || '').trim();
    if (!query) {
      res.status(400).json({ success: false, error: 'q requis (ID public, email, telephone ou UUID)' });
      return;
    }

    const resolved = await resolveRecipient(query);
    if (!resolved) {
      res.status(404).json({ success: false, error: 'Destinataire introuvable' });
      return;
    }

    if (resolved.userId === req.user!.id) {
      res.status(400).json({ success: false, error: 'Transfert vers soi-meme non autorise' });
      return;
    }

    res.json({ success: true, data: resolved });
  } catch (error: any) {
    logger.error(`Wallet recipient resolve error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la resolution du destinataire' });
  }
});

/**
 * POST /api/v2/wallet/transfer/preview
 * Prévisualisation d'un transfert wallet (frais, solde après, informations destinataire).
 * Entièrement côté backend Node.js (plus de dépendance Edge Function wallet-transfer).
 */
router.post('/transfer/preview', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const senderId = req.user!.id;
    const { amount, recipient_id } = req.body || {};

    if (!amount || typeof amount !== 'number' || amount <= 0) {
      res.status(400).json({ success: false, error: 'Montant invalide' });
      return;
    }
    if (!recipient_id || typeof recipient_id !== 'string') {
      res.status(400).json({ success: false, error: 'recipient_id requis' });
      return;
    }

    const resolved = await resolveRecipient(recipient_id);
    if (!resolved) {
      res.status(404).json({ success: false, error: 'Destinataire introuvable' });
      return;
    }

    if (resolved.userId === senderId) {
      res.status(400).json({ success: false, error: 'Transfert vers soi-même non autorisé' });
      return;
    }

    const [{ data: senderWallet, error: senderWalletError }, { data: receiverWallet, error: receiverWalletError }] = await Promise.all([
      supabaseAdmin
        .from('wallets')
        .select('id, balance, currency, user_id')
        .eq('user_id', senderId)
        .maybeSingle(),
      supabaseAdmin
        .from('wallets')
        .select('id, balance, currency, user_id')
        .eq('user_id', resolved.userId)
        .maybeSingle(),
    ]);

    if (senderWalletError || !senderWallet) {
      res.status(404).json({ success: false, error: 'Wallet expéditeur introuvable' });
      return;
    }

    let recipientWallet = receiverWallet;
    if (receiverWalletError || !recipientWallet) {
      const { data: createdWallet, error: createWalletError } = await supabaseAdmin
        .from('wallets')
        .insert({ user_id: resolved.userId })
        .select('id, balance, currency, user_id')
        .single();

      if (createWalletError || !createdWallet) {
        res.status(404).json({ success: false, error: 'Wallet destinataire introuvable' });
        return;
      }

      recipientWallet = createdWallet as any;
    }

    const senderCurrency = String((senderWallet as any).currency || 'GNF').toUpperCase();
    const receiverCurrency = String((recipientWallet as any).currency || senderCurrency).toUpperCase();
    const isInternational = senderCurrency !== receiverCurrency;
    const senderBalance = Number((senderWallet as any).balance || 0);

    // COMMISSION FX : prélevée EN PLUS sur l'expéditeur uniquement pour les transferts
    // internationaux (cross-devise). Le destinataire reçoit au TAUX NET du jour.
    // Ex (5%) : 1 EUR envoyé → destinataire reçoit 1 × taux_net (10 156,1011 GNF),
    // l'expéditeur est débité 1,05 EUR, la plateforme garde 0,05 EUR (= 507,8 GNF).
    const commissionRate = isInternational ? await getFxCommissionRate() : 0;
    const feePercentage = commissionRate * 100;
    const feeAmount = isInternational
      ? smartRoundCurrencyAmount(amount * commissionRate, senderCurrency)
      : 0;
    const totalDebit = smartRoundCurrencyAmount(amount + feeAmount, senderCurrency);

    if (senderBalance < totalDebit) {
      res.status(402).json({ success: false, error: 'Solde insuffisant' });
      return;
    }

    const amountAfterFee = amount; // base convertie au taux net (la commission est EN PLUS)
    let rateDisplayed = 1;
    let amountReceived = amountAfterFee;
    let rateSource = 'identity';
    let rateFetchedAt = new Date().toISOString();
    let commissionConversion = 0;

    if (isInternational) {
      const fxResult = await getInternalFxRateFromTable(senderCurrency, receiverCurrency);
      rateDisplayed = fxResult.rate; // TAUX NET du jour
      rateSource = fxResult.source;
      rateFetchedAt = fxResult.fetchedAt;
      amountReceived = smartRoundCurrencyAmount(amount * rateDisplayed, receiverCurrency);
      // Commission exprimée dans la devise du destinataire (pour l'affichage)
      commissionConversion = smartRoundCurrencyAmount(feeAmount * rateDisplayed, receiverCurrency);
    }

    // LIMITE de transfert vérifiée sur l'ÉQUIVALENT GNF du montant envoyé (limite en GNF).
    // Bornes pilotées par le PDG (pdg_settings) — national vs international.
    const { min: MIN_TRANSFER_AMOUNT_GNF, max: MAX_TRANSFER_AMOUNT_GNF } = await getTransferBoundsGnf(isInternational);
    let amountInGnf = amount;
    if (senderCurrency !== 'GNF') {
      if (isInternational && receiverCurrency === 'GNF') {
        amountInGnf = amountReceived; // = montant × taux(expéditeur→GNF)
      } else {
        try {
          amountInGnf = amount * (await getInternalFxRateFromTable(senderCurrency, 'GNF')).rate;
        } catch {
          // pas de taux GNF → on ne bloque pas le preview
        }
      }
    }
    if (amountInGnf < MIN_TRANSFER_AMOUNT_GNF) {
      res.status(400).json({ success: false, error: `Montant minimum: ${MIN_TRANSFER_AMOUNT_GNF.toLocaleString('fr-FR')} GNF (équivalent)` });
      return;
    }
    if (amountInGnf > MAX_TRANSFER_AMOUNT_GNF) {
      res.status(400).json({ success: false, error: `Montant maximum: ${MAX_TRANSFER_AMOUNT_GNF.toLocaleString('fr-FR')} GNF (équivalent)` });
      return;
    }

    res.json({
      success: true,
      is_international: isInternational,
      sender: {
        id: senderId,
        name: null,
        email: req.user?.email || null,
        phone: null,
        custom_id: null,
      },
      receiver: {
        id: resolved.userId,
        name: resolved.displayName,
        email: resolved.email,
        phone: resolved.phone,
        custom_id: resolved.customId || resolved.publicId || null,
      },
      receiver_name: resolved.displayName,
      receiver_email: resolved.email,
      receiver_phone: resolved.phone,
      receiver_code: resolved.customId || resolved.publicId || resolved.userId,
      amount_sent: amount,
      currency_sent: senderCurrency,
      fee_percentage: feePercentage,
      fee_amount: feeAmount,
      amount_after_fee: amountAfterFee,
      total_debit: totalDebit,
      amount_received: amountReceived,
      currency_received: receiverCurrency,
      rate_displayed: rateDisplayed,
      sender_balance: senderBalance,
      balance_after: senderBalance - totalDebit,
      sender_country: mapCurrencyToCountry(senderCurrency),
      receiver_country: mapCurrencyToCountry(receiverCurrency),
      commission_conversion: commissionConversion,
      frais_international: feeAmount,
      rate_source: rateSource,
      rate_fetched_at: rateFetchedAt,
      rate_lock_seconds: 60,
    });
  } catch (error: any) {
    logger.error(`Wallet transfer preview error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la prévisualisation du transfert' });
  }
});

/**
 * GET /api/v2/wallet/balance
 * Récupère le solde du wallet de l'utilisateur connecté
 */
router.get('/balance', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('wallets')
      .select('id, balance, currency, wallet_status, is_blocked, daily_limit, monthly_limit, created_at')
      .eq('user_id', req.user!.id)
      .maybeSingle();

    if (error) throw error;

    res.json({ success: true, data: data || null, exists: !!data });
  } catch (error: any) {
    logger.error(`Wallet balance error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la récupération du solde' });
  }
});

/**
 * POST /api/v2/wallet/initialize
 * Initialise le wallet si inexistant
 */
router.post('/initialize', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;

    // Vérifier si le wallet existe
    const { data: existing, error: selectError } = await supabaseAdmin
      .from('wallets')
      .select('*')
      .eq('user_id', userId)
      .maybeSingle();

    if (selectError) throw selectError;

    if (existing) {
      res.json({ success: true, wallet: existing, created: false });
      return;
    }

    // Créer — la table utilise des defaults pour balance, currency, wallet_status, limits
    const { data: newWallet, error: insertError } = await supabaseAdmin
      .from('wallets')
      .insert({ user_id: userId })
      .select()
      .single();

    if (insertError) throw insertError;

    logger.info(`Wallet created for user: ${userId}`);
    res.status(201).json({ success: true, wallet: newWallet, created: true });
  } catch (error: any) {
    logger.error(`Wallet init error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'initialisation du wallet' });
  }
});

/**
 * GET /api/v2/wallet/transactions
 * Historique des transactions du wallet
 */
router.get('/transactions', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const limit = Math.min(parseInt(req.query.limit as string) || 20, 100);
    const offset = parseInt(req.query.offset as string) || 0;

    // Récupérer le wallet
    const { data: wallet } = await supabaseAdmin
      .from('wallets')
      .select('id')
      .eq('user_id', userId)
      .single();

    if (!wallet) {
      res.json({ success: true, data: [], meta: { total: 0, limit, offset, hasMore: false } });
      return;
    }

    // Transactions où l'utilisateur est sender OU receiver
    const { data, error, count } = await supabaseAdmin
      .from('wallet_transactions')
      .select('*', { count: 'exact' })
      .or(`sender_wallet_id.eq.${wallet.id},receiver_wallet_id.eq.${wallet.id}`)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (error) throw error;

    res.json({
      success: true,
      data: data || [],
      meta: { limit, offset, total: count || 0, hasMore: (offset + limit) < (count || 0) }
    });
  } catch (error: any) {
    logger.error(`Wallet transactions error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * GET /api/v2/wallet/status
 * Statut complet du wallet (sécurité, limites, blocage)
 */
router.get('/status', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { data, error } = await supabaseAdmin
      .from('wallets')
      .select('id, balance, currency, wallet_status, is_blocked, blocked_reason, blocked_at, biometric_enabled, daily_limit, monthly_limit, created_at, updated_at, pin_enabled, pin_failed_attempts, pin_locked_until, pin_updated_at')
      .eq('user_id', userId)
      .maybeSingle();

    if (!error) {
      if (!data) {
        res.json({ success: true, exists: false, data: null });
        return;
      }

      res.json({ success: true, exists: true, data });
      return;
    }

    const errorMessage = String(error.message || error.details || '');
    const pinSchemaMissing = /pin_hash|pin_enabled|pin_failed_attempts|pin_locked_until|pin_updated_at/i.test(errorMessage)
      && /column|does not exist|schema cache/i.test(errorMessage);

    if (!pinSchemaMissing) {
      throw error;
    }

    const [{ data: walletData, error: walletError }, pinState] = await Promise.all([
      supabaseAdmin
        .from('wallets')
        .select('id, balance, currency, wallet_status, is_blocked, blocked_reason, blocked_at, biometric_enabled, daily_limit, monthly_limit, created_at, updated_at')
        .eq('user_id', userId)
        .maybeSingle(),
      getWalletPinState(userId),
    ]);

    if (walletError) {
      throw walletError;
    }

    if (!walletData) {
      res.json({ success: true, exists: false, data: null });
      return;
    }

    res.json({
      success: true,
      exists: true,
      data: {
        ...walletData,
        pin_enabled: hasWalletPinEnabled(pinState),
        pin_failed_attempts: Number(pinState?.pin_failed_attempts || 0),
        pin_locked_until: pinState?.pin_locked_until || null,
        pin_updated_at: pinState?.pin_updated_at || null,
      },
    });
  } catch (error: any) {
    logger.error(`Wallet status error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

router.get('/pin/status', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const wallet = await ensureWalletExistsForPin(req.user!.id);
    res.json({
      success: true,
      data: {
        pin_enabled: hasWalletPinEnabled(wallet),
        pin_failed_attempts: Number(wallet?.pin_failed_attempts || 0),
        pin_locked_until: wallet?.pin_locked_until || null,
        pin_updated_at: wallet?.pin_updated_at || null,
        policy: getWalletPinPolicy(),
      },
    });
  } catch (error: any) {
    logger.error(`Wallet pin status error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du chargement du statut PIN' });
  }
});

router.post('/pin/setup', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { pin, confirm_pin, confirmPin } = req.body || {};
    const confirmPinValue = confirm_pin ?? confirmPin;

    if (typeof pin !== 'string' || typeof confirmPinValue !== 'string') {
      res.status(400).json({ success: false, error: 'pin et confirm_pin requis' });
      return;
    }
    if (pin !== confirmPinValue) {
      res.status(400).json({ success: false, error: 'Les deux codes PIN ne correspondent pas' });
      return;
    }

    await setupWalletPin(req.user!.id, pin);
    res.json({ success: true, message: 'Code PIN configuré avec succès' });
  } catch (error: any) {
    logger.error(`Wallet pin setup error: ${error.message}`);
    res.status(400).json({ success: false, error: error.message || 'Erreur lors de la configuration du code PIN' });
  }
});

router.post('/pin/change', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { current_pin, new_pin, confirm_pin, currentPin, newPin, confirmPin } = req.body || {};
    const currentPinValue = current_pin ?? currentPin;
    const newPinValue = new_pin ?? newPin;
    const confirmPinValue = confirm_pin ?? confirmPin;

    if (typeof currentPinValue !== 'string' || typeof newPinValue !== 'string' || typeof confirmPinValue !== 'string') {
      res.status(400).json({ success: false, error: 'current_pin, new_pin et confirm_pin requis' });
      return;
    }
    if (newPinValue !== confirmPinValue) {
      res.status(400).json({ success: false, error: 'Le nouveau code PIN et sa confirmation ne correspondent pas' });
      return;
    }

    await changeWalletPin(req.user!.id, currentPinValue, newPinValue);
    res.json({ success: true, message: 'Code PIN modifié avec succès' });
  } catch (error: any) {
    logger.error(`Wallet pin change error: ${error.message}`);
    res.status(400).json({ success: false, error: error.message || 'Erreur lors du changement du code PIN' });
  }
});

router.post('/pin/reset', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { account_password, new_pin, confirm_pin, accountPassword, newPin, confirmPin } = req.body || {};
    const accountPasswordValue = account_password ?? accountPassword;
    const newPinValue = new_pin ?? newPin;
    const confirmPinValue = confirm_pin ?? confirmPin;

    if (typeof accountPasswordValue !== 'string' || typeof newPinValue !== 'string' || typeof confirmPinValue !== 'string') {
      res.status(400).json({ success: false, error: 'account_password, new_pin et confirm_pin requis' });
      return;
    }
    if (newPinValue !== confirmPinValue) {
      res.status(400).json({ success: false, error: 'Le nouveau code PIN et sa confirmation ne correspondent pas' });
      return;
    }

    await resetWalletPinWithPassword(req.user!.id, req.user?.email || null, accountPasswordValue, newPinValue);
    res.json({ success: true, message: 'Code PIN réinitialisé avec succès' });
  } catch (error: any) {
    logger.error(`Wallet pin reset error: ${error.message}`);
    res.status(400).json({ success: false, error: error.message || 'Erreur lors de la réinitialisation du code PIN' });
  }
});

// ─────────────────────────────────────────────────────────
// WALLET OPERATIONS — Migré depuis Edge Functions wallet-operations / wallet-transfer
// ─────────────────────────────────────────────────────────

/**
 * POST /api/v2/wallet/deposit
 * Crédite le wallet de l'utilisateur connecté.
 *
 * Auth : verifyJWT
 * Body : { amount, description?, reference?, idempotency_key? }
 */
router.post('/deposit', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { amount, description, reference, idempotency_key } = req.body || {};

    if (!amount || typeof amount !== 'number' || amount <= 0) {
      res.status(400).json({ success: false, error: 'Montant invalide' });
      return;
    }
    if (amount > 100000000) {
      res.status(400).json({ success: false, error: 'Montant trop élevé' });
      return;
    }

    const idemKey = idempotency_key || `deposit:${userId}:${amount}:${Math.floor(Date.now() / 60000)}`;
    const ref = reference || `dep_${Date.now()}`;

    const result = await creditWallet(userId, amount, description || 'Dépôt', ref, 'deposit', idemKey);

    if (!result.success) {
      await emitCoreFeatureEvent({
        featureKey: 'wallet.deposit',
        coreEngine: 'payment',
        ownerModule: 'wallet',
        criticality: 'high',
        status: 'failure',
        userId,
        payload: { amount, error: result.error || 'deposit_failed' },
      });
      res.status(400).json({ success: false, error: result.error });
      return;
    }

    // Déclencher commissions affiliées
    await triggerAffiliateCommission(userId, amount, 'deposit', ref);

    logger.info(`[WalletV2] Deposit: user=${userId}, amount=${amount}`);
    await emitCoreFeatureEvent({
      featureKey: 'wallet.deposit',
      coreEngine: 'payment',
      ownerModule: 'wallet',
      criticality: 'high',
      status: 'success',
      userId,
      payload: { amount },
    });
    res.json({ success: true, new_balance: result.newBalance, operation: 'deposit' });
  } catch (error: any) {
    logger.error(`Wallet deposit error: ${error.message}`);
    await emitCoreFeatureEvent({
      featureKey: 'wallet.deposit',
      coreEngine: 'payment',
      ownerModule: 'wallet',
      criticality: 'high',
      status: 'failure',
      userId: req.user?.id || null,
      payload: { error: error.message },
    });
    res.status(500).json({ success: false, error: 'Erreur lors du dépôt' });
  }
});

/**
 * POST /api/v2/wallet/withdraw
 * Débite le wallet de l'utilisateur connecté.
 *
 * Auth : verifyJWT
 * Body : { amount, description?, idempotency_key }
 */
router.post('/withdraw', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { amount, description, idempotency_key, pin } = req.body || {};

    if (!amount || typeof amount !== 'number' || amount <= 0) {
      res.status(400).json({ success: false, error: 'Montant invalide' });
      return;
    }

    const pinCheck = await requireValidTransactionPin(userId, pin);
    if (!pinCheck.ok) {
      await emitCoreFeatureEvent({
        featureKey: 'wallet.withdraw',
        coreEngine: 'payment',
        ownerModule: 'wallet',
        criticality: 'critical',
        status: 'failure',
        userId,
        payload: { amount, reason: pinCheck.error || 'pin_invalid' },
      });
      res.status(403).json({ success: false, error: pinCheck.error, locked_until: pinCheck.lockedUntil || null });
      return;
    }

    const idemKey = idempotency_key || `withdraw:${userId}:${amount}:${crypto.randomBytes(8).toString('hex')}`;

    const result = await debitWallet(userId, amount, description || 'Retrait', idemKey);

    if (!result.success) {
      await emitCoreFeatureEvent({
        featureKey: 'wallet.withdraw',
        coreEngine: 'payment',
        ownerModule: 'wallet',
        criticality: 'critical',
        status: 'failure',
        userId,
        payload: { amount, error: result.error || 'withdraw_failed' },
      });
      const statusCode = result.error === 'Solde insuffisant' ? 402
        : result.error === 'Wallet bloqué' ? 403
          : result.error?.includes('activité suspecte') ? 403
            : 400;
      res.status(statusCode).json({ success: false, error: result.error });
      return;
    }

    logger.info(`[WalletV2] Withdraw: user=${userId}, amount=${amount}`);
    await emitCoreFeatureEvent({
      featureKey: 'wallet.withdraw',
      coreEngine: 'payment',
      ownerModule: 'wallet',
      criticality: 'critical',
      status: 'success',
      userId,
      payload: { amount },
    });
    res.json({ success: true, new_balance: result.newBalance, operation: 'withdraw' });
  } catch (error: any) {
    logger.error(`Wallet withdraw error: ${error.message}`);
    await emitCoreFeatureEvent({
      featureKey: 'wallet.withdraw',
      coreEngine: 'payment',
      ownerModule: 'wallet',
      criticality: 'critical',
      status: 'failure',
      userId: req.user?.id || null,
      payload: { error: error.message },
    });
    res.status(500).json({ success: false, error: 'Erreur lors du retrait' });
  }
});

/**
 * POST /api/v2/wallet/transfer
 * Transfert P2P entre deux wallets.
 *
 * Auth : verifyJWT
 * Body : { amount, recipient_id (UUID), description?, idempotency_key? }
 */
router.post('/transfer', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const senderId = req.user!.id;
    const { amount, recipient_id, description, idempotency_key, pin, expected_rate } = req.body || {};

    if (!amount || typeof amount !== 'number' || amount <= 0) {
      res.status(400).json({ success: false, error: 'Montant invalide' });
      return;
    }

    if (!recipient_id || typeof recipient_id !== 'string' || !recipient_id.trim()) {
      res.status(400).json({ success: false, error: 'recipient_id requis' });
      return;
    }

    const resolvedRecipientId = await resolveRecipientUserId(recipient_id.trim());
    if (!resolvedRecipientId) {
      res.status(404).json({ success: false, error: 'Destinataire introuvable (UUID, ID public, email ou téléphone)' });
      return;
    }

    if (resolvedRecipientId === senderId) {
      res.status(400).json({ success: false, error: 'Transfert vers soi-même non autorisé' });
      return;
    }

    const pinCheck = await requireValidTransactionPin(senderId, pin);
    if (!pinCheck.ok) {
      await emitCoreFeatureEvent({
        featureKey: 'wallet.transfer',
        coreEngine: 'payment',
        ownerModule: 'wallet',
        criticality: 'critical',
        status: 'failure',
        userId: senderId,
        payload: { amount, recipient_id, resolved_recipient_id: resolvedRecipientId, reason: pinCheck.error || 'pin_invalid' },
      });
      res.status(403).json({ success: false, error: pinCheck.error, locked_until: pinCheck.lockedUntil || null });
      return;
    }

    // Vérifier que le destinataire existe
    let { data: recipient } = await supabaseAdmin
      .from('wallets')
      .select('user_id')
      .eq('user_id', resolvedRecipientId)
      .maybeSingle();

    if (!recipient) {
      // Auto-initialiser le wallet destinataire pour éviter les échecs sur comptes PDG/agent nouvellement créés
      const { error: initError } = await supabaseAdmin
        .from('wallets')
        .insert({ user_id: resolvedRecipientId })
        .select('user_id')
        .single();

      if (initError) {
        res.status(404).json({ success: false, error: 'Wallet destinataire introuvable' });
        return;
      }

      recipient = { user_id: resolvedRecipientId } as any;
    }

    const [{ data: senderWallet }, { data: recipientWallet }] = await Promise.all([
      supabaseAdmin
        .from('wallets')
        .select('currency')
        .eq('user_id', senderId)
        .maybeSingle(),
      supabaseAdmin
        .from('wallets')
        .select('currency')
        .eq('user_id', resolvedRecipientId)
        .maybeSingle(),
    ]);

    const senderCurrency = String(senderWallet?.currency || 'GNF').toUpperCase();
    const receiverCurrency = String(recipientWallet?.currency || senderCurrency).toUpperCase();
    const isInternational = senderCurrency !== receiverCurrency;
    let rateUsed = 1;
    let rateSource = 'identity';
    let amountToCredit = amount;

    if (isInternational) {
      const fxResult = await getInternalFxRateFromTable(senderCurrency, receiverCurrency);
      rateUsed = fxResult.rate; // TAUX NET du jour
      rateSource = fxResult.source;

      // GARDE ANTI-DÉRIVE DE TAUX : si le taux BCRG a bougé de plus de 2% depuis le preview
      // (expected_rate envoyé par le front), on REJETTE → l'utilisateur ne valide jamais un
      // montant périmé. Le débit/crédit utilisent ensuite ce taux frais, de façon atomique.
      const expRate = Number(expected_rate);
      if (Number.isFinite(expRate) && expRate > 0 && rateUsed > 0
          && Math.abs(rateUsed - expRate) / expRate > 0.02) {
        res.status(409).json({
          success: false,
          error: 'Le taux de change a changé depuis l\'aperçu. Veuillez relancer la prévisualisation.',
          rate_changed: true,
          previous_rate: expRate,
          current_rate: rateUsed,
        });
        return;
      }

      // Destinataire crédité au taux NET (la commission est prélevée EN PLUS, ci-dessous)
      amountToCredit = smartRoundCurrencyAmount(amount * rateUsed, receiverCurrency);
    }

    // COMMISSION FX (internationale uniquement) prélevée EN PLUS sur l'expéditeur.
    // Total débité = montant + commission. Le destinataire reçoit montant × taux NET.
    // La commission reste dans le float plateforme (débitée mais non recréditée).
    const commissionRate = isInternational ? await getFxCommissionRate() : 0;
    const feeAmount = isInternational
      ? smartRoundCurrencyAmount(amount * commissionRate, senderCurrency)
      : 0;

    // ── LIMITE de transfert vérifiée sur l'ÉQUIVALENT GNF du montant envoyé ──
    // Bornes pilotées par le PDG (pdg_settings) — national vs international.
    const { min: MIN_TRANSFER_AMOUNT_GNF, max: MAX_TRANSFER_AMOUNT_GNF } = await getTransferBoundsGnf(isInternational);
    let amountInGnf = amount;
    if (senderCurrency !== 'GNF') {
      if (receiverCurrency === 'GNF') {
        amountInGnf = amountToCredit; // déjà = montant × taux(expéditeur→GNF)
      } else {
        try {
          amountInGnf = amount * (await getInternalFxRateFromTable(senderCurrency, 'GNF')).rate;
        } catch {
          // Aucun taux vers GNF disponible → on ne bloque pas faute d'étalon.
        }
      }
    }
    if (amountInGnf < MIN_TRANSFER_AMOUNT_GNF) {
      res.status(400).json({ success: false, error: `Montant minimum: ${MIN_TRANSFER_AMOUNT_GNF.toLocaleString('fr-FR')} GNF (équivalent)` });
      return;
    }
    if (amountInGnf > MAX_TRANSFER_AMOUNT_GNF) {
      res.status(400).json({ success: false, error: `Montant maximum: ${MAX_TRANSFER_AMOUNT_GNF.toLocaleString('fr-FR')} GNF (équivalent)` });
      return;
    }

    // ── Description : pour un transfert INTERNATIONAL, on inscrit la conversion
    // dans la description pour que le DESTINATAIRE voie « X EUR envoyé → Y GNF reçu ».
    const fmtMoney = (n: number) => n.toLocaleString('fr-FR', { maximumFractionDigits: 2 });
    const finalDescription = isInternational
      ? `${description ? `${description} — ` : ''}${fmtMoney(amount)} ${senderCurrency} envoyé → ${fmtMoney(amountToCredit)} ${receiverCurrency} reçu`
      : (description || 'Transfert');

    const idemKey = idempotency_key || `transfer:${senderId}:${resolvedRecipientId}:${amount}:${crypto.randomBytes(8).toString('hex')}`;

    const result = await transferBetweenWallets(
      senderId,
      resolvedRecipientId,
      amount,
      finalDescription,
      idemKey,
      {
        amountToCredit,
        senderCurrency,
        receiverCurrency,
        isInternational,
        rateUsed,
        rateSource,
        feeAmount,
      },
    );

    if (!result.success) {
      await emitCoreFeatureEvent({
        featureKey: 'wallet.transfer',
        coreEngine: 'payment',
        ownerModule: 'wallet',
        criticality: 'critical',
        status: 'failure',
        userId: senderId,
        payload: { amount, recipient_id, resolved_recipient_id: resolvedRecipientId, error: result.error || 'transfer_failed' },
      });
      const statusCode = result.error === 'Solde insuffisant' ? 402
        : result.error?.includes('bloqué') ? 403
          : 400;
      res.status(statusCode).json({ success: false, error: result.error });
      return;
    }

    logger.info(`[WalletV2] Transfer: sender=${senderId}, receiver=${resolvedRecipientId}, amount=${amount}, credited=${amountToCredit}, ${senderCurrency}->${receiverCurrency}`);

    // 🔔 Notifications transfert (in-app + email/SMS via le funnel notifications). Best-effort.
    const fmt = (n: number, cur: string) => `${Number(n).toLocaleString('fr-FR')} ${cur}`;
    await Promise.allSettled([
      createNotification({
        userId: senderId,
        title: 'Transfert envoyé',
        message: `Vous avez envoyé ${fmt(amount, senderCurrency)}${feeAmount ? ` (frais : ${fmt(feeAmount, senderCurrency)})` : ''}.`,
        type: 'transfer',
        metadata: { transaction_id: result.transactionId, direction: 'sent', amount, currency: senderCurrency, fee: feeAmount, recipient_id: resolvedRecipientId },
      }),
      createNotification({
        userId: resolvedRecipientId,
        title: 'Transfert reçu',
        message: `Vous avez reçu ${fmt(amountToCredit, receiverCurrency)} sur votre wallet.`,
        type: 'transfer',
        metadata: { transaction_id: result.transactionId, direction: 'received', amount: amountToCredit, currency: receiverCurrency, sender_id: senderId },
      }),
    ]);

    await emitCoreFeatureEvent({
      featureKey: 'wallet.transfer',
      coreEngine: 'payment',
      ownerModule: 'wallet',
      criticality: 'critical',
      status: 'success',
      userId: senderId,
      payload: {
        amount,
        amount_received: amountToCredit,
        recipient_id,
        resolved_recipient_id: resolvedRecipientId,
        is_international: isInternational,
        sender_currency: senderCurrency,
        receiver_currency: receiverCurrency,
        rate_used: rateUsed,
      },
    });
    res.json({
      success: true,
      transaction_id: result.transactionId,
      operation: 'transfer',
      is_international: isInternational,
      amount_sent: amount,
      amount_received: amountToCredit,
      currency_sent: senderCurrency,
      currency_received: receiverCurrency,
      fee_amount: feeAmount,
      fee_percentage: commissionRate * 100,
      total_debit: smartRoundCurrencyAmount(amount + feeAmount, senderCurrency),
      rate_used: rateUsed,
      rate_source: rateSource,
    });
  } catch (error: any) {
    logger.error(`Wallet transfer error: ${error.message}`);
    await emitCoreFeatureEvent({
      featureKey: 'wallet.transfer',
      coreEngine: 'payment',
      ownerModule: 'wallet',
      criticality: 'critical',
      status: 'failure',
      userId: req.user?.id || null,
      payload: { error: error.message },
    });
    res.status(500).json({ success: false, error: 'Erreur lors du transfert' });
  }
});

/**
 * POST /api/v2/wallet/credit
 * Crédit admin/interne d'un wallet (service rôle uniquement).
 * Utilisé par les admins pour créditer manuellement un vendeur/affilié.
 *
 * Auth : verifyJWT + rôle admin/PDG/CEO
 * Body : { user_id, amount, description, reference?, transaction_type? }
 */
router.post(
  '/credit',
  verifyJWT,
  requirePermissionOrRole({
    permissionKey: 'manage_wallet_transactions',
    allowedRoles: ['admin', 'pdg', 'ceo'],
  }),
  async (req: AuthenticatedRequest, res: Response) => {
    try {
      const actorId = req.user!.id;

      const { user_id, amount, description, reference, transaction_type = 'admin_credit' } = req.body || {};

      if (!user_id || !amount || typeof amount !== 'number' || amount <= 0) {
        res.status(400).json({ success: false, error: 'user_id et amount (positif) requis' });
        return;
      }

      const ref = reference || `admin_${Date.now()}`;
      const result = await creditWallet(user_id, amount, description || 'Crédit administrateur', ref, transaction_type);

      if (!result.success) {
        res.status(400).json({ success: false, error: result.error });
        return;
      }

      // Audit log
      await ignoreSupabaseError(supabaseAdmin.from('financial_audit_logs').insert({
        user_id: actorId,
        action_type: 'admin_credit',
        description: `Crédit admin: ${amount} GNF → user=${user_id}`,
        request_data: { user_id, amount, description, reference: ref },
      }));

      logger.info(`[WalletV2] Admin credit: actor=${actorId}, target=${user_id}, amount=${amount}`);
      res.json({ success: true, new_balance: result.newBalance, operation: 'admin_credit' });
    } catch (error: any) {
      logger.error(`Wallet credit error: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors du crédit' });
    }
  });

/**
 * GET /api/v2/wallet/admin/fx-health
 * Dashboard FX pour PDG/Admin (fraicheur + alertes + sources bancaires)
 */
router.get(
  '/admin/fx-health',
  verifyJWT,
  requirePermissionOrRole({
    permissionKey: 'manage_wallet_transactions',
    allowedRoles: ['admin', 'pdg', 'ceo'],
  }),
  async (_req: AuthenticatedRequest, res: Response) => {
    try {
      const now = Date.now();
      // Conakry uses UTC+0; use UTC start-of-day to avoid host machine/local timezone drift.
      const startOfDay = new Date();
      startOfDay.setUTCHours(0, 0, 0, 0);
      const startOfDayIso = startOfDay.toISOString();

      const [{ data: latestAnyRate }, { data: latestUsdGnfRate }, { data: recentRuns }, { data: unresolvedAlerts }, { data: todayRates }, { data: marginConfig }] = await Promise.all([
        supabaseAdmin
          .from('currency_exchange_rates')
          .select('from_currency, to_currency, rate, margin, final_rate_usd, final_rate_eur, source, source_type, source_url, retrieved_at')
          .eq('is_active', true)
          .order('retrieved_at', { ascending: false })
          .limit(1)
          .maybeSingle(),
        supabaseAdmin
          .from('currency_exchange_rates')
          .select('from_currency, to_currency, rate, margin, final_rate_usd, final_rate_eur, source, source_type, source_url, retrieved_at, last_bcrg_scraped_at')
          .eq('is_active', true)
          .eq('from_currency', 'USD')
          .eq('to_currency', 'GNF')
          .order('retrieved_at', { ascending: false })
          .limit(1)
          .maybeSingle(),
        supabaseAdmin
          .from('fx_collection_log')
          .select('currency_code, status, source, source_url, source_type, error_message, collected_at')
          .order('collected_at', { ascending: false })
          .limit(30),
        supabaseAdmin
          .from('financial_security_alerts')
          .select('id, alert_type, severity, title, description, created_at, metadata')
          .like('alert_type', 'fx_%')
          .eq('is_resolved', false)
          .order('created_at', { ascending: false })
          .limit(20),
        supabaseAdmin
          .from('currency_exchange_rates')
          .select('from_currency, to_currency, rate, margin, final_rate_usd, final_rate_eur, source, source_type, source_url, retrieved_at')
          .eq('is_active', true)
          .gte('retrieved_at', startOfDayIso)
          .order('retrieved_at', { ascending: false })
          .limit(200),
        supabaseAdmin
          .from('margin_config')
          .select('config_value')
          .eq('config_key', 'default_margin')
          .maybeSingle(),
      ]);

      const liveBcrgRate = await fetchLiveBcrgUsdGnf();
      const fallbackRate: any = latestUsdGnfRate || latestAnyRate || null;
      const configuredMarginRaw = Number(marginConfig?.config_value ?? fallbackRate?.margin ?? 0.03);
      const currentMargin = Number.isFinite(configuredMarginRaw) ? configuredMarginRaw : 0.03;
      const currentRateBase = fallbackRate
        ? {
          ...fallbackRate,
          margin: currentMargin,
          configured_margin: currentMargin,
          final_rate_usd: Number.isFinite(Number(fallbackRate?.rate))
            ? Number(fallbackRate.rate) * (1 + currentMargin)
            : fallbackRate?.final_rate_usd ?? null,
          final_rate_eur:
            Number.isFinite(Number(fallbackRate?.final_rate_eur)) && Number.isFinite(Number(fallbackRate?.margin))
              ? (Number(fallbackRate.final_rate_eur) / (1 + Number(fallbackRate.margin))) * (1 + currentMargin)
              : fallbackRate?.final_rate_eur ?? null,
        }
        : null;
      // ÂGE = fraîcheur du taux RÉELLEMENT STOCKÉ (celui utilisé pour les transactions, écrit par le
      // job toutes les minutes). On préfère last_bcrg_scraped_at (n'avance qu'à un vrai scrape réussi)
      // → si le job d'écriture meurt, l'âge grimpe même si le re-scrape d'affichage réussit.
      // Avant : retrieved_at = horodatage du re-scrape d'affichage (NOW) → âge toujours ~00:00 (trompeur).
      const storedRateAgeIso: string | null =
        (latestUsdGnfRate as any)?.last_bcrg_scraped_at
        || latestUsdGnfRate?.retrieved_at
        || latestAnyRate?.retrieved_at
        || null;
      const currentRate = liveBcrgRate
        ? {
          ...(currentRateBase || {}),
          from_currency: 'USD',
          to_currency: 'GNF',
          rate: liveBcrgRate.usdGnf,
          margin: currentMargin,
          configured_margin: currentMargin,
          final_rate_usd: liveBcrgRate.usdGnf * (1 + currentMargin),
          final_rate_eur: liveBcrgRate.eurGnf ? liveBcrgRate.eurGnf * (1 + currentMargin) : currentRateBase?.final_rate_eur ?? null,
          source: 'bcrg-live-widget',
          source_type: 'official_html',
          source_url: BCRG_OFFICIAL_URL,
          // L'âge reflète le taux stocké ; on expose le moment du re-scrape d'affichage à part.
          retrieved_at: storedRateAgeIso || liveBcrgRate.retrievedAt,
          live_checked_at: liveBcrgRate.retrievedAt,
        }
        : currentRateBase;
      const lastRetrievedAt = currentRate?.retrieved_at ? new Date(currentRate.retrieved_at).getTime() : null;
      const ageMinutes = lastRetrievedAt ? Math.floor((now - lastRetrievedAt) / 60000) : null;
      // Cadence de scrape = 1 min → on tolère un cycle manqué et on marque « Stale » au-delà de 2 min.
      const staleThresholdMinutes = 2;
      const stale = ageMinutes === null || ageMinutes > staleThresholdMinutes;

      const runRows = recentRuns || [];
      const recentGnfRuns = runRows
        .filter((row) => row.currency_code === 'GNF')
        .slice(0, 2);
      const twoConsecutiveFailures = recentGnfRuns.length >= 2 && recentGnfRuns.every((row) => !isFxSuccessStatus(row.status));

      const todaysHistory = (todayRates || [])
        .filter((rate: any) => isAfricanBankRow(rate))
        .map((rate: any) => ({
          from_currency: rate.from_currency,
          to_currency: rate.to_currency,
          rate: rate.rate,
          margin: rate.margin,
          final_rate_usd: rate.final_rate_usd,
          final_rate_eur: rate.final_rate_eur,
          source: rate.source,
          source_type: rate.source_type,
          source_url: resolveOfficialBankSourceUrl(rate),
          retrieved_at: rate.retrieved_at,
        }));

      const sourceMap = new Map<string, { source: string | null; source_type: string | null; source_url: string | null; last_seen_at: string | null }>();
      const upsertSource = (entry: { source?: string | null; source_type?: string | null; source_url?: string | null; last_seen_at?: string | null }) => {
        const key = entry.source_url || `${entry.source || 'source'}:${entry.source_type || 'type'}`;
        if (!key) return;
        const current = sourceMap.get(key);
        const next = {
          source: entry.source || null,
          source_type: entry.source_type || null,
          source_url: entry.source_url || null,
          last_seen_at: entry.last_seen_at || null,
        };
        if (!current) {
          sourceMap.set(key, next);
          return;
        }
        const currentTs = current.last_seen_at ? new Date(current.last_seen_at).getTime() : 0;
        const nextTs = next.last_seen_at ? new Date(next.last_seen_at).getTime() : 0;
        if (nextTs >= currentTs) {
          sourceMap.set(key, next);
        }
      };

      for (const row of runRows.filter((row) => isAfricanBankRow(row))) {
        upsertSource({
          source: row.source,
          source_type: row.source_type,
          source_url: resolveOfficialBankSourceUrl(row),
          last_seen_at: row.collected_at,
        });
      }

      for (const rate of todaysHistory) {
        upsertSource({
          source: null,
          source_type: rate.source_type,
          source_url: rate.source_url,
          last_seen_at: rate.retrieved_at,
        });
      }

      const hasBcrgSource = Array.from(sourceMap.values()).some((source) => String(source?.source_url || '').includes('bcrg-guinee.org'));
      if (!hasBcrgSource) {
        upsertSource({
          source: 'Banque Centrale de Guinee (BCRG)',
          source_type: 'official_html',
          source_url: BCRG_OFFICIAL_URL,
          last_seen_at: currentRate?.retrieved_at || null,
        });
      }

      const bankSources = Array.from(sourceMap.values()).sort((a, b) => {
        const aTs = a.last_seen_at ? new Date(a.last_seen_at).getTime() : 0;
        const bTs = b.last_seen_at ? new Date(b.last_seen_at).getTime() : 0;
        return bTs - aTs;
      });

      const gnfTodayHistory = todaysHistory.filter((rate: any) => rate.from_currency === 'GNF' || rate.to_currency === 'GNF');

      // key_rates : taux X→GNF affichés sur le tableau de bord (EUR/GBP/XOF/XAF/CAD).
      // Source = derniers taux officiels en base (currency_exchange_rates), final recalculé avec la marge courante.
      const latestByCurrency = new Map<string, any>();
      for (const r of (todayRates || [])) {
        if (r.to_currency !== 'GNF') continue;
        const prev = latestByCurrency.get(r.from_currency);
        if (!prev || new Date(r.retrieved_at).getTime() > new Date(prev.retrieved_at).getTime()) {
          latestByCurrency.set(r.from_currency, r);
        }
      }
      // RÈGLE : n'afficher QUE les taux réellement publiés par le BCRG (widget officiel).
      // Le BCRG ne publie PAS le XAF (CFA CEMAC) → on ne l'affiche pas. Aucune dérivation/fallback.
      const keyRates: Record<string, any> = {};
      for (const cur of ['EUR', 'GBP', 'XOF', 'CAD']) {
        const row = latestByCurrency.get(cur);
        const rate = Number(row?.rate);
        const isBcrg = !!row && (String(row.source || '').toLowerCase().includes('bcrg') || isAfricanBankSourceUrl(row.source_url));
        if (!row || !Number.isFinite(rate) || !isBcrg) continue;
        keyRates[`${cur}_GNF`] = {
          rate,
          final_rate: rate * (1 + currentMargin),
          retrieved_at: row.retrieved_at,
          source: row.source,
          source_url: row.source_url,
        };
      }

      res.json({
        success: true,
        data: {
          timezone: 'Africa/Conakry',
          start_of_day_iso: startOfDayIso,
          stale_threshold_minutes: staleThresholdMinutes,
          is_stale: stale,
          age_minutes: ageMinutes,
          last_rate: currentRateBase || null,
          configured_margin: currentMargin,
          two_consecutive_failures: twoConsecutiveFailures,
          current_rate: currentRate || null,
          key_rates: keyRates,
          recent_runs: runRows.slice(0, 10),
          today_history: todaysHistory,
          gnf_today_history: gnfTodayHistory,
          bank_sources: bankSources,
          active_alerts: unresolvedAlerts || [],
        },
      });
    } catch (error: any) {
      logger.error(`FX health error: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors du chargement du monitoring FX' });
    }
  }
);

/**
 * GET /api/v2/wallet/admin/fx-conversion-stats
 * Statistiques conversions/transferts: volume utilisateur, pays et corridors pays->pays
 */
router.get(
  '/admin/fx-conversion-stats',
  verifyJWT,
  requirePermissionOrRole({
    permissionKey: 'manage_wallet_transactions',
    allowedRoles: ['admin', 'pdg', 'ceo'],
  }),
  async (req: AuthenticatedRequest, res: Response) => {
    try {
      // Fenêtre dynamique : le frontend envoie ?hours=24|72|168|720. Avant : forcé à 24h (bug).
      const hoursRaw = Number((req.query.hours as string) ?? 24);
      const windowHours = Number.isFinite(hoursRaw) && hoursRaw > 0 ? Math.min(hoursRaw, 24 * 366) : 24;
      const sinceIso = new Date(Date.now() - windowHours * 3600000).toISOString();

      // SOURCE = enhanced_transactions (1 ligne par transfert, avec metadata.is_international +
      // sender_currency/receiver_currency). Avant : wallet_transactions filtré sur transaction_type
      // ='transfer' QUI N'EXISTE PAS (types réels : transfer_out/transfer_in/payment…) → toujours 0.
      const [{ data: txRows }, { data: profiles }] = await Promise.all([
        supabaseAdmin
          .from('enhanced_transactions')
          .select('id, sender_id, receiver_id, amount, currency, method, status, metadata, created_at')
          .eq('status', 'completed')
          .gte('created_at', sinceIso)
          .order('created_at', { ascending: false })
          .limit(5000),
        supabaseAdmin
          .from('profiles')
          .select('id, country, email, first_name, last_name'),
      ]);

      const profileMap = new Map((profiles || []).map((p: any) => [p.id, p]));

      const byUser = new Map<string, { user_id: string; user_label: string; country: string; conversions_count: number; total_amount: number }>();
      const byCountry = new Map<string, { country: string; conversions_count: number; total_amount: number }>();
      const countryCorridors = new Map<string, { from_country: string; to_country: string; conversions_count: number; total_amount: number }>();
      const transactions: any[] = [];   // onglet « Transactions »
      const rateHistory: any[] = [];    // onglet « Taux » (taux appliqués aux transferts internationaux)

      let totalConversions = 0;
      let internationalConversions = 0;

      for (const tx of txRows || []) {
        const meta: any = tx.metadata || {};
        const senderProfile: any = tx.sender_id ? profileMap.get(tx.sender_id) : null;
        const receiverProfile: any = tx.receiver_id ? profileMap.get(tx.receiver_id) : null;

        const senderCurrency = meta.sender_currency || tx.currency || null;
        const receiverCurrency = meta.receiver_currency || tx.currency || null;
        // Pays basé sur la devise (zone monétaire) — pertinent pour un tableau de conversions FX ;
        // repli sur le pays du profil si la devise est absente.
        const senderCountry = senderCurrency ? mapCurrencyToCountry(senderCurrency) : String(senderProfile?.country || 'Inconnu');
        const receiverCountry = receiverCurrency ? mapCurrencyToCountry(receiverCurrency) : String(receiverProfile?.country || 'Inconnu');
        // International : flag explicite du transfert, sinon devises différentes.
        const isInternational = meta.is_international === true || (!!senderCurrency && !!receiverCurrency && senderCurrency !== receiverCurrency);
        const amount = Number(meta.amount_sent ?? tx.amount ?? 0);

        totalConversions += 1;
        if (isInternational) internationalConversions += 1;

        if (tx.sender_id) {
          const senderName = `${String(senderProfile?.first_name || '').trim()} ${String(senderProfile?.last_name || '').trim()}`.trim();
          const senderLabel = String(meta.sender_name || '').trim() || senderName || String(senderProfile?.email || tx.sender_id);

          const currentUser = byUser.get(tx.sender_id) || {
            user_id: tx.sender_id,
            user_label: senderLabel,
            country: senderCountry,
            conversions_count: 0,
            total_amount: 0,
          };
          currentUser.conversions_count += 1;
          currentUser.total_amount += amount;
          byUser.set(tx.sender_id, currentUser);
        }

        const senderCountryStats = byCountry.get(senderCountry) || {
          country: senderCountry,
          conversions_count: 0,
          total_amount: 0,
        };
        senderCountryStats.conversions_count += 1;
        senderCountryStats.total_amount += amount;
        byCountry.set(senderCountry, senderCountryStats);

        const corridorKey = `${senderCountry}=>${receiverCountry}`;
        const corridorStats = countryCorridors.get(corridorKey) || {
          from_country: senderCountry,
          to_country: receiverCountry,
          conversions_count: 0,
          total_amount: 0,
        };
        corridorStats.conversions_count += 1;
        corridorStats.total_amount += amount;
        countryCorridors.set(corridorKey, corridorStats);

        // Détail transaction (onglet « Transactions »)
        const senderName = String(meta.sender_name || '').trim()
          || `${String(senderProfile?.first_name || '').trim()} ${String(senderProfile?.last_name || '').trim()}`.trim()
          || String(senderProfile?.email || tx.sender_id || '—');
        const receiverName = String(meta.receiver_name || '').trim()
          || `${String(receiverProfile?.first_name || '').trim()} ${String(receiverProfile?.last_name || '').trim()}`.trim()
          || String(receiverProfile?.email || tx.receiver_id || '—');
        const amountSent = Number(meta.amount_sent ?? tx.amount ?? 0);
        const amountReceived = Number(meta.amount_received ?? meta.amount_sent ?? tx.amount ?? 0);
        const rateUsed = Number(meta.rate_used ?? 1);
        transactions.push({
          id: tx.id,
          created_at: tx.created_at,
          is_international: isInternational,
          sender_name: senderName,
          receiver_name: receiverName,
          sender_country: senderCountry,
          receiver_country: receiverCountry,
          sender_currency: senderCurrency,
          receiver_currency: receiverCurrency,
          amount_sent: amountSent,
          amount_received: amountReceived,
          fee_amount: Number(meta.fee_amount ?? 0),
          rate_used: rateUsed,
          rate_source: meta.rate_source || null,
        });

        // Historique des taux appliqués (uniquement transferts internationaux avec un taux ≠ identité)
        if (isInternational && Number.isFinite(rateUsed) && rateUsed > 0 && senderCurrency && receiverCurrency) {
          rateHistory.push({
            retrieved_at: tx.created_at,
            effective_date: tx.created_at,
            from_currency: senderCurrency,
            to_currency: receiverCurrency,
            rate: rateUsed,
            margin: null,
            source: meta.rate_source || null,
            status: 'OK',
          });
        }
      }

      res.json({
        success: true,
        data: {
          window_hours: windowHours,
          total_conversions: totalConversions,
          international_conversions: internationalConversions,
          by_user: Array.from(byUser.values()).sort((a, b) => b.conversions_count - a.conversions_count).slice(0, 50),
          by_country: Array.from(byCountry.values()).sort((a, b) => b.conversions_count - a.conversions_count),
          country_corridors: Array.from(countryCorridors.values()).sort((a, b) => b.conversions_count - a.conversions_count).slice(0, 100),
          transactions: transactions.slice(0, 300),
          rate_history: rateHistory.slice(0, 300),
        },
      });
    } catch (error: any) {
      logger.error(`FX conversion stats error: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors du chargement des stats de conversion' });
    }
  }
);

/**
 * POST /api/v2/wallet/admin/fx-rate-alert-check
 * Bouton alerte: crée une alerte si un changement de taux est détecté en moins d'1h.
 */
router.post(
  '/admin/fx-rate-alert-check',
  verifyJWT,
  requirePermissionOrRole({
    permissionKey: 'manage_wallet_transactions',
    allowedRoles: ['admin', 'pdg', 'ceo'],
  }),
  async (req: AuthenticatedRequest, res: Response) => {
    try {
      const { data: rateRows } = await supabaseAdmin
        .from('currency_exchange_rates')
        .select('from_currency, to_currency, rate, source_url, retrieved_at')
        .eq('is_active', true)
        .order('retrieved_at', { ascending: false })
        .limit(100);

      const validRates = (rateRows || []).filter((r: any) => isAfricanBankSourceUrl(r?.source_url));
      if (validRates.length < 2) {
        res.json({ success: true, data: { alert_created: false, reason: 'not_enough_data' } });
        return;
      }

      const latest = validRates[0] as any;
      const previous = validRates.find((r: any) => r.from_currency === latest.from_currency && r.to_currency === latest.to_currency && r.retrieved_at !== latest.retrieved_at) as any;
      if (!previous) {
        res.json({ success: true, data: { alert_created: false, reason: 'no_previous_same_pair' } });
        return;
      }

      const latestTs = latest.retrieved_at ? new Date(latest.retrieved_at).getTime() : 0;
      const previousTs = previous.retrieved_at ? new Date(previous.retrieved_at).getTime() : 0;
      const minutesBetween = Math.abs(latestTs - previousTs) / 60000;

      const latestRate = Number(latest.rate || 0);
      const previousRate = Number(previous.rate || 0);
      const changed = latestRate > 0 && previousRate > 0 && latestRate !== previousRate;
      // Seuil d'alerte : 1 MINUTE (le BCRG est vérifié chaque minute).
      const changedUnderOneHour = changed && minutesBetween <= 1;

      let alertCreated = false;
      if (changedUnderOneHour) {
        const thresholdIso = new Date(Date.now() - 60000).toISOString();
        const { data: existing } = await supabaseAdmin
          .from('financial_security_alerts')
          .select('id')
          .eq('alert_type', 'fx_rate_change_under_1m')
          .eq('is_resolved', false)
          .gte('created_at', thresholdIso)
          .limit(1)
          .maybeSingle();

        if (!existing) {
          await ignoreSupabaseError(supabaseAdmin.from('financial_security_alerts').insert({
            user_id: SYSTEM_USER_ID,
            alert_type: 'fx_rate_change_under_1m',
            severity: 'high',
            title: 'Changement de taux detecte en moins d\'1 minute',
            description: `${latest.from_currency}/${latest.to_currency} a change de ${previousRate} a ${latestRate} en ${Math.round(minutesBetween)} minute(s).`,
            metadata: {
              actor_id: req.user!.id,
              latest,
              previous,
              minutes_between: Math.round(minutesBetween),
            },
          }));
          alertCreated = true;
        }
      }

      res.json({
        success: true,
        data: {
          alert_created: alertCreated,
          changed_under_one_hour: changedUnderOneHour,
          minutes_between: Math.round(minutesBetween),
          latest,
          previous,
        },
      });
    } catch (error: any) {
      logger.error(`FX rate alert check error: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors de la verification d\'alerte FX' });
    }
  }
);

/**
 * POST /api/v2/wallet/admin/fx-refresh
 * Déclenche manuellement une collecte des taux (PDG/Admin)
 */
router.post(
  '/admin/fx-margin',
  verifyJWT,
  requirePermissionOrRole({
    permissionKey: 'manage_wallet_transactions',
    allowedRoles: ['admin', 'pdg', 'ceo'],
  }),
  async (req: AuthenticatedRequest, res: Response) => {
    try {
      const marginPercentRaw = Number(req.body?.margin_percent);
      if (!Number.isFinite(marginPercentRaw) || marginPercentRaw < 0 || marginPercentRaw > 30) {
        res.status(400).json({ success: false, error: 'margin_percent invalide (attendu: 0 a 30)' });
        return;
      }

      const marginValue = marginPercentRaw / 100;
      const { error: upsertError } = await supabaseAdmin
        .from('margin_config')
        .upsert({
          config_key: 'default_margin',
          config_value: marginValue,
        }, { onConflict: 'config_key' });

      if (upsertError) {
        throw upsertError;
      }

      const refreshResult = await triggerAfricanFxCollection('pdg_margin_update', req.user!.id);

      if (!refreshResult.ok && !refreshResult.timedOut) {
        logger.warn(`FX margin update: refresh non confirmé (status=${refreshResult.status ?? 'n/a'})`);
      }

      res.json({
        success: true,
        data: {
          margin_percent: marginPercentRaw,
          margin_value: marginValue,
          refresh_triggered: refreshResult.ok,
          refresh_status: refreshResult.status,
          refresh_payload: refreshResult.payload,
          refresh_timed_out: refreshResult.timedOut,
        },
      });
    } catch (error: any) {
      logger.error(`FX margin update error: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors de la mise a jour de la commission FX' });
    }
  }
);

router.post(
  '/admin/fx-refresh',
  verifyJWT,
  requirePermissionOrRole({
    permissionKey: 'manage_wallet_transactions',
    allowedRoles: ['admin', 'pdg', 'ceo'],
  }),
  async (req: AuthenticatedRequest, res: Response) => {
    try {
      const refreshResult = await triggerAfricanFxCollection('pdg_manual_refresh', req.user!.id, 4000);

      if (!refreshResult.ok && !refreshResult.timedOut) {
        await ignoreSupabaseError(supabaseAdmin.from('financial_security_alerts').insert({
          user_id: SYSTEM_USER_ID,
          alert_type: 'fx_manual_refresh_failed',
          severity: 'high',
          title: 'Échec du refresh FX manuel',
          description: 'Le déclenchement manuel de la collecte FX a échoué.',
          metadata: {
            actor_id: req.user!.id,
            status: refreshResult.status,
            error: refreshResult.payload?.error || refreshResult.payload?.message || 'unknown',
          },
        }));

        res.status(refreshResult.status || 502).json({
          success: false,
          error: refreshResult.payload?.error || refreshResult.payload?.message || 'Le refresh FX manuel a échoué',
        });
        return;
      }

      res.json({
        success: true,
        data: refreshResult.payload || { queued: true },
        meta: {
          refresh_status: refreshResult.status,
          refresh_timed_out: refreshResult.timedOut,
        },
      });
    } catch (error: any) {
      logger.error(`FX manual refresh error: ${error.message}`);
      res.status(500).json({ success: false, error: 'Erreur lors du refresh FX manuel' });
    }
  }
);

export default router;
