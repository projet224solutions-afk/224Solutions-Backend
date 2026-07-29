import { logger } from '../config/logger.js';
import { markWithdrawalPaid, refundWithdrawal } from './wallet.service.js';

/**
 * Disbursement (versement sortant) des retraits — côté backend Node UNIQUEMENT (exigence
 * « un seul chemin financier »). Adaptateur par prestataire mobile money.
 *
 * ⚠️ FAIL-CLOSED : tant que le client prestataire + ses secrets (env, JAMAIS en base) ne sont
 * pas branchés, on N'ATTEND PAS et on NE PRÉTEND PAS avoir versé. Le retrait reste `pending`
 * (argent immobilisé, remboursable) — il sera résolu par le disbursement réel (à venir) ou par
 * le PDG (mark_paid après virement / refund). Jamais de faux « payé ».
 *
 * Câblage réel à venir (décision PDG « disbursement auto ChapChap/Djomy ») : porter le client
 * push ChapChapPay en Node (cf. supabase/functions/_shared/chapchappay-client.ts), puis ici :
 *   1. appeler le PUSH prestataire (montant net, téléphone bénéficiaire) ;
 *   2. ACCEPTÉ  → markWithdrawalPaid(id, providerRef)  (ou mark_withdrawal_processing si async) ;
 *   3. REFUSÉ   → refundWithdrawal(id, raison)          (remboursement atomique).
 */

export interface DisbursementTarget {
  withdrawalId: string;
  amount: number;
  currency: string;
  destinationType: string;            // 'momo' | 'bank' | 'card' | ...
  destination: Record<string, unknown>;
}

export interface DisbursementResult {
  attempted: boolean;
  status: 'pending' | 'processing' | 'paid' | 'refunded';
  error_code?: string;
  error?: string;
}

/** Un prestataire de disbursement momo est-il configuré (secrets en env) ? */
function momoDisburseConfigured(): boolean {
  return Boolean(
    (process.env.CCP_API_KEY && (process.env.CCP_SECRET_KEY || process.env.CCP_ENCRYPTION_KEY)) ||
    process.env.DJOMY_CLIENT_SECRET,
  );
}

/**
 * Tente le versement d'un retrait déjà en `pending`. Ne débite/rembourse jamais directement :
 * délègue aux RPC verrouillées (markWithdrawalPaid / refundWithdrawal). Retourne l'état atteint.
 */
export async function attemptDisbursement(target: DisbursementTarget): Promise<DisbursementResult> {
  if (target.destinationType === 'bank' || target.destinationType === 'card') {
    // Virement bancaire/carte : traitement PDG (machine à états), pas de disbursement momo auto.
    return { attempted: false, status: 'pending', error_code: 'MANUAL_REVIEW' };
  }

  if (!momoDisburseConfigured()) {
    // Fail-closed : pas de secret prestataire → on laisse la ligne `pending`, honnête.
    logger.warn(`[Disbursement] Prestataire momo non configuré — retrait ${target.withdrawalId} laissé en pending`);
    return { attempted: false, status: 'pending', error_code: 'PAYOUT_PROVIDER_NOT_CONFIGURED' };
  }

  // TODO (creds fournis) : appeler le PUSH ChapChapPay/Djomy porté en Node, puis :
  //   ok   -> return markWithdrawalPaid(...) puis { attempted:true, status:'paid' }
  //   fail -> return refundWithdrawal(...)   puis { attempted:true, status:'refunded' }
  // En attendant le port du client, on reste fail-closed même si des secrets existent, pour ne
  // jamais marquer `paid` sans versement réellement confirmé.
  void markWithdrawalPaid; void refundWithdrawal;
  logger.warn(`[Disbursement] Client push Node pas encore branché — retrait ${target.withdrawalId} laissé en pending`);
  return { attempted: false, status: 'pending', error_code: 'DISBURSEMENT_NOT_WIRED' };
}
