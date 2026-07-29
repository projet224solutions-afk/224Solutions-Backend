import { logger } from '../config/logger.js';

/**
 * Client ChapChapPay PUSH (versement sortant mobile money) — PORT NODE de
 * supabase/functions/_shared/chapchappay-client.ts (initiatePushPayment). Sert le disbursement
 * des RETRAITS zone Afrique (OM/MoMo). Flux financier dans Node. FAIL-CLOSED : sans secrets env,
 * aucun versement (le retrait reste `pending`, résolu par la file PDG).
 *
 * Secrets (env only, jamais en base, jamais loggés) :
 *   CCP_API_KEY, CCP_SECRET_KEY | CCP_ENCRYPTION_KEY. Base : https://chapchappay.com.
 * ⚠️ ÉTAPE 0 (Thierno) : permission « transfer/payout » active + preuve sandbox avant go-live.
 */

const BASE_URL = 'https://chapchappay.com';

function apiKey(): string | undefined { return process.env.CCP_API_KEY?.trim(); }
function signKey(): string | undefined { return (process.env.CCP_ENCRYPTION_KEY || process.env.CCP_SECRET_KEY)?.trim(); }

/** Le canal de versement ChapChap est-il configuré ? */
export function chapchapPayoutConfigured(): boolean {
  return Boolean(apiKey() && signKey());
}

/** Format téléphone Guinée international (224XXXXXXXXX). */
function formatPhone(msisdn: string): string {
  const d = (msisdn || '').replace(/\D/g, '');
  if (d.startsWith('224')) return d;
  if (d.startsWith('00224')) return d.slice(2);
  if (d.length === 9) return `224${d}`;
  return d;
}

export interface PushResult {
  success: boolean; operationId?: string; status?: string; error?: string;
}

/**
 * Déclenche un PUSH (versement) OM/MoMo vers `recipientPhone`. NE MARQUE RIEN — l'appelant
 * (attemptDisbursement) décide paid/refund selon le résultat. Idempotence applicative via orderId.
 */
export async function initiatePush(params: {
  amount: number; recipientPhone: string; operator: 'orange_money' | 'mtn_momo';
  orderId: string; description?: string;
}): Promise<PushResult> {
  if (!chapchapPayoutConfigured()) return { success: false, error: 'CHAPCHAP_NOT_CONFIGURED' };
  try {
    const resp = await fetch(`${BASE_URL}/api/transfer/create`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json',
                 'CCP-Api-Key': apiKey() as string, 'User-Agent': '224Solutions/2.0' },
      body: JSON.stringify({
        amount: Math.round(params.amount),
        order_id: params.orderId,
        recipient_phone: formatPhone(params.recipientPhone),
        recipient_name: 'Retrait 224Solutions',
        payment_method: params.operator,
        description: params.description || 'Retrait 224Solutions',
      }),
    });
    const json: any = await resp.json().catch(() => ({}));
    if (!resp.ok) return { success: false, error: json?.error || json?.message || `Erreur ${resp.status}` };
    return { success: true, operationId: String(json?.operation_id || params.orderId), status: json?.status || 'pending' };
  } catch (e: any) {
    logger.error(`[ChapChapPush] initiatePush: ${e?.message}`);
    return { success: false, error: e?.message || 'CHAPCHAP_ERROR' };
  }
}

/** Statut réel d'un versement (par operation_id / order_id). */
export async function checkPushStatus(operationId?: string, orderId?: string): Promise<{ status: string } | null> {
  if (!chapchapPayoutConfigured()) return null;
  try {
    const resp = await fetch(`${BASE_URL}/api/payment/status`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Accept': 'application/json',
                 'CCP-Api-Key': apiKey() as string, 'User-Agent': '224Solutions/2.0' },
      body: JSON.stringify({ operation_id: operationId, order_id: orderId }),
    });
    const json: any = await resp.json().catch(() => ({}));
    if (!resp.ok) return null;
    return { status: String(json?.status || 'unknown') };
  } catch (e: any) {
    logger.error(`[ChapChapPush] checkPushStatus: ${e?.message}`);
    return null;
  }
}
