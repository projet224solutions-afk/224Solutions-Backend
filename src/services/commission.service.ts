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
  pending?: boolean; // leg devise-agent sans taux frais → mis en attente (jamais perdu)
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
  transactionId?: string,
  amountCurrency: string = 'GNF', // 🌍 devise SOURCE du montant (grille par pays). Défaut GNF.
): Promise<CommissionTriggerResult> {
  // Validation montant (anti-exploit: pas de montants négatifs/nuls)
  if (typeof amount !== 'number' || amount <= 0) {
    logger.warn(`[Commission] Invalid amount: ${amount}`);
    return { success: false, error: 'Amount must be > 0' };
  }

  const srcCur = String(amountCurrency || 'GNF').toUpperCase();
  let gnfBase = amount;
  let baseFx: { rate: number; rate_at: string; source: string } | null = null;

  try {
    // 1) BASE DE CALCUL EN GNF. La commission raisonne en GNF (base du coffre PDG). Si le montant
    //    source est dans une autre devise (grille par pays : XOF/SLE/EUR…), on convertit source→GNF
    //    via _acash_fx (taux frais, TRACÉ). Taux indisponible → PENDING (devise SOURCE conservée) :
    //    JAMAIS de calcul sur base fausse, JAMAIS d'abandon silencieux.
    if (srcCur !== 'GNF') {
      const { data: fx, error: fxErr } = await supabaseAdmin.rpc('_acash_fx', {
        p_amount: amount, p_from: srcCur, p_to: 'GNF',
      } as any);
      const conv = Number((fx as any)?.converted);
      if (fxErr || !Number.isFinite(conv) || conv <= 0) {
        if (transactionId) {
          await supabaseAdmin.rpc('affiliate_commission_enqueue', {
            p_source_type: transactionType, p_source_ref: String(transactionId), p_beneficiary: userId,
            p_fee_amount: amount, p_fee_currency: srcCur, p_reason: 'NO_RATE_SOURCE',
            p_detail: { source_currency: srcCur, source_amount: amount },
          } as any);
          return { success: true, pending: true, hasAgent: true };
        }
        logger.warn(`[Commission] taux source ${srcCur}→GNF indisponible sans transactionId → non mis en attente (userId=${userId})`);
        return { success: false, error: 'NO_RATE_SOURCE' };
      }
      gnfBase = conv;
      baseFx = { rate: Number((fx as any).rate), rate_at: String((fx as any).rate_at), source: String((fx as any).source) };
    }

    // 2) Crédit sur BASE GNF (le maillon GNF→devise agent est tracé dans credit_agent_wallet_gnf).
    const { data, error } = await supabaseAdmin.rpc('credit_agent_commission', {
      p_user_id: userId,
      p_amount: Math.round(gnfBase),
      p_source_type: transactionType,
      p_transaction_id: transactionId || null,
      p_metadata: { currency: 'GNF', source: 'backend-node', triggered_at: new Date().toISOString() },
    });

    if (error) {
      logger.error(`[Commission] credit_agent_commission RPC error: ${error.message}`);
      return { success: false, error: error.message };
    }

    const result = data as any;

    // Leg GNF→devise agent indisponible → PENDING (FX_DOWN), base GNF conservée (source déjà convertie).
    if (result?.fx_pending) {
      if (transactionId) {
        await supabaseAdmin.rpc('affiliate_commission_enqueue', {
          p_source_type: transactionType, p_source_ref: String(transactionId), p_beneficiary: userId,
          p_fee_amount: Math.round(gnfBase), p_fee_currency: 'GNF', p_reason: 'FX_DOWN',
          p_detail: { agent_fx: result?.error || 'AGENT_FX_UNAVAILABLE' },
        } as any);
      } else {
        logger.warn(`[Commission] fx_pending sans transactionId → impossible de mettre en attente (userId=${userId})`);
      }
      return { success: true, pending: true, hasAgent: true };
    }

    // 3) Trace du leg SOURCE→GNF sur la/les ligne(s) de commission (sous-agent + parent partagent la base).
    if (baseFx && transactionId && result?.has_agent && !result?.already_processed) {
      await supabaseAdmin.from('agent_commissions_log').update({
        base_currency: srcCur, base_amount: amount,
        base_fx_rate: baseFx.rate, base_fx_rate_at: baseFx.rate_at, base_fx_source: baseFx.source,
      }).eq('transaction_id', transactionId).eq('related_user_id', userId);
    }

    logger.info('[Commission] Affiliate commission processed', {
      userId, transactionType, amount, srcCur, gnfBase,
      hasAgent: result?.has_agent, alreadyProcessed: result?.already_processed,
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
