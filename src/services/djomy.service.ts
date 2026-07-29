import crypto from 'node:crypto';
import { logger } from '../config/logger.js';

/**
 * Client Djomy — PORT NODE fidèle de supabase/functions/_shared/djomy-client.ts
 * (doc: https://developers.djomy.africa). Le flux financier vit dans le backend Node
 * (exigence « un seul chemin financier ») ; l'Edge ne sert au plus que de relais signé.
 *
 * - Signature HMAC-SHA256 pour X-API-KEY : HMAC(key=clientSecret, message=clientId) → hex.
 * - X-API-KEY: `${clientId}:${signature}`.
 * - Auth Bearer via POST /v1/auth (body {}), token caché.
 * - Payin (collecte) OM/MoMo via POST /v1/payments (SANS redirection).
 * - Statut réel via GET /v1/payments/:id/status.
 * - Vérification signature webhook `X-Webhook-Signature: v1:<hmac(payload, clientSecret)>`.
 * Secrets UNIQUEMENT depuis l'env (jamais en base, jamais loggés en clair).
 */

export type DjomyOperator = 'orange_money' | 'mtn_momo';
export type DjomyMethod = 'OM' | 'MOMO';

export interface DjomyStatusResponse {
  transactionId: string;
  status: 'CREATED' | 'PENDING' | 'SUCCESS' | 'FAILED' | 'CANCELLED' | 'REDIRECTED';
  paidAmount?: number;
  receivedAmount?: number;
  fees?: number;
  paymentMethod?: string;
  payerIdentifier?: string;
  merchantPaymentReference?: string;
  currency?: string;
}

interface TokenData { accessToken: string; expiresAt: number; }
const tokenCache: Record<string, TokenData> = {};

function hmacHex(key: string, message: string): string {
  return crypto.createHmac('sha256', key).update(message, 'utf8').digest('hex');
}

/** Signature X-API-KEY = HMAC_SHA256(clientId, clientSecret). */
export function generateXApiKey(clientId: string, clientSecret: string): string {
  return `${clientId}:${hmacHex(clientSecret, clientId)}`;
}

/**
 * Vérifie une signature webhook Djomy. En-tête: `X-Webhook-Signature: v1:<hex>`.
 * Clé = DJOMY_WEBHOOK_SECRET (repli sur clientSecret). Comparaison à temps constant.
 * Fail-closed : sans secret ou header invalide → false.
 */
export function verifyWebhookSignature(signatureHeader: string | undefined, payload: string): boolean {
  const secret = (process.env.DJOMY_WEBHOOK_SECRET || activeSecret() || '').trim();
  if (!secret) { logger.warn('[Djomy] webhook: aucun secret configuré — rejeté'); return false; }
  if (!signatureHeader) return false;
  const parts = signatureHeader.split(':');
  if (parts.length !== 2 || parts[0] !== 'v1' || !parts[1]) return false;
  const expected = hmacHex(secret, payload);
  const a = Buffer.from(parts[1]);
  const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// ── Résolution des credentials (env only) ────────────────────────────────────
function sandboxMode(): boolean {
  return process.env.DJOMY_SANDBOX !== 'false'; // défaut sandbox tant que prod pas activée
}
function activeClientId(): string | undefined {
  return (sandboxMode() ? process.env.DJOMY_CLIENT_ID_SANDBOX : process.env.DJOMY_CLIENT_ID)?.trim();
}
function activeSecret(): string | undefined {
  return (sandboxMode() ? process.env.DJOMY_CLIENT_SECRET_SANDBOX : process.env.DJOMY_CLIENT_SECRET)?.trim();
}
/** Le canal Djomy est-il configuré (secrets présents) ? Sinon → fail-closed en amont. */
export function djomyConfigured(): boolean {
  return Boolean(activeClientId() && activeSecret());
}

class DjomyClient {
  private clientId: string;
  private clientSecret: string;
  private baseUrl: string;
  private xApiKey: string;

  constructor(clientId: string, clientSecret: string, useSandbox: boolean) {
    this.clientId = clientId;
    this.clientSecret = clientSecret;
    this.baseUrl = useSandbox ? 'https://sandbox-api.djomy.africa' : 'https://api.djomy.africa';
    this.xApiKey = generateXApiKey(clientId, clientSecret);
  }

  private async getAccessToken(): Promise<string> {
    const cacheKey = `${this.baseUrl}_${this.clientId}`;
    const cached = tokenCache[cacheKey];
    if (cached && cached.expiresAt > Date.now()) return cached.accessToken;

    const resp = await fetch(`${this.baseUrl}/v1/auth`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json', 'Accept': 'application/json',
        'X-API-KEY': this.xApiKey, 'User-Agent': '224Solutions/2.0',
      },
      body: JSON.stringify({}),
    });
    const text = await resp.text();
    if (!resp.ok) throw new Error(`Djomy auth ${resp.status}`);
    const data: any = JSON.parse(text);
    const td = data.data || data;
    const accessToken = td.access_token || td.accessToken;
    const expiresIn = td.expires_in || td.expiresIn || data.expires_in || 3600;
    if (!accessToken) throw new Error('Djomy auth: token manquant');
    tokenCache[cacheKey] = { accessToken, expiresAt: Date.now() + (expiresIn - 300) * 1000 };
    return accessToken;
  }

  private async headers(): Promise<Record<string, string>> {
    return {
      'Content-Type': 'application/json', 'Accept': 'application/json', 'User-Agent': '224Solutions/2.0',
      'Authorization': `Bearer ${await this.getAccessToken()}`, 'X-API-KEY': this.xApiKey,
    };
  }

  /** POST /v1/payments — collecte OM/MOMO (push USSD), SANS redirection. */
  async initiatePayment(body: {
    paymentMethod: DjomyMethod; payerIdentifier: string; amount: number; countryCode: string;
    description?: string; merchantPaymentReference?: string; metadata?: Record<string, unknown>;
  }): Promise<{ success: boolean; transactionId?: string; status?: string; error?: string; data?: unknown }> {
    const resp = await fetch(`${this.baseUrl}/v1/payments`, {
      method: 'POST', headers: await this.headers(), body: JSON.stringify(body),
    });
    const text = await resp.text();
    if (!resp.ok) return { success: false, error: `${resp.status}: ${text}` };
    const data: any = JSON.parse(text);
    return { success: true, transactionId: data.transactionId || data.id, status: data.status, data };
  }

  /** GET /v1/payments/:id/status — statut RÉEL (à re-vérifier avant tout crédit). */
  async getPaymentStatus(transactionId: string): Promise<DjomyStatusResponse | null> {
    const resp = await fetch(`${this.baseUrl}/v1/payments/${encodeURIComponent(transactionId)}/status`, {
      method: 'GET', headers: await this.headers(),
    });
    const text = await resp.text();
    if (!resp.ok) { logger.warn(`[Djomy] status ${transactionId}: ${resp.status}`); return null; }
    return JSON.parse(text) as DjomyStatusResponse;
  }
}

let singleton: DjomyClient | null = null;
function client(): DjomyClient {
  const id = activeClientId(); const secret = activeSecret();
  if (!id || !secret) throw new Error('DJOMY_NOT_CONFIGURED');
  if (!singleton) singleton = new DjomyClient(id, secret, sandboxMode());
  return singleton;
}

/** Normalise un numéro guinéen au format international attendu par Djomy (00224XXXXXXXXX). */
export function toDjomyPayerIdentifier(msisdn: string): string {
  const digits = (msisdn || '').replace(/\D/g, '');
  if (digits.startsWith('00224')) return digits;
  if (digits.startsWith('224')) return `00${digits}`;
  if (digits.length === 9) return `00224${digits}`;
  return digits;
}

/**
 * Wrapper BLOC 1 : initie un PAYIN (collecte) OM/MoMo. NE CRÉDITE RIEN — déclenche seulement le
 * push USSD chez le payeur. Le crédit vendeur se fait UNIQUEMENT au webhook vérifié.
 */
export async function initiatePayin(params: {
  amount: number; currency: string; msisdn: string; operator: DjomyOperator; reference: string; description?: string;
}): Promise<{ success: boolean; transactionId?: string; status?: string; error?: string }> {
  if (!djomyConfigured()) return { success: false, error: 'DJOMY_NOT_CONFIGURED' };
  const method: DjomyMethod = params.operator === 'orange_money' ? 'OM' : 'MOMO';
  try {
    const res = await client().initiatePayment({
      paymentMethod: method,
      payerIdentifier: toDjomyPayerIdentifier(params.msisdn),
      amount: params.amount,
      countryCode: 'GN',
      description: params.description || 'Paiement 224Solutions',
      merchantPaymentReference: params.reference,
    });
    return { success: res.success, transactionId: res.transactionId, status: res.status, error: res.error };
  } catch (e: any) {
    logger.error(`[Djomy] initiatePayin: ${e?.message}`);
    return { success: false, error: e?.message || 'DJOMY_ERROR' };
  }
}

/** Statut réel d'une transaction Djomy (par son transactionId). */
export async function checkStatus(transactionId: string): Promise<DjomyStatusResponse | null> {
  if (!djomyConfigured()) return null;
  try { return await client().getPaymentStatus(transactionId); }
  catch (e: any) { logger.error(`[Djomy] checkStatus: ${e?.message}`); return null; }
}
