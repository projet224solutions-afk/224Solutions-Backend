import crypto from 'node:crypto';
import { logger } from '../config/logger.js';

/**
 * Client Wave (mobile money, zone Afrique de l'Ouest — Sénégal / Côte d'Ivoire, XOF) via l'API
 * Wave Business « Checkout » officielle (https://docs.wave.com). Flux financier dans le backend
 * Node (RÈGLE archi). FAIL-CLOSED : sans clé env, rien ne part et rien n'est cru payé.
 *
 * A.0 (vérifié) : ni Djomy (enum OM/MOMO/KULU/SOUTRA_MONEY/PAYCARD, aucun WAVE) ni CinetPay (Wave
 * seulement via sa page hébergée multi-opérateurs, pas de canal Wave dédié par API) n'offrent un
 * bouton Wave propre → intégration Wave Business DIRECTE, fail-closed jusqu'aux clés de Thierno.
 *
 * ⚠️ ÉTAPE 0 (Thierno) avant mise en service : compte Wave Business approuvé, `WAVE_API_KEY` +
 * `WAVE_WEBHOOK_SECRET` posés en env, et un checkout sandbox de preuve. Sans ça → 503, jamais un
 * faux « payé ». Devise d'encaissement Wave = XOF (Sénégal/CI) — la portée pays vient du compte Wave.
 *
 * Secrets (env only, jamais en base, jamais loggés) :
 *   WAVE_API_KEY, WAVE_WEBHOOK_SECRET, WAVE_SANDBOX ('true' par défaut → base sandbox).
 */

function apiKey(): string | undefined { return process.env.WAVE_API_KEY?.trim(); }
function webhookSecret(): string | undefined { return process.env.WAVE_WEBHOOK_SECRET?.trim(); }

function baseUrl(): string {
  // Wave n'expose qu'un seul host d'API ; le mode sandbox est porté par la CLÉ (clé de test).
  return 'https://api.wave.com';
}

/** Le rail Wave est-il configuré ? Sinon → fail-closed en amont (routeur/route/UI). */
export function waveConfigured(): boolean {
  return Boolean(apiKey());
}

export interface WaveInit {
  success: boolean; waveLaunchUrl?: string; sessionId?: string; error?: string;
}

/**
 * Initie une session de paiement Wave hébergée (redirection vers `wave_launch_url`).
 * NE CRÉDITE RIEN — renvoie l'URL de paiement. `clientReference` = référence marchande unique
 * (retrouvée au webhook + à la relecture de statut). Le crédit vendeur se fait UNIQUEMENT au
 * webhook vérifié → `settle_qr_payment`.
 */
export async function initiateCheckout(params: {
  clientReference: string; amount: number; currency: string;
  successUrl: string; errorUrl: string;
}): Promise<WaveInit> {
  if (!waveConfigured()) return { success: false, error: 'WAVE_NOT_CONFIGURED' };
  try {
    const resp = await fetch(`${baseUrl()}/v1/checkout/sessions`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey()}`,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: JSON.stringify({
        amount: String(Math.round(params.amount)),
        currency: params.currency.toUpperCase(),
        success_url: params.successUrl,
        error_url: params.errorUrl,
        client_reference: params.clientReference,
      }),
    });
    const data: any = await resp.json().catch(() => ({}));
    if (resp.ok && data?.wave_launch_url && data?.id) {
      return { success: true, waveLaunchUrl: data.wave_launch_url, sessionId: String(data.id) };
    }
    return { success: false, error: `${resp.status}: ${data?.message || data?.code || 'init Wave échouée'}` };
  } catch (e: any) {
    logger.error(`[Wave] initiateCheckout: ${e?.message}`);
    return { success: false, error: e?.message || 'WAVE_ERROR' };
  }
}

export interface WaveStatus {
  status: 'ACCEPTED' | 'REFUSED' | 'PENDING' | 'UNKNOWN';
  amount?: number; currency?: string;
}

/**
 * Statut RÉEL d'une session (autoritaire — à re-vérifier avant tout crédit au webhook).
 * Wave : `payment_status` ∈ processing|succeeded|failed ; `checkout_status` ∈ open|complete|expired.
 */
export async function checkSessionStatus(sessionId: string): Promise<WaveStatus | null> {
  if (!waveConfigured()) return null;
  try {
    const resp = await fetch(`${baseUrl()}/v1/checkout/sessions/${encodeURIComponent(sessionId)}`, {
      method: 'GET',
      headers: { 'Authorization': `Bearer ${apiKey()}`, 'Accept': 'application/json' },
    });
    const data: any = await resp.json().catch(() => ({}));
    const pay = String(data?.payment_status || '').toLowerCase();
    const co = String(data?.checkout_status || '').toLowerCase();
    let status: WaveStatus['status'] = 'UNKNOWN';
    if (pay === 'succeeded' || co === 'complete') status = 'ACCEPTED';
    else if (pay === 'failed' || co === 'expired') status = 'REFUSED';
    else if (pay === 'processing' || co === 'open') status = 'PENDING';
    return { status, amount: Number(data?.amount) || undefined, currency: data?.currency };
  } catch (e: any) {
    logger.error(`[Wave] checkSessionStatus: ${e?.message}`);
    return null;
  }
}

/**
 * Vérifie la signature du webhook Wave (en-tête `Wave-Signature: t=<ts>,v1=<hmac>`).
 * HMAC-SHA256 de `${t}${rawBody}` avec `WAVE_WEBHOOK_SECRET`. Fail-closed : sans secret/en-tête →
 * false. Comparaison à temps constant. La vérif signature s'accompagne TOUJOURS d'un re-statut
 * `checkSessionStatus` (autoritaire) — jamais l'un sans l'autre.
 * ⚠️ Ordre exact de concaténation à confirmer en sandbox (ÉTAPE 0), comme pour CinetPay.
 */
export function verifyWebhookSignature(rawBody: string, signatureHeader: string | undefined): boolean {
  const key = webhookSecret();
  if (!key) { logger.warn('[Wave] webhook: WAVE_WEBHOOK_SECRET absente — rejeté'); return false; }
  if (!signatureHeader) return false;
  const parts = Object.fromEntries(
    signatureHeader.split(',').map((kv) => kv.trim().split('=') as [string, string]),
  );
  const t = parts['t'];
  const v1 = parts['v1'];
  if (!t || !v1) return false;
  const expected = crypto.createHmac('sha256', key).update(`${t}${rawBody}`, 'utf8').digest('hex');
  const a = Buffer.from(v1); const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
