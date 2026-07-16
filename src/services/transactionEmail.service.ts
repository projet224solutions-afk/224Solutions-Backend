/**
 * Service d'envoi d'emails pour les transactions wallet
 * Utilise la Edge Function send-otp-email de Supabase
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { env } from '../config/env.js';

interface TransactionEmailParams {
  senderId: string;
  receiverId: string;
  amountSent: number;
  amountReceived: number;
  senderCurrency: string;
  receiverCurrency: string;
  description?: string;
  isInternational: boolean;
  rateUsed?: number;
  transactionId?: string;
}

interface UserProfile {
  email: string | null;
  full_name: string | null;
  first_name: string | null;
  last_name: string | null;
  custom_id: string | null;
}

async function getProfile(userId: string): Promise<UserProfile | null> {
  const { data } = await supabaseAdmin
    .from('profiles')
    .select('email, full_name, first_name, last_name, custom_id')
    .eq('id', userId)
    .maybeSingle();

  let email = data?.email ?? null;

  // profiles.email est souvent null — fallback sur auth.users
  if (!email) {
    const { data: authUser } = await supabaseAdmin.auth.admin.getUserById(userId);
    email = authUser?.user?.email ?? null;
  }

  if (!data && !email) return null;

  return {
    email,
    full_name: data?.full_name ?? null,
    first_name: data?.first_name ?? null,
    last_name: data?.last_name ?? null,
    custom_id: data?.custom_id ?? null,
  };
}

function formatAmount(amount: number, currency: string): string {
  return `${Math.round(amount).toLocaleString('fr-FR')} ${currency}`;
}

function getDisplayName(profile: UserProfile | null, fallback = 'Utilisateur'): string {
  if (!profile) return fallback;
  const firstLast = [profile.first_name, profile.last_name].filter(Boolean).join(' ');
  return profile.full_name || firstLast || profile.custom_id || fallback;
}

// ── Observabilité des envois (fini les emails perdus en silence) ──────────────
// Un échec Resend n'interrompt JAMAIS le flux appelant (l'email est un effet de
// bord best-effort), mais il ne doit plus être invisible : on compte les échecs
// et on retient le dernier, exposé via getEmailHealth() (santé/monitoring PDG).
let emailFailures = 0;
let emailSent = 0;
let lastEmailError: { at: string; status: number | null; reason: string } | null = null;

/** Snapshot de santé du mailer (aucun secret) — consommable par un endpoint de monitoring. */
export function getEmailHealth(): {
  configured: boolean;
  sent: number;
  failures: number;
  lastError: { at: string; status: number | null; reason: string } | null;
} {
  return { configured: Boolean(env.RESEND_API_KEY), sent: emailSent, failures: emailFailures, lastError: lastEmailError };
}

export async function sendEmail(email: string, subject: string, html: string): Promise<boolean> {
  const apiKey = env.RESEND_API_KEY;
  if (!apiKey) {
    emailFailures++;
    lastEmailError = { at: new Date().toISOString(), status: null, reason: 'RESEND_API_KEY non configurée' };
    // error (pas warn) : un mailer non configuré = des emails perdus en silence.
    logger.error('[TransactionEmail] RESEND_API_KEY absente de l\'environnement — email NON envoyé (config manquante)');
    return false;
  }
  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        from: '224Solutions <no-reply@224solution.net>',
        to: [email],
        subject,
        html,
      }),
    });
    if (!res.ok) {
      const body = (await res.text()).slice(0, 500);
      emailFailures++;
      lastEmailError = { at: new Date().toISOString(), status: res.status, reason: body };
      // 403 « domain is not verified » = cause de config actionnable → on la nomme.
      const isUnverifiedDomain = res.status === 403 && /domain is not verified/i.test(body);
      const hint = isUnverifiedDomain
        ? ' → DOMAINE NON VÉRIFIÉ chez Resend : poser les DNS (DKIM/SPF/MX) de 224solution.net, cf. docs/EMAILS_RESEND_DIAGNOSTIC.md'
        : '';
      logger.error(`[TransactionEmail] Échec Resend (${res.status}) pour ${email} — total échecs=${emailFailures}: ${body}${hint}`);
      return false;
    }
    emailSent++;
    return true;
  } catch (err: any) {
    emailFailures++;
    lastEmailError = { at: new Date().toISOString(), status: null, reason: err?.message || 'erreur réseau' };
    logger.error(`[TransactionEmail] Échec réseau Resend pour ${email} — total échecs=${emailFailures}: ${err?.message}`);
    return false;
  }
}

function buildSenderHtml(params: {
  senderName: string;
  receiverName: string;
  amountSent: number;
  senderCurrency: string;
  amountReceived: number;
  receiverCurrency: string;
  description?: string;
  isInternational: boolean;
  rateUsed?: number;
  transactionId?: string;
  date: string;
}): string {
  const { receiverName, amountSent, senderCurrency, amountReceived, receiverCurrency, description, isInternational, rateUsed, transactionId, date } = params;
  const internationalInfo = isInternational && rateUsed && rateUsed !== 1
    ? `<tr><td style="padding:6px 0;color:#718096;">Taux utilisé</td><td style="padding:6px 0;text-align:right;font-weight:600;">1 ${senderCurrency} = ${rateUsed.toFixed(4)} ${receiverCurrency}</td></tr>`
    : '';
  return `
    <div style="font-family:sans-serif;max-width:600px;margin:0 auto;padding:24px;background:#f7fafc;">
      <div style="background:#fff;border-radius:12px;padding:32px;box-shadow:0 1px 3px rgba(0,0,0,0.1);">
        <div style="text-align:center;margin-bottom:24px;">
          <div style="background:#fff7ed;border-radius:50%;width:64px;height:64px;display:inline-flex;align-items:center;justify-content:center;font-size:32px;">💸</div>
          <h1 style="margin:12px 0 4px;font-size:20px;color:#1a202c;">Transfert envoyé</h1>
          <p style="margin:0;color:#718096;font-size:14px;">${date}</p>
        </div>
        <div style="background:#fff7ed;border-radius:8px;padding:20px;text-align:center;margin-bottom:24px;">
          <p style="margin:0;font-size:13px;color:#718096;">Montant débité</p>
          <p style="margin:4px 0 0;font-size:28px;font-weight:700;color:#c05621;">-${formatAmount(amountSent, senderCurrency)}</p>
          ${isInternational ? `<p style="margin:4px 0 0;font-size:14px;color:#718096;">→ ${formatAmount(amountReceived, receiverCurrency)} reçus par ${receiverName}</p>` : ''}
        </div>
        <table style="width:100%;border-collapse:collapse;">
          <tr><td style="padding:6px 0;color:#718096;">Destinataire</td><td style="padding:6px 0;text-align:right;font-weight:600;">${receiverName}</td></tr>
          ${description ? `<tr><td style="padding:6px 0;color:#718096;">Description</td><td style="padding:6px 0;text-align:right;">${description}</td></tr>` : ''}
          ${internationalInfo}
          ${transactionId ? `<tr><td style="padding:6px 0;color:#718096;">Référence</td><td style="padding:6px 0;text-align:right;font-family:monospace;font-size:12px;">${transactionId}</td></tr>` : ''}
        </table>
        <hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0;">
        <p style="margin:0;font-size:12px;color:#a0aec0;text-align:center;">224Solutions — Transfert sécurisé</p>
      </div>
    </div>
  `;
}

function buildReceiverHtml(params: {
  senderName: string;
  receiverName: string;
  amountSent: number;
  senderCurrency: string;
  amountReceived: number;
  receiverCurrency: string;
  description?: string;
  isInternational: boolean;
  transactionId?: string;
  date: string;
}): string {
  const { senderName, amountSent, senderCurrency, amountReceived, receiverCurrency, description, isInternational, transactionId, date } = params;
  return `
    <div style="font-family:sans-serif;max-width:600px;margin:0 auto;padding:24px;background:#f7fafc;">
      <div style="background:#fff;border-radius:12px;padding:32px;box-shadow:0 1px 3px rgba(0,0,0,0.1);">
        <div style="text-align:center;margin-bottom:24px;">
          <div style="background:#f0fff4;border-radius:50%;width:64px;height:64px;display:inline-flex;align-items:center;justify-content:center;font-size:32px;">💰</div>
          <h1 style="margin:12px 0 4px;font-size:20px;color:#1a202c;">Transfert reçu</h1>
          <p style="margin:0;color:#718096;font-size:14px;">${date}</p>
        </div>
        <div style="background:#f0fff4;border-radius:8px;padding:20px;text-align:center;margin-bottom:24px;">
          <p style="margin:0;font-size:13px;color:#718096;">Montant reçu</p>
          <p style="margin:4px 0 0;font-size:28px;font-weight:700;color:#276749;">+${formatAmount(amountReceived, receiverCurrency)}</p>
          ${isInternational ? `<p style="margin:4px 0 0;font-size:14px;color:#718096;">Envoyé : ${formatAmount(amountSent, senderCurrency)} par ${senderName}</p>` : ''}
        </div>
        <table style="width:100%;border-collapse:collapse;">
          <tr><td style="padding:6px 0;color:#718096;">Expéditeur</td><td style="padding:6px 0;text-align:right;font-weight:600;">${senderName}</td></tr>
          ${description ? `<tr><td style="padding:6px 0;color:#718096;">Description</td><td style="padding:6px 0;text-align:right;">${description}</td></tr>` : ''}
          ${transactionId ? `<tr><td style="padding:6px 0;color:#718096;">Référence</td><td style="padding:6px 0;text-align:right;font-family:monospace;font-size:12px;">${transactionId}</td></tr>` : ''}
        </table>
        <hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0;">
        <p style="margin:0;font-size:12px;color:#a0aec0;text-align:center;">224Solutions — Transfert sécurisé</p>
      </div>
    </div>
  `;
}

export async function sendTransactionEmails(params: TransactionEmailParams): Promise<void> {
  const { senderId, receiverId, amountSent, amountReceived, senderCurrency, receiverCurrency, description, isInternational, rateUsed, transactionId } = params;

  let senderProfile: UserProfile | null = null;
  let receiverProfile: UserProfile | null = null;
  try {
    [senderProfile, receiverProfile] = await Promise.all([
      getProfile(senderId),
      getProfile(receiverId),
    ]);
  } catch (err: any) {
    logger.warn(`[TransactionEmail] Could not load profiles: ${err?.message}`);
    return;
  }

  const senderName = getDisplayName(senderProfile, 'Expéditeur');
  const receiverName = getDisplayName(receiverProfile, 'Destinataire');
  const date = new Date().toLocaleString('fr-FR', { dateStyle: 'long', timeStyle: 'short' });

  const emailPromises: Promise<boolean>[] = [];

  if (senderProfile?.email) {
    const html = buildSenderHtml({ senderName, receiverName, amountSent, senderCurrency, amountReceived, receiverCurrency, description, isInternational, rateUsed, transactionId, date });
    const subject = isInternational
      ? `Transfert international envoyé : ${formatAmount(amountSent, senderCurrency)}`
      : `Transfert envoyé : ${formatAmount(amountSent, senderCurrency)}`;
    emailPromises.push(sendEmail(senderProfile.email, subject, html));
  }

  if (receiverProfile?.email) {
    const html = buildReceiverHtml({ senderName, receiverName, amountSent, senderCurrency, amountReceived, receiverCurrency, description, isInternational, transactionId, date });
    const subject = isInternational
      ? `Transfert international reçu : ${formatAmount(amountReceived, receiverCurrency)}`
      : `Transfert reçu : ${formatAmount(amountReceived, receiverCurrency)}`;
    emailPromises.push(sendEmail(receiverProfile.email, subject, html));
  }

  if (emailPromises.length === 0) {
    logger.info('[TransactionEmail] No emails to send (no profiles with email found)');
    return;
  }

  try {
    const results = await Promise.all(emailPromises);
    const sent = results.filter(Boolean).length;
    logger.info(`[TransactionEmail] Sent ${sent}/${emailPromises.length} transaction emails (txId=${transactionId || 'N/A'})`);
  } catch (err: any) {
    logger.warn(`[TransactionEmail] Batch send error: ${err?.message}`);
  }
}
