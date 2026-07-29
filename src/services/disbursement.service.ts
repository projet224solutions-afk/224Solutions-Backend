import { logger } from '../config/logger.js';
import { markWithdrawalPaid, refundWithdrawal } from './wallet.service.js';
import { resolveZone } from './paymentRouter.service.js';
import { chapchapPayoutConfigured, initiatePush } from './chapchapPayout.service.js';

/**
 * Disbursement (versement sortant) des retraits — backend Node UNIQUEMENT. Le prestataire suit la
 * ZONE DU BÉNÉFICIAIRE (celui qui retire reçoit son argent) : africa → mobile money (ChapChapPay
 * push OM/MoMo) ; west → Stripe payout (virement). Cohérent avec le routeur des encaissements.
 *
 * FAIL-CLOSED : sans prestataire configuré (secrets env), le retrait reste `pending` (argent
 * immobilisé, remboursable, résolu par la file PDG) — JAMAIS un faux « payé ». markWithdrawalPaid /
 * refundWithdrawal ne sont appelés que sur confirmation / échec RÉEL du prestataire.
 */

export interface DisbursementTarget {
  withdrawalId: string;
  userId: string;                     // bénéficiaire du payout (le retireur) → détermine la zone
  amount: number;
  currency: string;
  destinationType: string;            // 'momo' | 'bank' | 'card'
  destination: Record<string, unknown>;
}

export interface DisbursementResult {
  attempted: boolean;
  status: 'pending' | 'processing' | 'paid' | 'refunded';
  error_code?: string;
  error?: string;
}

function extractMomo(dest: Record<string, unknown>): { phone: string; operator: 'orange_money' | 'mtn_momo' } | null {
  const phone = String(dest.phone_number || dest.phone || dest.msisdn || '').trim();
  if (!phone) return null;
  const p = String(dest.provider || dest.operator || dest.network || '').toLowerCase();
  const operator: 'orange_money' | 'mtn_momo' = (p.includes('mtn') || p.includes('momo')) ? 'mtn_momo' : 'orange_money';
  return { phone, operator };
}

export async function attemptDisbursement(target: DisbursementTarget): Promise<DisbursementResult> {
  // Zone du bénéficiaire (le retireur). Inconnue → on laisse pending (pas de défaut silencieux).
  const zone = await resolveZone(target.userId);

  // Virement bancaire/carte : traitement PDG (pas de payout momo auto).
  if (target.destinationType === 'bank' || target.destinationType === 'card') {
    return { attempted: false, status: 'pending', error_code: 'MANUAL_REVIEW' };
  }

  if (zone === 'west') {
    // Occident → Stripe payout (virement SEPA/bancaire). Non branché ici (Stripe Connect/payout) →
    // fail-closed : reste pending, résolu par la file PDG. À câbler comme les autres, avec creds.
    logger.warn(`[Disbursement] zone west (Stripe payout non branché) — retrait ${target.withdrawalId} pending`);
    return { attempted: false, status: 'pending', error_code: 'STRIPE_PAYOUT_NOT_WIRED' };
  }

  // Afrique → mobile money (ChapChapPay push). Fail-closed si non configuré.
  if (!chapchapPayoutConfigured()) {
    logger.warn(`[Disbursement] ChapChapPay non configuré — retrait ${target.withdrawalId} pending`);
    return { attempted: false, status: 'pending', error_code: 'PAYOUT_PROVIDER_NOT_CONFIGURED' };
  }
  const momo = extractMomo(target.destination);
  if (!momo) {
    logger.warn(`[Disbursement] coordonnées momo manquantes — retrait ${target.withdrawalId} pending`);
    return { attempted: false, status: 'pending', error_code: 'MOMO_DESTINATION_MISSING' };
  }

  // order_id déterministe = idempotence applicative côté ChapChap (rejeu = même ordre).
  const orderId = `wd_${target.withdrawalId}`;
  const push = await initiatePush({
    amount: target.amount, recipientPhone: momo.phone, operator: momo.operator,
    orderId, description: 'Retrait 224Solutions',
  });

  if (!push.success) {
    // Échec provider → REMBOURSEMENT ATOMIQUE (l'argent revient au solde). Jamais perdu.
    const ref = await refundWithdrawal(target.withdrawalId, `Payout échoué: ${push.error || 'inconnu'}`);
    logger.warn(`[Disbursement] push échoué retrait ${target.withdrawalId} → refund (${ref.success})`);
    return { attempted: true, status: 'refunded', error_code: 'PAYOUT_FAILED', error: push.error };
  }

  // Accepté par ChapChap → débit rendu définitif (payout_reference = operation_id).
  const paid = await markWithdrawalPaid(target.withdrawalId, push.operationId || orderId);
  if (!paid.success) {
    logger.error(`[Disbursement] push OK mais mark_paid échoué retrait ${target.withdrawalId}: ${paid.error}`);
    return { attempted: true, status: 'processing', error_code: 'MARK_PAID_FAILED' };
  }
  return { attempted: true, status: 'paid' };
}
