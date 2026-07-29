import crypto from 'node:crypto';
import { logger } from '../config/logger.js';

/**
 * Client CinetPay (carte, zone Afrique) — API api-checkout officielle
 * (https://docs.cinetpay.com). Flux financier dans le backend Node (RÈGLE archi).
 * FAIL-CLOSED : sans secrets env, rien ne part et rien n'est cru payé.
 *
 * ⚠️ ÉTAPE 0 (Thierno) avant mise en service : compte marchand Guinée actif, canal CARTE activé,
 * secrets posés en env, et un appel /payment/check sandbox de preuve. Sans ça → 503, jamais un
 * faux « payé ». Devise d'encaissement zone Guinée : GNF (à confirmer côté CinetPay GN).
 *
 * Secrets (env only, jamais en base, jamais loggés) :
 *   CINETPAY_API_KEY, CINETPAY_SITE_ID, CINETPAY_SECRET, CINETPAY_SANDBOX ('true' par défaut).
 */

const BASE_URL = 'https://api-checkout.cinetpay.com/v2';

function apiKey(): string | undefined { return process.env.CINETPAY_API_KEY?.trim(); }
function siteId(): string | undefined { return process.env.CINETPAY_SITE_ID?.trim(); }
function secret(): string | undefined { return process.env.CINETPAY_SECRET?.trim(); }

/** Le canal CinetPay est-il configuré ? Sinon → fail-closed en amont (routeur/route). */
export function cinetpayConfigured(): boolean {
  return Boolean(apiKey() && siteId());
}

export interface CinetpayInit {
  success: boolean; paymentUrl?: string; token?: string; error?: string;
}

/**
 * Initie un paiement CARTE hébergé (redirection). NE CRÉDITE RIEN — renvoie l'URL de paiement.
 * transactionId = référence marchande unique (on la retrouvera au webhook + checkStatus).
 */
export async function initiatePayment(params: {
  transactionId: string; amount: number; currency: string; description: string;
  notifyUrl: string; returnUrl: string;
}): Promise<CinetpayInit> {
  if (!cinetpayConfigured()) return { success: false, error: 'CINETPAY_NOT_CONFIGURED' };
  try {
    const resp = await fetch(`${BASE_URL}/payment`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
      body: JSON.stringify({
        apikey: apiKey(),
        site_id: siteId(),
        transaction_id: params.transactionId,
        amount: Math.round(params.amount),
        currency: params.currency.toUpperCase(),
        description: params.description,
        notify_url: params.notifyUrl,
        return_url: params.returnUrl,
        channels: 'CREDIT_CARD',
      }),
    });
    const data: any = await resp.json().catch(() => ({}));
    // CinetPay : code '201' = created ; data.payment_url / payment_token.
    if (String(data?.code) === '201' && data?.data?.payment_url) {
      return { success: true, paymentUrl: data.data.payment_url, token: data.data.payment_token };
    }
    return { success: false, error: `${data?.code ?? resp.status}: ${data?.message ?? 'init échouée'}` };
  } catch (e: any) {
    logger.error(`[CinetPay] initiatePayment: ${e?.message}`);
    return { success: false, error: e?.message || 'CINETPAY_ERROR' };
  }
}

export interface CinetpayStatus {
  status: 'ACCEPTED' | 'REFUSED' | 'PENDING' | 'UNKNOWN';
  amount?: number; currency?: string;
}

/** Statut RÉEL d'une transaction (autoritaire — à re-vérifier avant tout crédit au webhook). */
export async function checkStatus(transactionId: string): Promise<CinetpayStatus | null> {
  if (!cinetpayConfigured()) return null;
  try {
    const resp = await fetch(`${BASE_URL}/payment/check`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
      body: JSON.stringify({ apikey: apiKey(), site_id: siteId(), transaction_id: transactionId }),
    });
    const data: any = await resp.json().catch(() => ({}));
    // code '00' + data.status ('ACCEPTED' | 'REFUSED' | 'PENDING').
    const raw = String(data?.data?.status || '').toUpperCase();
    const status = (['ACCEPTED', 'REFUSED', 'PENDING'].includes(raw) ? raw : 'UNKNOWN') as CinetpayStatus['status'];
    return { status, amount: Number(data?.data?.amount) || undefined, currency: data?.data?.currency };
  } catch (e: any) {
    logger.error(`[CinetPay] checkStatus: ${e?.message}`);
    return null;
  }
}

/**
 * Vérifie le HMAC du webhook CinetPay (en-tête `x-token` = HMAC-SHA256 de la concaténation des
 * champs POST avec le secret). Fail-closed : sans secret ou token → false. Comparaison à temps
 * constant. NB : la vérif signature s'accompagne TOUJOURS d'un re-statut checkStatus (autoritaire) —
 * jamais l'un sans l'autre. Ordre des champs à confirmer en sandbox (ÉTAPE 0).
 */
export function verifyWebhookToken(form: Record<string, string>, xToken: string | undefined): boolean {
  const key = secret();
  if (!key) { logger.warn('[CinetPay] webhook: CINETPAY_SECRET absente — rejeté'); return false; }
  if (!xToken) return false;
  // Concaténation documentée par CinetPay (ordre des cpm_* du POST de notification).
  const fields = [
    'cpm_site_id', 'cpm_trans_id', 'cpm_trans_date', 'cpm_amount', 'cpm_currency', 'signature',
    'payment_method', 'cel_phone_num', 'cpm_phone_prefixe', 'cpm_language', 'cpm_version',
    'cpm_payment_config', 'cpm_page_action', 'cpm_custom', 'cpm_designation', 'cpm_error_message',
  ];
  const data = fields.map((f) => form[f] ?? '').join('');
  const expected = crypto.createHmac('sha256', key).update(data, 'utf8').digest('hex');
  const a = Buffer.from(xToken); const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
