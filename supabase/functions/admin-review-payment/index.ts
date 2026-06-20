// =====================================================
// EDGE FUNCTION: GESTION ADMIN DES PAIEMENTS
// =====================================================
// Description: Permet aux admins d'approuver/rejeter manuellement
//              les paiements en attente de review
// =====================================================

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import Stripe from 'https://esm.sh/stripe@13.6.0?target=deno';

const STRIPE_KEY = Deno.env.get('STRIPE_SECRET_KEY');
if (!STRIPE_KEY) throw new Error("CRITICAL: STRIPE_SECRET_KEY not configured");
const stripe = new Stripe(STRIPE_KEY, {
  apiVersion: '2023-10-16',
  httpClient: Stripe.createFetchHttpClient(),
});

const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

serve(async (req) => {
  // CORS headers
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      },
    });
  }

  try {
    const { action, releaseId, adminId, notes, reason } = await req.json();

    if (!releaseId || !adminId) {
      throw new Error('releaseId and adminId required');
    }

    if (!['approve', 'reject'].includes(action)) {
      throw new Error('action must be "approve" or "reject"');
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Vérifier que l'utilisateur est admin
    const { data: admin, error: adminError } = await supabase
      .from('profiles')
      .select('id, role, email')
      .eq('id', adminId)
      .single();

    if (adminError || !admin || admin.role !== 'ADMIN') {
      return new Response(
        JSON.stringify({ error: 'Unauthorized: Admin role required' }),
        { status: 403, headers: { 'Content-Type': 'application/json' } }
      );
    }

    console.log(`👨‍💼 Admin ${admin.email} performing action: ${action}`);

    // Récupérer les détails du release
    const { data: release, error: releaseError } = await supabase
      .from('funds_release_schedule')
      .select(`
        *,
        stripe_transactions (
          id,
          stripe_payment_intent_id,
          amount,
          seller_net_amount,
          buyer_id,
          seller_id
        )
      `)
      .eq('id', releaseId)
      .single();

    if (releaseError || !release) {
      throw new Error('Release not found');
    }

    if (release.status !== 'PENDING') {
      throw new Error(`Release already processed: ${release.status}`);
    }

    const transaction = release.stripe_transactions;

    // =====================================================
    // ACTION: APPROUVER
    // =====================================================
    if (action === 'approve') {
      console.log('✅ Approving payment...');

      const { data: approveResult, error: approveError } = await supabase
        .rpc('admin_approve_payment', {
          p_release_id: releaseId,
          p_admin_id: adminId,
          p_notes: notes || null,
        });

      if (approveError) {
        console.error('Error approving payment:', approveError);
        throw approveError;
      }

      // Créer une notification pour le vendeur
      await supabase.from('notifications').insert({
        user_id: transaction.seller_id,
        type: 'PAYMENT_APPROVED',
        title: 'Paiement approuvé',
        message: `Votre paiement de ${transaction.seller_net_amount / 100} XOF a été approuvé par un administrateur.`,
        data: {
          transaction_id: transaction.id,
          release_id: releaseId,
          admin_notes: notes,
        },
      });

      // Enregistrer l'audit
      await supabase.from('admin_audit_logs').insert({
        admin_id: adminId,
        action: 'APPROVE_PAYMENT',
        entity_type: 'funds_release_schedule',
        entity_id: releaseId,
        details: {
          transaction_id: transaction.id,
          amount: transaction.seller_net_amount,
          notes,
        },
      });

      return new Response(
        JSON.stringify({
          success: true,
          action: 'approved',
          release_id: releaseId,
          transaction_id: transaction.id,
          amount: transaction.seller_net_amount,
          message: 'Payment approved and funds released',
        }),
        { headers: { 'Content-Type': 'application/json' } }
      );
    }

    // =====================================================
    // ACTION: REJETER
    // =====================================================
    if (action === 'reject') {
      console.log('❌ Rejecting payment...');

      if (!reason) {
        throw new Error('reason required for rejection');
      }

      const { data: rejectResult, error: rejectError } = await supabase
        .rpc('admin_reject_payment', {
          p_release_id: releaseId,
          p_admin_id: adminId,
          p_reason: reason,
        });

      if (rejectError) {
        console.error('Error rejecting payment:', rejectError);
        throw rejectError;
      }

      // Initier le remboursement via Stripe
      try {
        console.log('💳 Initiating Stripe refund...');
        
        const refund = await stripe.refunds.create({
          payment_intent: transaction.stripe_payment_intent_id,
          reason: 'fraudulent',
          metadata: {
            rejected_by: adminId,
            rejection_reason: reason,
          },
        });

        console.log(`✅ Refund created: ${refund.id}`);

        // Mettre à jour la transaction
        await supabase
          .from('stripe_transactions')
          .update({
            payment_status: 'REFUNDED',
            refunded_at: new Date().toISOString(),
            metadata: {
              ...transaction.metadata,
              refund_id: refund.id,
              rejection_reason: reason,
            },
          })
          .eq('id', transaction.id);

      } catch (stripeError) {
        console.error('Error creating Stripe refund:', stripeError);
        // Continuer même si le remboursement échoue
      }

      // Créer une notification pour le vendeur
      await supabase.from('notifications').insert({
        user_id: transaction.seller_id,
        type: 'PAYMENT_REJECTED',
        title: 'Paiement rejeté',
        message: `Votre paiement de ${transaction.seller_net_amount / 100} XOF a été rejeté. Un remboursement a été initié.`,
        data: {
          transaction_id: transaction.id,
          release_id: releaseId,
          reason,
        },
      });

      // Créer une notification pour l'acheteur
      await supabase.from('notifications').insert({
        user_id: transaction.buyer_id,
        type: 'PAYMENT_REFUNDED',
        title: 'Paiement remboursé',
        message: `Votre paiement de ${transaction.amount / 100} XOF a été remboursé.`,
        data: {
          transaction_id: transaction.id,
          reason,
        },
      });

      // Enregistrer l'audit
      await supabase.from('admin_audit_logs').insert({
        admin_id: adminId,
        action: 'REJECT_PAYMENT',
        entity_type: 'funds_release_schedule',
        entity_id: releaseId,
        details: {
          transaction_id: transaction.id,
          amount: transaction.seller_net_amount,
          reason,
        },
      });

      return new Response(
        JSON.stringify({
          success: true,
          action: 'rejected',
          release_id: releaseId,
          transaction_id: transaction.id,
          amount: transaction.seller_net_amount,
          message: 'Payment rejected and refund initiated',
        }),
        { headers: { 'Content-Type': 'application/json' } }
      );
    }

  } catch (error) {
    console.error('❌ Error in admin-review-payment:', error);
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : 'Unknown error',
        success: false,
      }),
      {
        headers: { 'Content-Type': 'application/json' },
        status: 500,
      }
    );
  }

  // Fallback response (should never reach here)
  return new Response(
    JSON.stringify({ error: 'Invalid action', success: false }),
    { headers: { 'Content-Type': 'application/json' }, status: 400 }
  );
});
