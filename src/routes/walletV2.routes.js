/**
 * 💰 WALLET v2 ROUTES — JavaScript (compatible Node.js ESM sans compilation TS)
 *
 * Endpoints montés sur /api/v2/wallet :
 *   GET  /balance
 *   GET  /status
 *   GET  /transactions
 *   POST /initialize
 *   GET  /pin/status
 *   POST /pin/setup
 *   POST /pin/change
 *   POST /pin/reset
 */

import crypto from 'crypto';
import { Router } from 'express';
import { createClient } from '@supabase/supabase-js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { verifyJWT, requireRole } from '../middlewares/auth.middleware.js';

const router = Router();

// ────────────────────────────────────────────────────────────
// WALLET PIN — logique interne (portée depuis walletPin.service.ts)
// ────────────────────────────────────────────────────────────

const PIN_LENGTH = 6;
const MAX_FAILED_ATTEMPTS = 5;
const LOCKOUT_MINUTES = 15;
const PIN_RESET_MAX_FAILED_ATTEMPTS = 5;
const PIN_RESET_LOCKOUT_MINUTES = 30;
const WALLET_PIN_SCHEMA_MISSING_MESSAGE =
  'Le schéma PIN wallet n\'est pas encore appliqué en base. Exécutez la migration 20260408193000_wallet_pin_schema_compat.sql.';
const ACCOUNT_PASSWORD_REQUIRED_MESSAGE =
  'Entrez le mot de passe de votre compte pour réinitialiser le PIN.';
const ACCOUNT_PASSWORD_INVALID_MESSAGE = 'Mot de passe du compte incorrect.';
const ACCOUNT_PASSWORD_RESET_UNAVAILABLE_MESSAGE =
  'Réinitialisation du PIN indisponible pour ce compte. Contactez le support.';
const SYSTEM_USER_ID = '00000000-0000-0000-0000-000000000000';
const BCRG_OFFICIAL_URL = 'https://www.bcrg-guinee.org';
const AFRICAN_BANK_SOURCE_URLS = [
  BCRG_OFFICIAL_URL,
  'https://www.bceao.int',
  'https://www.beac.int',
  'https://www.cbn.gov.ng',
  'https://www.resbank.co.za',
  'https://www.ecobank.com',
  'https://www.orabank.net',
  'https://www.afreximbank.com',
];
const BCRG_SCRAPE_URLS = [
  'https://www.bcrg-guinee.org',
  'https://www.bcrg-guinee.org/cours-de-change',
  'https://www.bcrg.gov.gn',
  'https://www.bcrg.gov.gn/cours-de-change',
];

function validatePinFormat(pin) {
  return /^\d{6}$/.test(pin);
}

function isWeakPin(pin) {
  if (/^(\d)\1{5}$/.test(pin)) return true;
  if (['012345', '123456', '234567', '345678', '456789', '987654', '876543', '765432', '654321'].includes(pin)) return true;
  if (['000000', '111111', '222222', '333333', '444444', '555555', '666666', '777777', '888888', '999999'].includes(pin)) return true;
  return false;
}

function assertPinPolicy(pin, label = 'Le code PIN') {
  if (!validatePinFormat(pin)) {
    throw new Error(`${label} doit contenir exactement 6 chiffres`);
  }

  if (isWeakPin(pin)) {
    throw new Error(`${label} est trop simple. Choisissez 6 chiffres non répétitifs et non séquentiels.`);
  }
}

function isWalletPinSchemaMissingError(error) {
  const msg = String(error?.message || error?.details || '');
  return (
    /pin_hash|pin_enabled|pin_failed_attempts|pin_locked_until|pin_updated_at/i.test(msg) &&
    /column|does not exist|schema cache/i.test(msg)
  );
}

function toFallbackPinState(wallet) {
  if (!wallet) return null;
  return {
    id: wallet.id,
    pin_hash: wallet.pin_hash ?? null,
    pin_enabled: Boolean(wallet.pin_hash),
    pin_failed_attempts: 0,
    pin_locked_until: null,
    pin_updated_at: wallet.updated_at ?? null,
  };
}

async function fetchWalletPinFallback(userId) {
  const { data, error } = await supabaseAdmin
    .from('wallets')
    .select('id, pin_hash, updated_at')
    .eq('user_id', userId)
    .maybeSingle();

  if (!error) return toFallbackPinState(data);
  if (!isWalletPinSchemaMissingError(error)) throw error;

  const { data: minimal, error: minErr } = await supabaseAdmin
    .from('wallets')
    .select('id, updated_at')
    .eq('user_id', userId)
    .maybeSingle();

  if (minErr) throw minErr;
  return toFallbackPinState(minimal ? { ...minimal, pin_hash: null } : null);
}

async function persistWalletPinUpdate(userId, payload, fallbackPayload = {}) {
  const { error } = await supabaseAdmin.from('wallets').update(payload).eq('user_id', userId);
  if (!error) return;
  if (!isWalletPinSchemaMissingError(error)) throw error;
  if (Object.keys(fallbackPayload).length === 0) return;

  const { error: fbErr } = await supabaseAdmin
    .from('wallets')
    .update(fallbackPayload)
    .eq('user_id', userId);
  if (fbErr) throw fbErr;
}

async function getWalletPinState(userId) {
  const { data, error } = await supabaseAdmin
    .from('wallets')
    .select('id, pin_hash, pin_enabled, pin_failed_attempts, pin_locked_until, pin_updated_at')
    .eq('user_id', userId)
    .maybeSingle();

  if (!error) return data;
  if (!isWalletPinSchemaMissingError(error)) throw error;
  return fetchWalletPinFallback(userId);
}

async function ensureWalletExistsForPin(userId) {
  const wallet = await getWalletPinState(userId);
  if (wallet) return wallet;

  const { data, error } = await supabaseAdmin
    .from('wallets')
    .insert({ user_id: userId })
    .select('id, pin_hash, pin_enabled, pin_failed_attempts, pin_locked_until, pin_updated_at')
    .maybeSingle();

  if (!error && data) return data;
  if (error && !isWalletPinSchemaMissingError(error)) throw error;

  const existing = await fetchWalletPinFallback(userId);
  if (existing) return existing;

  const { data: fallback, error: fbErr } = await supabaseAdmin
    .from('wallets')
    .insert({ user_id: userId })
    .select('id, updated_at')
    .single();
  if (fbErr) throw fbErr;
  return toFallbackPinState(fallback ? { ...fallback, pin_hash: null } : null);
}

function hashPin(pin, salt) {
  const actualSalt = salt || crypto.randomBytes(16).toString('hex');
  const derivedKey = crypto.scryptSync(pin, actualSalt, 64).toString('hex');
  return `${actualSalt}:${derivedKey}`;
}

function verifyHashedPin(pin, storedHash) {
  const [salt, expectedHash] = storedHash.split(':');
  if (!salt || !expectedHash) return false;
  const candidateHash = crypto.scryptSync(pin, salt, 64);
  const expectedBuffer = Buffer.from(expectedHash, 'hex');
  if (candidateHash.length !== expectedBuffer.length) return false;
  return crypto.timingSafeEqual(candidateHash, expectedBuffer);
}

async function verifyAccountPassword(expectedUserId, email, password) {
  if (!password || !String(password).trim()) {
    throw new Error(ACCOUNT_PASSWORD_REQUIRED_MESSAGE);
  }
  const anonKey = process.env.SUPABASE_ANON_KEY;
  if (!email || !String(email).trim() || !anonKey) {
    throw new Error(ACCOUNT_PASSWORD_RESET_UNAVAILABLE_MESSAGE);
  }
  const authClient = createClient(process.env.SUPABASE_URL, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data, error } = await authClient.auth.signInWithPassword({
    email: String(email).trim(),
    password,
  });
  await authClient.auth.signOut().catch(() => undefined);
  if (error || !data.user || data.user.id !== expectedUserId) {
    throw new Error(ACCOUNT_PASSWORD_INVALID_MESSAGE);
  }
}

async function setupWalletPin(userId, pin) {
  assertPinPolicy(pin, 'Le code PIN');
  try {
    await ensureWalletExistsForPin(userId);
    const pinHash = hashPin(pin);
    const timestamp = new Date().toISOString();
    await persistWalletPinUpdate(
      userId,
      { pin_hash: pinHash, pin_enabled: true, pin_failed_attempts: 0, pin_locked_until: null, pin_updated_at: timestamp, updated_at: timestamp },
      { pin_hash: pinHash, updated_at: timestamp }
    );
  } catch (error) {
    if (isWalletPinSchemaMissingError(error)) throw new Error(WALLET_PIN_SCHEMA_MISSING_MESSAGE);
    throw error;
  }
}

async function verifyWalletPin(userId, pin) {
  if (!validatePinFormat(pin)) {
    return { valid: false, error: 'Le code PIN doit contenir 6 chiffres' };
  }
  let wallet;
  try {
    wallet = await ensureWalletExistsForPin(userId);
  } catch (error) {
    if (isWalletPinSchemaMissingError(error)) {
      return { valid: false, error: WALLET_PIN_SCHEMA_MISSING_MESSAGE };
    }
    throw error;
  }

  const hasActivePin = Boolean(wallet?.pin_hash) && wallet?.pin_enabled !== false;
  if (!hasActivePin) {
    return { valid: false, error: 'Veuillez configurer votre code PIN avant cette opération' };
  }

  const now = Date.now();
  const lockedUntilTs = wallet.pin_locked_until ? new Date(wallet.pin_locked_until).getTime() : null;
  if (lockedUntilTs && lockedUntilTs > now) {
    return { valid: false, error: 'Code PIN temporairement bloqué', lockedUntil: wallet.pin_locked_until };
  }

  const isValid = verifyHashedPin(pin, wallet.pin_hash);
  if (isValid) {
    if (Number(wallet.pin_failed_attempts || 0) > 0) {
      await persistWalletPinUpdate(
        userId,
        { pin_failed_attempts: 0, pin_locked_until: null },
        {}
      ).catch(() => undefined);
    }
    return { valid: true };
  }

  const newFailedAttempts = Number(wallet.pin_failed_attempts || 0) + 1;
  const shouldLock = newFailedAttempts >= MAX_FAILED_ATTEMPTS;
  const lockedUntil = shouldLock
    ? new Date(now + LOCKOUT_MINUTES * 60 * 1000).toISOString()
    : null;
  await persistWalletPinUpdate(
    userId,
    { pin_failed_attempts: newFailedAttempts, pin_locked_until: lockedUntil },
    {}
  ).catch(() => undefined);

  return {
    valid: false,
    error: shouldLock
      ? `Code PIN bloqué pour ${LOCKOUT_MINUTES} minutes après ${MAX_FAILED_ATTEMPTS} tentatives`
      : `Code PIN incorrect. ${MAX_FAILED_ATTEMPTS - newFailedAttempts} tentatives restantes`,
    lockedUntil,
  };
}

async function changeWalletPin(userId, currentPin, newPin) {
  let wallet;
  try {
    wallet = await ensureWalletExistsForPin(userId);
  } catch (error) {
    if (isWalletPinSchemaMissingError(error)) throw new Error(WALLET_PIN_SCHEMA_MISSING_MESSAGE);
    throw error;
  }
  const hasActivePin = Boolean(wallet?.pin_hash) && wallet?.pin_enabled !== false;
  if (!hasActivePin) throw new Error('Aucun code PIN actif');

  const verification = await verifyWalletPin(userId, currentPin);
  if (!verification.valid) throw new Error(verification.error || 'Code PIN actuel invalide');

  await setupWalletPin(userId, newPin);
}

async function countRecentFailedPinResets(userId) {
  const since = new Date(Date.now() - PIN_RESET_LOCKOUT_MINUTES * 60 * 1000).toISOString();
  const { count, error } = await supabaseAdmin
    .from('security_audit_logs')
    .select('id', { count: 'exact', head: true })
    .eq('event_type', 'wallet_pin_reset')
    .eq('user_id', userId)
    .eq('success', false)
    .gte('created_at', since);

  if (error) return 0;
  return count || 0;
}

async function logWalletPinSecurityEvent({ userId, action, success, severity, reason, ipAddress, userAgent }) {
  await supabaseAdmin
    .from('security_audit_logs')
    .insert({
      event_type: `wallet_pin_${action}`,
      user_id: userId,
      ip_address: ipAddress || null,
      user_agent: userAgent || null,
      resource_type: 'wallet',
      resource_id: userId,
      action,
      success,
      severity: severity || (success ? 'medium' : 'high'),
      details: {
        reason: reason || null,
        source: 'wallet-v2-route',
      },
    })
    .then(() => undefined, () => undefined);
}

async function notifyWalletPinReset(userId) {
  await supabaseAdmin
    .from('notifications')
    .insert({
      user_id: userId,
      title: 'Code PIN wallet réinitialisé',
      message: 'Votre code PIN wallet vient d\'être réinitialisé. Si vous n\'êtes pas à l\'origine de cette action, contactez immédiatement le support.',
      type: 'security_alert',
      read: false,
    })
    .then(() => undefined, () => undefined);
}

async function resetWalletPinWithPassword(userId, email, accountPassword, newPin, options = {}) {
  assertPinPolicy(newPin, 'Le nouveau code PIN');

  const recentFailures = await countRecentFailedPinResets(userId);
  if (recentFailures >= PIN_RESET_MAX_FAILED_ATTEMPTS) {
    await logWalletPinSecurityEvent({
      userId,
      action: 'reset',
      success: false,
      severity: 'high',
      reason: 'reset_rate_limited',
      ipAddress: options.ipAddress,
      userAgent: options.userAgent,
    });
    throw new Error(`Trop de tentatives de réinitialisation. Réessayez dans ${PIN_RESET_LOCKOUT_MINUTES} minutes.`);
  }

  try {
    await verifyAccountPassword(userId, email, accountPassword);
  } catch (error) {
    await logWalletPinSecurityEvent({
      userId,
      action: 'reset',
      success: false,
      severity: 'high',
      reason: error?.message || 'password_verification_failed',
      ipAddress: options.ipAddress,
      userAgent: options.userAgent,
    });
    throw error;
  }

  await setupWalletPin(userId, newPin);
  await logWalletPinSecurityEvent({
    userId,
    action: 'reset',
    success: true,
    severity: 'high',
    reason: 'account_password_verified',
    ipAddress: options.ipAddress,
    userAgent: options.userAgent,
  });
  await notifyWalletPinReset(userId);
}

function getWalletPinPolicy() {
  return {
    pinLength: PIN_LENGTH,
    maxFailedAttempts: MAX_FAILED_ATTEMPTS,
    lockoutMinutes: LOCKOUT_MINUTES,
    resetMaxFailedAttempts: PIN_RESET_MAX_FAILED_ATTEMPTS,
    resetLockoutMinutes: PIN_RESET_LOCKOUT_MINUTES,
  };
}

function hasPinEnabled(pinState) {
  return Boolean(pinState?.pin_enabled ?? pinState?.pin_hash);
}

function isFxSuccessStatus(status) {
  const normalized = String(status || '').toLowerCase();
  return normalized === 'success' || normalized === 'completed' || normalized === 'ok';
}

function mapCurrencyToCountry(currency) {
  const currencyCode = String(currency || '').toUpperCase();
  const mapping = {
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

  return mapping[currencyCode] || currencyCode || 'Inconnu';
}

function isAfricanBankSourceUrl(url) {
  const normalized = String(url || '').toLowerCase();
  return AFRICAN_BANK_SOURCE_URLS.some((sourceUrl) => normalized.includes(sourceUrl.replace(/^https?:\/\//, '').toLowerCase()));
}

function isAfricanBankRow(row) {
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

function resolveOfficialBankSourceUrl(row) {
  if (row?.source_url) return row.source_url;

  const text = `${String(row?.source || '').toLowerCase()} ${String(row?.source_type || '').toLowerCase()}`;
  if (/bcrg|banque centrale de guinee|banque centrale de guinée/.test(text)) {
    return BCRG_OFFICIAL_URL;
  }

  return null;
}

function parseFxRateNumber(rawValue) {
  const parsed = Number.parseFloat(String(rawValue || '').replace(/\u00a0/g, ' ').replace(/\s/g, '').replace(/,/g, '.'));
  return Number.isFinite(parsed) ? parsed : Number.NaN;
}

function normalizeBcrgUrl(rawUrl) {
  try {
    return new URL(rawUrl, BCRG_OFFICIAL_URL).toString();
  } catch {
    return rawUrl;
  }
}

function extractBcrgFixingUrls(html) {
  const urls = [];
  const pushUrl = (value) => {
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

  return urls.sort((left, right) => right.localeCompare(left));
}

function extractBcrgWidgetRate(html, currency) {
  const labelPattern = currency === 'USD' ? '(?:USD|Dollar)' : '(?:EUR|Euro)';
  const patterns = [
    new RegExp(`${labelPattern}\\s*=\\s*<\\/h\\d>[\\s\\S]{0,1800}?<h\\d[^>]*>\\s*([\\d\\s.,]+)\\s*<\\/h\\d>`, 'gi'),
    new RegExp(`<td[^>]*>\\s*${labelPattern}\\s*=?\\s*<\\/td>\\s*<td[^>]*>\\s*([\\d\\s.,]+)\\s*<\\/td>`, 'gi'),
    new RegExp(`(?:1\\s*${currency}\\s*=\\s*|${currency}\\s*\\/\\s*GNF\\s*[:=]\\s*)([\\d\\s.,]+)`, 'gi'),
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

async function fetchBcrgHtml(url) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);

  try {
    const response = await fetch(url, {
      headers: {
        'User-Agent': '224Solutions-FX-Monitor/2.0',
        Accept: 'text/html',
      },
      signal: controller.signal,
    });

    if (!response.ok) {
      logger.warn(`[walletV2] BCRG HTTP ${response.status} sur ${url}`);
      return null;
    }

    return await response.text();
  } catch (error) {
    const message = error?.name === 'AbortError' ? 'timeout' : String(error?.message || error || 'unknown error');
    logger.warn(`[walletV2] BCRG fetch échoué sur ${url}: ${message}`);
    return null;
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchLiveBcrgUsdGnf() {
  let homepageHtml = null;

  try {
    homepageHtml = await fetchBcrgHtml(BCRG_OFFICIAL_URL);
  } catch {
    homepageHtml = null;
  }

  const fixingUrls = homepageHtml ? extractBcrgFixingUrls(homepageHtml) : [];
  const urlsToTry = Array.from(new Set([
    ...fixingUrls,
    ...BCRG_SCRAPE_URLS,
  ]));

  for (const url of urlsToTry) {
    const html = url === BCRG_OFFICIAL_URL && homepageHtml
      ? homepageHtml
      : await fetchBcrgHtml(url);

    if (!html) {
      continue;
    }

    const usdGnf = extractBcrgWidgetRate(html, 'USD');
    if (!usdGnf) {
      continue;
    }

    const eurGnf = extractBcrgWidgetRate(html, 'EUR');
    return {
      usdGnf,
      eurGnf,
      retrievedAt: new Date().toISOString(),
      sourceUrl: url,
    };
  }

  return null;
}

async function ignoreSupabaseError(operation) {
  await Promise.resolve(operation).catch(() => undefined);
}

async function readSupabaseData(queryPromise, label, fallbackValue = null) {
  try {
    const result = await queryPromise;
    if (result?.error) {
      logger.warn(`[walletV2] ${label} query failed: ${result.error.message}`);
      return fallbackValue;
    }
    return result?.data ?? fallbackValue;
  } catch (error) {
    logger.warn(`[walletV2] ${label} query threw: ${error?.message || error}`);
    return fallbackValue;
  }
}

function buildAfricanFxCollectPayload(source, actorId) {
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
    bcrg_source_urls: BCRG_SCRAPE_URLS,
    preferred_source_urls: AFRICAN_BANK_SOURCE_URLS,
  };
}

async function triggerAfricanFxCollection(source, actorId, timeoutMs = 3500) {
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
    let payload = null;
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
  } catch (error) {
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

// ────────────────────────────────────────────────────────────
// WALLET ROUTES
// ────────────────────────────────────────────────────────────

/**
 * GET /api/v2/wallet/balance
 */
router.get('/balance', verifyJWT, async (req, res) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('wallets')
      .select('id, balance, currency, wallet_status, is_blocked, daily_limit, monthly_limit, created_at')
      .eq('user_id', req.user.id)
      .maybeSingle();

    if (error) throw error;
    res.json({ success: true, data: data || null, exists: !!data });
  } catch (error) {
    logger.error(`[walletV2] balance error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la récupération du solde' });
  }
});

/**
 * POST /api/v2/wallet/initialize
 */
router.post('/initialize', verifyJWT, async (req, res) => {
  try {
    const userId = req.user.id;
    const { data: existing, error: selectErr } = await supabaseAdmin
      .from('wallets')
      .select('*')
      .eq('user_id', userId)
      .maybeSingle();

    if (selectErr) throw selectErr;
    if (existing) {
      res.json({ success: true, wallet: existing, created: false });
      return;
    }

    const { data: newWallet, error: insertErr } = await supabaseAdmin
      .from('wallets')
      .insert({ user_id: userId })
      .select()
      .single();

    if (insertErr) throw insertErr;
    res.status(201).json({ success: true, wallet: newWallet, created: true });
  } catch (error) {
    logger.error(`[walletV2] initialize error: ${error.message}`);
    res.status(500).json({ success: false, error: "Erreur lors de l'initialisation du wallet" });
  }
});

/**
 * GET /api/v2/wallet/transactions
 */
router.get('/transactions', verifyJWT, async (req, res) => {
  try {
    const userId = req.user.id;
    const limit = Math.min(parseInt(req.query.limit) || 20, 100);
    const offset = parseInt(req.query.offset) || 0;

    const { data: wallet } = await supabaseAdmin
      .from('wallets')
      .select('id')
      .eq('user_id', userId)
      .single();

    if (!wallet) {
      res.json({ success: true, data: [], meta: { total: 0, limit, offset, hasMore: false } });
      return;
    }

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
      meta: { limit, offset, total: count || 0, hasMore: offset + limit < (count || 0) },
    });
  } catch (error) {
    logger.error(`[walletV2] transactions error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

/**
 * GET /api/v2/wallet/status
 */
router.get('/status', verifyJWT, async (req, res) => {
  try {
    const userId = req.user.id;
    const { data, error } = await supabaseAdmin
      .from('wallets')
      .select(
        'id, balance, currency, wallet_status, is_blocked, blocked_reason, blocked_at, biometric_enabled, daily_limit, monthly_limit, created_at, updated_at, pin_enabled, pin_failed_attempts, pin_locked_until, pin_updated_at'
      )
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

    // Fallback si colonnes PIN manquantes
    const pinSchemaMissing = isWalletPinSchemaMissingError(error);
    if (!pinSchemaMissing) throw error;

    const [{ data: walletData, error: walletErr }, pinState] = await Promise.all([
      supabaseAdmin
        .from('wallets')
        .select(
          'id, balance, currency, wallet_status, is_blocked, blocked_reason, blocked_at, biometric_enabled, daily_limit, monthly_limit, created_at, updated_at'
        )
        .eq('user_id', userId)
        .maybeSingle(),
      getWalletPinState(userId),
    ]);

    if (walletErr) throw walletErr;
    if (!walletData) {
      res.json({ success: true, exists: false, data: null });
      return;
    }

    res.json({
      success: true,
      exists: true,
      data: {
        ...walletData,
        pin_enabled: hasPinEnabled(pinState),
        pin_failed_attempts: Number(pinState?.pin_failed_attempts || 0),
        pin_locked_until: pinState?.pin_locked_until || null,
        pin_updated_at: pinState?.pin_updated_at || null,
      },
    });
  } catch (error) {
    logger.error(`[walletV2] status error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur' });
  }
});

// ────────────────────────────────────────────────────────────
// PIN ROUTES
// ────────────────────────────────────────────────────────────

/**
 * GET /api/v2/wallet/pin/status
 */
router.get('/pin/status', verifyJWT, async (req, res) => {
  try {
    const wallet = await ensureWalletExistsForPin(req.user.id);
    res.json({
      success: true,
      data: {
        pin_enabled: hasPinEnabled(wallet),
        pin_failed_attempts: Number(wallet?.pin_failed_attempts || 0),
        pin_locked_until: wallet?.pin_locked_until || null,
        pin_updated_at: wallet?.pin_updated_at || null,
        policy: getWalletPinPolicy(),
      },
    });
  } catch (error) {
    logger.error(`[walletV2] pin/status error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du chargement du statut PIN' });
  }
});

/**
 * POST /api/v2/wallet/pin/setup
 */
router.post('/pin/setup', verifyJWT, async (req, res) => {
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

    await setupWalletPin(req.user.id, pin);
    res.json({ success: true, message: 'Code PIN configuré avec succès' });
  } catch (error) {
    logger.error(`[walletV2] pin/setup error: ${error.message}`);
    res.status(400).json({ success: false, error: error.message || 'Erreur lors de la configuration du code PIN' });
  }
});

/**
 * POST /api/v2/wallet/pin/change
 */
router.post('/pin/change', verifyJWT, async (req, res) => {
  try {
    const { current_pin, new_pin, confirm_pin, currentPin, newPin, confirmPin } = req.body || {};
    const currentPinValue = current_pin ?? currentPin;
    const newPinValue = new_pin ?? newPin;
    const confirmPinValue = confirm_pin ?? confirmPin;

    if (
      typeof currentPinValue !== 'string' ||
      typeof newPinValue !== 'string' ||
      typeof confirmPinValue !== 'string'
    ) {
      res.status(400).json({ success: false, error: 'current_pin, new_pin et confirm_pin requis' });
      return;
    }
    if (newPinValue !== confirmPinValue) {
      res.status(400).json({ success: false, error: 'Le nouveau code PIN et sa confirmation ne correspondent pas' });
      return;
    }

    await changeWalletPin(req.user.id, currentPinValue, newPinValue);
    res.json({ success: true, message: 'Code PIN modifié avec succès' });
  } catch (error) {
    logger.error(`[walletV2] pin/change error: ${error.message}`);
    res.status(400).json({ success: false, error: error.message || 'Erreur lors du changement du code PIN' });
  }
});

/**
 * POST /api/v2/wallet/pin/reset
 */
router.post('/pin/reset', verifyJWT, async (req, res) => {
  try {
    const { account_password, new_pin, confirm_pin, accountPassword, newPin, confirmPin } = req.body || {};
    const accountPasswordValue = account_password ?? accountPassword;
    const newPinValue = new_pin ?? newPin;
    const confirmPinValue = confirm_pin ?? confirmPin;

    if (
      typeof accountPasswordValue !== 'string' ||
      typeof newPinValue !== 'string' ||
      typeof confirmPinValue !== 'string'
    ) {
      res.status(400).json({ success: false, error: 'account_password, new_pin et confirm_pin requis' });
      return;
    }
    if (newPinValue !== confirmPinValue) {
      res.status(400).json({ success: false, error: 'Le nouveau code PIN et sa confirmation ne correspondent pas' });
      return;
    }

    await resetWalletPinWithPassword(
      req.user.id,
      req.user?.email || null,
      accountPasswordValue,
      newPinValue,
      {
        ipAddress: req.ip || req.headers['x-forwarded-for']?.toString() || null,
        userAgent: req.headers['user-agent']?.toString() || null,
      }
    );
    res.json({ success: true, message: 'Code PIN réinitialisé avec succès' });
  } catch (error) {
    logger.error(`[walletV2] pin/reset error: ${error.message}`);
    res.status(400).json({ success: false, error: error.message || 'Erreur lors de la réinitialisation du code PIN' });
  }
});

router.get('/admin/fx-health', verifyJWT, requireRole('admin', 'pdg', 'ceo'), async (req, res) => {
  try {
    const now = Date.now();
    const startOfDay = new Date();
    startOfDay.setUTCHours(0, 0, 0, 0);
    const startOfDayIso = startOfDay.toISOString();

    const [
      latestAnyRate,
      latestUsdGnfRate,
      recentRuns,
      unresolvedAlerts,
      todayRates,
      marginConfig,
    ] = await Promise.all([
      readSupabaseData(supabaseAdmin
        .from('currency_exchange_rates')
        .select('from_currency, to_currency, rate, margin, final_rate_usd, final_rate_eur, source, source_type, source_url, retrieved_at')
        .eq('is_active', true)
        .order('retrieved_at', { ascending: false })
        .limit(1)
        .maybeSingle(), 'fx-health.latestAnyRate', null),
      readSupabaseData(supabaseAdmin
        .from('currency_exchange_rates')
        .select('from_currency, to_currency, rate, margin, final_rate_usd, final_rate_eur, source, source_type, source_url, retrieved_at')
        .eq('is_active', true)
        .eq('from_currency', 'USD')
        .eq('to_currency', 'GNF')
        .order('retrieved_at', { ascending: false })
        .limit(1)
        .maybeSingle(), 'fx-health.latestUsdGnfRate', null),
      readSupabaseData(supabaseAdmin
        .from('fx_collection_log')
        .select('currency_code, status, source, source_url, source_type, error_message, collected_at')
        .order('collected_at', { ascending: false })
        .limit(30), 'fx-health.recentRuns', []),
      readSupabaseData(supabaseAdmin
        .from('financial_security_alerts')
        .select('id, alert_type, severity, title, description, created_at, metadata')
        .like('alert_type', 'fx_%')
        .eq('is_resolved', false)
        .order('created_at', { ascending: false })
        .limit(20), 'fx-health.unresolvedAlerts', []),
      readSupabaseData(supabaseAdmin
        .from('currency_exchange_rates')
        .select('from_currency, to_currency, rate, margin, final_rate_usd, final_rate_eur, source, source_type, source_url, retrieved_at')
        .eq('is_active', true)
        .gte('retrieved_at', startOfDayIso)
        .order('retrieved_at', { ascending: false })
        .limit(200), 'fx-health.todayRates', []),
      readSupabaseData(supabaseAdmin
        .from('margin_config')
        .select('config_value')
        .eq('config_key', 'default_margin')
        .maybeSingle(), 'fx-health.marginConfig', null),
    ]);

    const liveBcrgRate = await fetchLiveBcrgUsdGnf();
    const fallbackRate = latestUsdGnfRate || latestAnyRate || null;
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
          source_url: liveBcrgRate.sourceUrl || BCRG_OFFICIAL_URL,
          retrieved_at: liveBcrgRate.retrievedAt,
        }
      : currentRateBase;
    const lastRetrievedAt = currentRate?.retrieved_at ? new Date(currentRate.retrieved_at).getTime() : null;
    const ageMinutes = lastRetrievedAt ? Math.floor((now - lastRetrievedAt) / 60000) : null;
    const staleThresholdMinutes = 90;
    const stale = ageMinutes === null || ageMinutes > staleThresholdMinutes;

    const runRows = recentRuns || [];
    const recentGnfRuns = runRows.filter((row) => row.currency_code === 'GNF').slice(0, 2);
    const twoConsecutiveFailures = recentGnfRuns.length >= 2 && recentGnfRuns.every((row) => !isFxSuccessStatus(row.status));
    const shouldTriggerRefresh = !liveBcrgRate && (stale || !currentRate || twoConsecutiveFailures);

    let refreshMeta = {
      attempted: false,
      reason: null,
      ok: false,
      status: null,
      timed_out: false,
      payload: null,
    };

    if (shouldTriggerRefresh) {
      const refreshReason = !currentRate
        ? 'missing_current_rate'
        : twoConsecutiveFailures
          ? 'two_consecutive_failures'
          : 'stale_rates';

      const refreshResult = await triggerAfricanFxCollection(`fx_health_${refreshReason}`, req.user?.id || null, 4000);
      refreshMeta = {
        attempted: true,
        reason: refreshReason,
        ok: refreshResult.ok,
        status: refreshResult.status,
        timed_out: refreshResult.timedOut,
        payload: refreshResult.payload,
      };

      if (!refreshResult.ok && !refreshResult.timedOut) {
        logger.warn(`[walletV2] FX health auto-refresh not confirmed (status=${refreshResult.status ?? 'n/a'})`);
      }
    }

    const todaysHistory = (todayRates || [])
      .filter((rate) => isAfricanBankRow(rate))
      .map((rate) => ({
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

    const sourceMap = new Map();
    const upsertSource = (entry) => {
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

    const gnfTodayHistory = todaysHistory.filter((rate) => rate.from_currency === 'GNF' || rate.to_currency === 'GNF');

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
        refresh: refreshMeta,
        recent_runs: runRows.slice(0, 10),
        today_history: todaysHistory,
        gnf_today_history: gnfTodayHistory,
        bank_sources: bankSources,
        active_alerts: unresolvedAlerts || [],
      },
    });
  } catch (error) {
    logger.error(`FX health error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du chargement du monitoring FX' });
  }
});

router.get('/admin/fx-conversion-stats', verifyJWT, requireRole('admin', 'pdg', 'ceo'), async (req, res) => {
  try {
    const windowHours = 24;
    const sinceIso = new Date(Date.now() - windowHours * 3600000).toISOString();

    const [{ data: txRows }, { data: wallets }, { data: profiles }] = await Promise.all([
      supabaseAdmin
        .from('wallet_transactions')
        .select('id, sender_wallet_id, receiver_wallet_id, amount, transaction_type, created_at')
        .eq('status', 'completed')
        .gte('created_at', sinceIso)
        .order('created_at', { ascending: false })
        .limit(5000),
      supabaseAdmin
        .from('wallets')
        .select('id, user_id, currency'),
      supabaseAdmin
        .from('profiles')
        .select('id, country, email, first_name, last_name'),
    ]);

    const walletMap = new Map((wallets || []).map((wallet) => [wallet.id, wallet]));
    const profileMap = new Map((profiles || []).map((profile) => [profile.id, profile]));
    const byUser = new Map();
    const byCountry = new Map();
    const countryCorridors = new Map();

    let totalConversions = 0;
    let internationalConversions = 0;

    for (const tx of txRows || []) {
      if (tx.transaction_type !== 'transfer') continue;

      const senderWallet = walletMap.get(tx.sender_wallet_id);
      const receiverWallet = walletMap.get(tx.receiver_wallet_id);
      if (!senderWallet || !receiverWallet) continue;

      const senderProfile = profileMap.get(senderWallet.user_id);
      const receiverProfile = profileMap.get(receiverWallet.user_id);
      const senderCountry = String(senderProfile?.country || mapCurrencyToCountry(senderWallet.currency || null));
      const receiverCountry = String(receiverProfile?.country || mapCurrencyToCountry(receiverWallet.currency || null));
      const amount = Number(tx.amount || 0);

      totalConversions += 1;
      if (senderCountry !== receiverCountry) internationalConversions += 1;

      const senderName = `${String(senderProfile?.first_name || '').trim()} ${String(senderProfile?.last_name || '').trim()}`.trim();
      const senderLabel = senderName || String(senderProfile?.email || senderWallet.user_id);
      const currentUser = byUser.get(senderWallet.user_id) || {
        user_id: senderWallet.user_id,
        user_label: senderLabel,
        country: senderCountry,
        conversions_count: 0,
        total_amount: 0,
      };
      currentUser.conversions_count += 1;
      currentUser.total_amount += amount;
      byUser.set(senderWallet.user_id, currentUser);

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
      },
    });
  } catch (error) {
    logger.error(`FX conversion stats error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du chargement des stats de conversion' });
  }
});

router.post('/admin/fx-rate-alert-check', verifyJWT, requireRole('admin', 'pdg', 'ceo'), async (req, res) => {
  try {
    const { data: rateRows } = await supabaseAdmin
      .from('currency_exchange_rates')
      .select('from_currency, to_currency, rate, source_url, retrieved_at')
      .eq('is_active', true)
      .order('retrieved_at', { ascending: false })
      .limit(100);

    const validRates = (rateRows || []).filter((row) => isAfricanBankSourceUrl(row?.source_url));
    if (validRates.length < 2) {
      res.json({ success: true, data: { alert_created: false, reason: 'not_enough_data' } });
      return;
    }

    const latest = validRates[0];
    const previous = validRates.find((row) => row.from_currency === latest.from_currency && row.to_currency === latest.to_currency && row.retrieved_at !== latest.retrieved_at);
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
    const changedUnderOneHour = changed && minutesBetween <= 60;

    let alertCreated = false;
    if (changedUnderOneHour) {
      const thresholdIso = new Date(Date.now() - 60 * 60000).toISOString();
      const { data: existing } = await supabaseAdmin
        .from('financial_security_alerts')
        .select('id')
        .eq('alert_type', 'fx_rate_change_under_1h')
        .eq('is_resolved', false)
        .gte('created_at', thresholdIso)
        .limit(1)
        .maybeSingle();

      if (!existing) {
        await ignoreSupabaseError(
          supabaseAdmin.from('financial_security_alerts').insert({
            user_id: SYSTEM_USER_ID,
            alert_type: 'fx_rate_change_under_1h',
            severity: 'high',
            title: 'Changement de taux detecte en moins d\'1 heure',
            description: `${latest.from_currency}/${latest.to_currency} a change de ${previousRate} a ${latestRate} en ${Math.round(minutesBetween)} minutes.`,
            metadata: {
              actor_id: req.user?.id,
              latest,
              previous,
              minutes_between: Math.round(minutesBetween),
            },
          })
        );
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
  } catch (error) {
    logger.error(`FX rate alert check error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la verification d\'alerte FX' });
  }
});

router.post('/admin/fx-margin', verifyJWT, requireRole('admin', 'pdg', 'ceo'), async (req, res) => {
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

    const refreshResult = await triggerAfricanFxCollection('pdg_margin_update', req.user?.id || null);
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
  } catch (error) {
    logger.error(`FX margin update error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la mise a jour de la commission FX' });
  }
});

router.post('/admin/fx-refresh', verifyJWT, requireRole('admin', 'pdg', 'ceo'), async (req, res) => {
  try {
    const refreshResult = await triggerAfricanFxCollection('pdg_manual_refresh', req.user?.id || null, 4000);

    if (!refreshResult.ok && !refreshResult.timedOut) {
      await ignoreSupabaseError(supabaseAdmin.from('financial_security_alerts').insert({
        user_id: SYSTEM_USER_ID,
        alert_type: 'fx_manual_refresh_failed',
        severity: 'high',
        title: 'Échec du refresh FX manuel',
        description: 'Le déclenchement manuel de la collecte FX a échoué.',
        metadata: {
          actor_id: req.user?.id || null,
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
  } catch (error) {
    logger.error(`FX manual refresh error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors du refresh FX manuel' });
  }
});

export default router;
