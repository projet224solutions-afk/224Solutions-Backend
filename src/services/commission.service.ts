/**
 * 🤝 COMMISSION SERVICE - Centralisé côté Node.js
 *
 * Responsabilités :
 *  - Déclenchement des commissions affiliées après un paiement validé
 *  - Appel du RPC SQL credit_agent_commission (anti-doublon intégré en base)
 *  - Journalisation des résultats de commission
 *
 * Migré depuis l'Edge Function affiliate-commission-trigger
 */

import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

export interface CommissionTriggerResult {
  success: boolean;
  hasAgent?: boolean;
  alreadyProcessed?: boolean;
  commissionAmount?: number;
  error?: string;
}

/**
 * Déclenche le calcul et crédit de commission affiliée.
 *
 * Le RPC credit_agent_commission gère :
 * - Recherche de l'agent affilié (direct + sous-affiliation)
 * - Anti-doublon par transaction_id
 * - Calcul commission agent principal / sous-agent
 * - Crédit du wallet agent
 * - Log dans agent_commissions_log
 */
export async function triggerAffiliateCommission(
  userId: string,
  amount: number,
  transactionType: string,
  transactionId?: string
): Promise<CommissionTriggerResult> {
  // Validation montant (anti-exploit: pas de montants négatifs/nuls)
  if (typeof amount !== 'number' || amount <= 0) {
    logger.warn(`[Commission] Invalid amount: ${amount}`);
    return { success: false, error: 'Amount must be > 0' };
  }

  try {
    const { data, error } = await supabaseAdmin.rpc('credit_agent_commission', {
      p_user_id: userId,
      p_amount: amount,
      p_source_type: transactionType,
      p_transaction_id: transactionId || null,
      p_metadata: {
        currency: 'GNF', // Validé: uniquement 'GNF' autorisé
        source: 'backend-node',
        triggered_at: new Date().toISOString(),
      },
    });

    if (error) {
      logger.error(`[Commission] credit_agent_commission RPC error: ${error.message}`);
      return { success: false, error: error.message };
    }

    const result = data as any;
    logger.info('[Commission] Affiliate commission processed', {
      userId,
      transactionType,
      amount,
      hasAgent: result?.has_agent,
      alreadyProcessed: result?.already_processed,
    });

    return {
      success: true,
      hasAgent: result?.has_agent || false,
      alreadyProcessed: result?.already_processed || false,
      commissionAmount: result?.agent_commission || result?.total_commissions,
    };
  } catch (err: any) {
    logger.error(`[Commission] triggerAffiliateCommission exception: ${err.message}`);
    return { success: false, error: err.message };
  }
}

/**
 * Enregistre une vente affiliée (tracking de conversion).
 * Appelé quand un paiement client aboutit et que ce client est affilié à un agent.
 */
export async function trackAffiliateSale(
  userId: string,
  vendorId: string,
  amount: number,
  transactionId: string,
  productName?: string
): Promise<{ success: boolean; error?: string }> {
  try {
    // Vérifier si l'utilisateur est affilié à un agent
    const { data: affiliation } = await supabaseAdmin
      .from('user_agent_affiliations')
      .select('agent_id, affiliate_link_id')
      .eq('user_id', userId)
      .maybeSingle();

    if (!affiliation?.agent_id) {
      return { success: true }; // Pas d'affiliation — rien à faire
    }

    // Enregistrer la vente affiliée
    const { error } = await supabaseAdmin.from('affiliate_sales').insert({
      agent_id: affiliation.agent_id,
      buyer_id: userId,
      vendor_id: vendorId,
      affiliate_link_id: affiliation.affiliate_link_id,
      transaction_id: transactionId,
      sale_amount: amount,
      product_name: productName || null,
      status: 'pending',
      created_at: new Date().toISOString(),
    });

    if (error) {
      // La table affiliate_sales peut ne pas exister (fallback silencieux)
      logger.warn(`[Commission] trackAffiliateSale insert failed: ${error.message}`);
      return { success: true }; // Non-bloquant
    }

    logger.info(`[Commission] Affiliate sale tracked: agent=${affiliation.agent_id}, amount=${amount}`);
    return { success: true };
  } catch (err: any) {
    logger.warn(`[Commission] trackAffiliateSale exception (non-blocking): ${err.message}`);
    return { success: true }; // Non-bloquant — ne doit pas casser le flux principal
  }
}
