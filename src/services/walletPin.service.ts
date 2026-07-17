import crypto from 'crypto';
import { createClient } from '@supabase/supabase-js';
import { env } from '../config/env.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

/**
 * 🔒 FAIL-CLOSED sur l'ARGENT : si les colonnes PIN manquent (migration
 * absente), les routes d'argent doivent REFUSER (503 PIN_SCHEMA_UNAVAILABLE)
 * — jamais laisser passer. Les lectures gardent la tolérance historique.
 * L'indisponibilité est alertée (system_alerts, 1/h par process).
 */
let pinSchemaAlertAt = 0;
export async function isPinSchemaAvailableForMoney(): Promise<boolean> {
  const { error } = await supabaseAdmin.from('wallets').select('pin_enabled').limit(1);
  if (!error) return true;
  if (!isWalletPinSchemaMissingError(error)) return true; // autre panne → gérée par le flux appelant
  if (Date.now() - pinSchemaAlertAt > 3600_000) {
    pinSchemaAlertAt = Date.now();
    logger.error('[walletPin] SCHÉMA PIN ABSENT — routes argent en fail-closed (migration PIN manquante)');
    try {
      await supabaseAdmin.from('system_alerts').insert({
        title: 'Schéma PIN absent — argent bloqué (fail-closed)',
        message: 'Les colonnes wallets.pin_* sont introuvables : les routes d’argent refusent (503 PIN_SCHEMA_UNAVAILABLE). Appliquer la migration PIN.',
        severity: 'critical', module: 'wallet_pin', status: 'active',
      } as never);
    } catch { /* l'alerte ne casse jamais le flux */ }
  }
  return false;
}

/**
 * 🎚️ Politique PIN (pdg_settings) — RELUE À CHAQUE APPEL : une modification
 * PDG s'applique immédiatement, sans redéploiement.
 *  - pin_required_transfer_threshold : seuil GNF (défaut 500 000).
 *  - pin_required_operations : opérations couvertes.
 */
export async function getPinPolicy(): Promise<{ threshold: number; operations: string[] }> {
  let threshold = 500000;
  let operations = ['transfer', 'withdrawal', 'payment_link', 'b2b_payment'];
  try {
    const { data } = await supabaseAdmin.from('pdg_settings')
      .select('setting_key, setting_value')
      .in('setting_key', ['pin_required_transfer_threshold', 'pin_required_operations']);
    for (const row of ((data || []) as Array<{ setting_key: string; setting_value: unknown }>)) {
      const v = row.setting_value as { value?: unknown } | unknown[];
      if (row.setting_key === 'pin_required_transfer_threshold') {
        const n = Number((v as { value?: unknown })?.value ?? v);
        if (Number.isFinite(n) && n >= 0) threshold = n;
      } else if (row.setting_key === 'pin_required_operations') {
        const arr = Array.isArray(v) ? v : Array.isArray((v as { value?: unknown })?.value) ? (v as { value: unknown[] }).value : null;
        if (arr && arr.length) operations = arr.map(String);
      }
    }
  } catch { /* défauts sûrs */ }
  return { threshold, operations };
}

const PIN_LENGTH = 6;
const MAX_FAILED_ATTEMPTS = 5;
const LOCKOUT_MINUTES = 15;
const PIN_RESET_MAX_FAILED_ATTEMPTS = 5;
const PIN_RESET_LOCKOUT_MINUTES = 30;
const WALLET_PIN_SCHEMA_MISSING_MESSAGE = 'Le schéma PIN wallet n’est pas encore appliqué en base. Exécutez la migration 20260408193000_wallet_pin_schema_compat.sql.';
const ACCOUNT_PASSWORD_REQUIRED_MESSAGE = 'Entrez le mot de passe de votre compte pour réinitialiser le PIN.';
const ACCOUNT_PASSWORD_INVALID_MESSAGE = 'Mot de passe du compte incorrect.';
const ACCOUNT_PASSWORD_RESET_UNAVAILABLE_MESSAGE = 'Réinitialisation du PIN indisponible pour ce compte. Contactez le support.';

function validatePinFormat(pin: string): boolean {
  return /^\d{6}$/.test(pin);
}

function isWeakPin(pin: string): boolean {
  if (/^(\d)\1{5}$/.test(pin)) return true;
  if (['012345', '123456', '234567', '345678', '456789', '987654', '876543', '765432', '654321'].includes(pin)) return true;
  if (['000000', '111111', '222222', '333333', '444444', '555555', '666666', '777777', '888888', '999999'].includes(pin)) return true;
  return false;
}

function assertPinPolicy(pin: string, label = 'Le code PIN') {
  if (!validatePinFormat(pin)) {
    throw new Error(`${label} doit contenir exactement 6 chiffres`);
  }

  if (isWeakPin(pin)) {
    throw new Error(`${label} est trop simple. Choisissez 6 chiffres non répétitifs et non séquentiels.`);
  }
}

function isWalletPinSchemaMissingError(error: unknown): boolean {
  const errorMessage = String(
    (error as { message?: string; details?: string } | null)?.message ||
    (error as { details?: string } | null)?.details ||
    ''
  );

  return /pin_hash|pin_enabled|pin_failed_attempts|pin_locked_until|pin_updated_at/i.test(errorMessage)
    && /column|does not exist|schema cache/i.test(errorMessage);
}

function toFallbackWalletPinState(wallet: { id: string; pin_hash?: string | null; updated_at?: string | null } | null) {
  if (!wallet) {
    return null;
  }

  return {
    id: wallet.id,
    pin_hash: wallet.pin_hash ?? null,
    pin_enabled: Boolean(wallet.pin_hash),
    pin_failed_attempts: 0,
    pin_locked_until: null,
    pin_updated_at: wallet.updated_at ?? null,
  };
}

async function fetchWalletPinFallback(userId: string) {
  const { data: fallbackWallet, error: fallbackError } = await supabaseAdmin
    .from('wallets')
    .select('id, pin_hash, updated_at')
    .eq('user_id', userId)
    .order('updated_at', { ascending: false })
    .maybeSingle();

  if (!fallbackError) {
    return toFallbackWalletPinState(fallbackWallet);
  }

  if (!isWalletPinSchemaMissingError(fallbackError)) {
    throw fallbackError;
  }

  const { data: minimalWallet, error: minimalError } = await supabaseAdmin
    .from('wallets')
    .select('id, updated_at')
    .eq('user_id', userId)
    .order('updated_at', { ascending: false })
    .maybeSingle();

  if (minimalError) {
    throw minimalError;
  }

  return toFallbackWalletPinState(minimalWallet ? { ...minimalWallet, pin_hash: null } : null);
}

async function persistWalletPinUpdate(
  userId: string,
  payload: Record<string, unknown>,
  fallbackPayload: Record<string, unknown> = {}
) {
  const { error } = await supabaseAdmin
    .from('wallets')
    .update(payload)
    .eq('user_id', userId);

  if (!error) {
    return;
  }

  if (!isWalletPinSchemaMissingError(error)) {
    throw error;
  }

  if (Object.keys(fallbackPayload).length === 0) {
    return;
  }

  const { error: fallbackError } = await supabaseAdmin
    .from('wallets')
    .update(fallbackPayload)
    .eq('user_id', userId);

  if (fallbackError) {
    throw fallbackError;
  }
}

async function verifyAccountPassword(expectedUserId: string, email: string | null | undefined, password: string) {
  if (!password || !password.trim()) {
    throw new Error(ACCOUNT_PASSWORD_REQUIRED_MESSAGE);
  }

  if (!email || !String(email).trim() || !env.SUPABASE_ANON_KEY) {
    throw new Error(ACCOUNT_PASSWORD_RESET_UNAVAILABLE_MESSAGE);
  }

  const authClient = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
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

async function countRecentFailedPinResets(userId: string): Promise<number> {
  const since = new Date(Date.now() - PIN_RESET_LOCKOUT_MINUTES * 60 * 1000).toISOString();
  const { count, error } = await supabaseAdmin
    .from('security_audit_logs')
    .select('id', { count: 'exact', head: true })
    .eq('event_type', 'wallet_pin_reset')
    .eq('user_id', userId)
    .eq('success', false)
    .gte('created_at', since);

  if (error) {
    return 0;
  }

  return count || 0;
}

async function logWalletPinSecurityEvent(params: {
  userId: string;
  action: 'setup' | 'change' | 'reset';
  success: boolean;
  severity?: 'low' | 'medium' | 'high' | 'critical';
  reason?: string;
  ipAddress?: string | null;
  userAgent?: string | null;
}) {
  await supabaseAdmin
    .from('security_audit_logs')
    .insert({
      event_type: `wallet_pin_${params.action}`,
      user_id: params.userId,
      ip_address: params.ipAddress || null,
      user_agent: params.userAgent || null,
      resource_type: 'wallet',
      resource_id: params.userId,
      action: params.action,
      success: params.success,
      severity: params.severity || (params.success ? 'medium' : 'high'),
      details: {
        reason: params.reason || null,
        source: 'wallet-pin-service',
      },
    })
    .then(() => undefined, () => undefined);
}

async function notifyWalletPinReset(userId: string) {
  await supabaseAdmin
    .from('notifications')
    .insert({
      user_id: userId,
      title: 'Code PIN wallet réinitialisé',
      message: 'Votre code PIN wallet vient d’être réinitialisé. Si vous n’êtes pas à l’origine de cette action, contactez immédiatement le support.',
      type: 'security_alert',
      read: false,
    })
    .then(() => undefined, () => undefined);
}

function hashPin(pin: string, salt?: string): string {
  const actualSalt = salt || crypto.randomBytes(16).toString('hex');
  const derivedKey = crypto.scryptSync(pin, actualSalt, 64).toString('hex');
  return `${actualSalt}:${derivedKey}`;
}

function verifyHashedPin(pin: string, storedHash: string): boolean {
  const [salt, expectedHash] = storedHash.split(':');
  if (!salt || !expectedHash) return false;
  const candidateHash = crypto.scryptSync(pin, salt, 64);
  const expectedBuffer = Buffer.from(expectedHash, 'hex');
  if (candidateHash.length !== expectedBuffer.length) return false;
  return crypto.timingSafeEqual(candidateHash, expectedBuffer);
}

export async function getWalletPinState(userId: string) {
  const { data, error } = await supabaseAdmin
    .from('wallets')
    .select('id, pin_hash, pin_enabled, pin_failed_attempts, pin_locked_until, pin_updated_at')
    .eq('user_id', userId)
    .order('updated_at', { ascending: false })
    .maybeSingle();

  if (!error) {
    return data;
  }

  if (!isWalletPinSchemaMissingError(error)) {
    throw error;
  }

  return fetchWalletPinFallback(userId);
}

export async function ensureWalletExistsForPin(userId: string) {
  const wallet = await getWalletPinState(userId);
  if (wallet) return wallet;

  const { data, error } = await supabaseAdmin
    .from('wallets')
    .insert({ user_id: userId })
    .select('id, pin_hash, pin_enabled, pin_failed_attempts, pin_locked_until, pin_updated_at')
    .maybeSingle();

  if (!error && data) {
    return data;
  }

  if (error && !isWalletPinSchemaMissingError(error)) {
    throw error;
  }

  const existingFallback = await fetchWalletPinFallback(userId);
  if (existingFallback) {
    return existingFallback;
  }

  const { data: insertedFallback, error: insertFallbackError } = await supabaseAdmin
    .from('wallets')
    .insert({ user_id: userId })
    .select('id, updated_at')
    .single();

  if (insertFallbackError) {
    throw insertFallbackError;
  }

  return toFallbackWalletPinState(insertedFallback ? { ...insertedFallback, pin_hash: null } : null);
}

export async function setupWalletPin(userId: string, pin: string) {
  assertPinPolicy(pin, 'Le code PIN');

  try {
    await ensureWalletExistsForPin(userId);

    const pinHash = hashPin(pin);
    const timestamp = new Date().toISOString();

    await persistWalletPinUpdate(
      userId,
      {
        pin_hash: pinHash,
        pin_enabled: true,
        pin_failed_attempts: 0,
        pin_locked_until: null,
        pin_updated_at: timestamp,
        updated_at: timestamp,
      },
      {
        pin_hash: pinHash,
        updated_at: timestamp,
      }
    );
  } catch (error) {
    if (isWalletPinSchemaMissingError(error)) {
      throw new Error(WALLET_PIN_SCHEMA_MISSING_MESSAGE);
    }
    throw error;
  }
}

export async function changeWalletPin(userId: string, currentPin: string, newPin: string) {
  let wallet;

  try {
    wallet = await ensureWalletExistsForPin(userId);
  } catch (error) {
    if (isWalletPinSchemaMissingError(error)) {
      throw new Error(WALLET_PIN_SCHEMA_MISSING_MESSAGE);
    }
    throw error;
  }

  const hasActivePin = Boolean(wallet?.pin_hash) && wallet?.pin_enabled !== false;

  if (!hasActivePin) {
    throw new Error('Aucun code PIN actif');
  }

  const verification = await verifyWalletPin(userId, currentPin);
  if (!verification.valid) {
    throw new Error(verification.error || 'Code PIN actuel invalide');
  }

  await setupWalletPin(userId, newPin);
}

export async function resetWalletPinWithPassword(
  userId: string,
  email: string | null | undefined,
  accountPassword: string,
  newPin: string,
  options: { ipAddress?: string | null; userAgent?: string | null } = {},
) {
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
  } catch (error: any) {
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

export async function verifyWalletPin(userId: string, pin: string): Promise<{ valid: boolean; error?: string; lockedUntil?: string | null }> {
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

  const isValid = verifyHashedPin(pin, wallet.pin_hash!);
  if (isValid) {
    await persistWalletPinUpdate(
      userId,
      {
        pin_failed_attempts: 0,
        pin_locked_until: null,
        updated_at: new Date().toISOString(),
      },
      {
        updated_at: new Date().toISOString(),
      }
    );

    return { valid: true };
  }

  const failedAttempts = Number(wallet.pin_failed_attempts || 0) + 1;
  const shouldLock = failedAttempts >= MAX_FAILED_ATTEMPTS;
  const lockedUntil = shouldLock
    ? new Date(Date.now() + LOCKOUT_MINUTES * 60 * 1000).toISOString()
    : null;

  await persistWalletPinUpdate(
    userId,
    {
      pin_failed_attempts: failedAttempts,
      pin_locked_until: lockedUntil,
      updated_at: new Date().toISOString(),
    },
    {
      updated_at: new Date().toISOString(),
    }
  );

  return {
    valid: false,
    error: shouldLock
      ? `Trop de tentatives. Code PIN bloqué pendant ${LOCKOUT_MINUTES} minutes`
      : `Code PIN invalide (${failedAttempts}/${MAX_FAILED_ATTEMPTS})`,
    lockedUntil,
  };
}

export function getWalletPinPolicy() {
  return {
    pinLength: PIN_LENGTH,
    maxFailedAttempts: MAX_FAILED_ATTEMPTS,
    lockoutMinutes: LOCKOUT_MINUTES,
    resetMaxFailedAttempts: PIN_RESET_MAX_FAILED_ATTEMPTS,
    resetLockoutMinutes: PIN_RESET_LOCKOUT_MINUTES,
  };
}
