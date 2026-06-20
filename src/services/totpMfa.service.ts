/**
 * 🔐 SERVICE 2FA ADMIN — TOTP step-up VÉRIFIÉ CÔTÉ SERVEUR
 * ---------------------------------------------------------------------------
 * Remplace le 2FA "cosmétique" (vérifié dans le navigateur, TOTP non conforme,
 * secret "chiffré" avec l'UUID public). Ici :
 *   - secret TOTP généré + vérifié SERVEUR via speakeasy (RFC 6238, Base32) ;
 *   - secret stocké chiffré AES-256-GCM (clé serveur dérivée scrypt), dans la table
 *     isolée `admin_mfa` (RLS sans policy → service_role uniquement) ;
 *   - lockout anti brute-force + journal append-only `admin_mfa_events`.
 *
 * Tout passe par le backend Node.js (règle projet : aucune logique sensible côté client).
 */

import crypto from 'crypto';
import speakeasy from 'speakeasy';
import { supabaseAdmin } from '../config/supabase.js';
import { env } from '../config/env.js';
import { logger } from '../config/logger.js';

const ISSUER = '224Solutions';
const STEP_WINDOW = 1;           // ±1 pas (±30 s) de tolérance d'horloge
const MAX_FAILED_ATTEMPTS = 5;   // verrouillage après N échecs
const LOCKOUT_MINUTES = 15;

export interface AdminMfaRow {
  user_id: string;
  secret_encrypted: string;
  enabled: boolean;
  enrolled_at: string | null;
  last_step_up_at: string | null;
  failed_attempts: number;
  locked_until: string | null;
}

// ── Chiffrement du secret au repos (AES-256-GCM) ────────────────────────────
let cachedKey: Buffer | null = null;
function encryptionKey(): Buffer {
  if (cachedKey) return cachedKey;
  const material = env.MFA_ENCRYPTION_KEY || env.SUPABASE_SERVICE_ROLE_KEY;
  if (!material) {
    throw new Error('MFA_ENCRYPTION_KEY absente — impossible de chiffrer le secret 2FA');
  }
  // Dérivation déterministe 32 octets (sel fixe : la confidentialité tient à la clé serveur).
  cachedKey = crypto.scryptSync(material, 'admin-mfa-totp-v1', 32);
  return cachedKey;
}

export function encryptSecret(plain: string): string {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', encryptionKey(), iv);
  const enc = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `${iv.toString('base64')}.${tag.toString('base64')}.${enc.toString('base64')}`;
}

export function decryptSecret(payload: string): string {
  const [ivB64, tagB64, dataB64] = payload.split('.');
  if (!ivB64 || !tagB64 || !dataB64) throw new Error('Secret 2FA chiffré invalide');
  const decipher = crypto.createDecipheriv('aes-256-gcm', encryptionKey(), Buffer.from(ivB64, 'base64'));
  decipher.setAuthTag(Buffer.from(tagB64, 'base64'));
  return Buffer.concat([decipher.update(Buffer.from(dataB64, 'base64')), decipher.final()]).toString('utf8');
}

// ── TOTP (speakeasy, RFC 6238) ──────────────────────────────────────────────
export function generateTotpSecret(email: string): { base32: string; otpauthUrl: string } {
  const secret = speakeasy.generateSecret({ length: 20, name: `${ISSUER} (${email})`, issuer: ISSUER });
  const otpauthUrl = speakeasy.otpauthURL({
    secret: secret.base32,
    label: `${ISSUER}:${email}`,
    issuer: ISSUER,
    encoding: 'base32',
    digits: 6,
    period: 30,
  });
  return { base32: secret.base32, otpauthUrl };
}

export function verifyTotp(base32Secret: string, token: string): boolean {
  if (!/^\d{6}$/.test((token || '').trim())) return false;
  return speakeasy.totp.verify({
    secret: base32Secret,
    encoding: 'base32',
    token: token.trim(),
    window: STEP_WINDOW,
  });
}

// ── Accès base (table isolée admin_mfa) ─────────────────────────────────────
export async function getAdminMfa(userId: string): Promise<AdminMfaRow | null> {
  const { data, error } = await supabaseAdmin
    .from('admin_mfa')
    .select('user_id, secret_encrypted, enabled, enrolled_at, last_step_up_at, failed_attempts, locked_until')
    .eq('user_id', userId)
    .maybeSingle();
  if (error) {
    logger.error(`[admin-mfa] lecture échouée: ${error.message}`);
    throw error;
  }
  return (data as AdminMfaRow) || null;
}

export function isLocked(row: AdminMfaRow | null): boolean {
  return !!row?.locked_until && new Date(row.locked_until).getTime() > Date.now();
}

export async function logEvent(
  userId: string,
  eventType: 'enroll' | 'activate' | 'step_up' | 'disable' | 'fail' | 'lockout',
  success: boolean,
  meta: { ip?: string; userAgent?: string; details?: Record<string, unknown> } = {}
): Promise<void> {
  try {
    await supabaseAdmin.from('admin_mfa_events').insert({
      user_id: userId,
      event_type: eventType,
      success,
      ip: meta.ip || null,
      user_agent: meta.userAgent || null,
      details: meta.details || null,
    });
  } catch (e: any) {
    logger.warn(`[admin-mfa] log event échoué (non bloquant): ${e?.message}`);
  }
}

/** Crée/écrase le secret EN ATTENTE (enabled=false) lors de l'enrôlement. */
export async function upsertPendingSecret(userId: string, base32: string): Promise<void> {
  const { error } = await supabaseAdmin
    .from('admin_mfa')
    .upsert({
      user_id: userId,
      secret_encrypted: encryptSecret(base32),
      enabled: false,
      failed_attempts: 0,
      locked_until: null,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'user_id' });
  if (error) throw error;
}

export async function enableMfa(userId: string): Promise<void> {
  const { error } = await supabaseAdmin
    .from('admin_mfa')
    .update({ enabled: true, enrolled_at: new Date().toISOString(), failed_attempts: 0, locked_until: null })
    .eq('user_id', userId);
  if (error) throw error;
}

export async function disableMfa(userId: string): Promise<void> {
  const { error } = await supabaseAdmin.from('admin_mfa').delete().eq('user_id', userId);
  if (error) throw error;
}

export async function recordStepUpSuccess(userId: string): Promise<void> {
  await supabaseAdmin
    .from('admin_mfa')
    .update({ last_step_up_at: new Date().toISOString(), failed_attempts: 0, locked_until: null })
    .eq('user_id', userId);
}

/** Incrémente le compteur d'échecs ; verrouille au-delà du seuil. Retourne true si verrouillé. */
export async function recordFailure(userId: string, current: number): Promise<boolean> {
  const attempts = (current || 0) + 1;
  const locked = attempts >= MAX_FAILED_ATTEMPTS;
  await supabaseAdmin
    .from('admin_mfa')
    .update({
      failed_attempts: attempts,
      locked_until: locked ? new Date(Date.now() + LOCKOUT_MINUTES * 60_000).toISOString() : null,
    })
    .eq('user_id', userId);
  return locked;
}

export const MFA_CONST = { MAX_FAILED_ATTEMPTS, LOCKOUT_MINUTES, STEP_WINDOW };
