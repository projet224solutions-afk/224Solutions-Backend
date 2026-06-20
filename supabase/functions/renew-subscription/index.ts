/**
 * 🔐 RENOUVELLEMENT ABONNEMENT SÉCURISÉ
 * Avec signature HMAC et audit log
 * 224Solutions - Règles de sécurité financières
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';
import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";

const TRANSACTION_SECRET = Deno.env.get("TRANSACTION_SECRET_KEY");
if (!TRANSACTION_SECRET) throw new Error("CRITICAL: TRANSACTION_SECRET_KEY not configured");

interface RenewalRequest {
  subscription_id: string;
  payment_method: 'wallet' | 'external';
  payment_reference?: string;
  // 🔐 SUPPRIMÉ: amount_gnf - Le montant est TOUJOURS calculé backend
}

// 🔐 Génère signature HMAC
async function generateSignature(transactionId: string, amount: number): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(`${transactionId}${amount}`);
  const keyData = encoder.encode(TRANSACTION_SECRET);
  const key = await crypto.subtle.importKey("raw", keyData, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, data);
  return Array.from(new Uint8Array(signature)).map(b => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  // 🔐 Créer client Supabase
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  );

  try {
    // 🔐 SÉCURITÉ: On accepte subscription_id et payment_method seulement
    // Le montant est TOUJOURS calculé côté backend
    const { subscription_id, payment_method, payment_reference }: Omit<RenewalRequest, 'amount_gnf'> = await req.json();
    const now = new Date().toISOString();

    console.log('Processing subscription renewal:', { subscription_id, payment_method });

    // Get auth user
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      throw new Error('Missing authorization header');
    }

    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);

    if (authError || !user) {
      throw new Error('Unauthorized');
    }

    // Get subscription with plan details
    const { data: subscription, error: subError } = await supabase
      .from('subscriptions')
      .select('*, plans(*)')
      .eq('id', subscription_id)
      .eq('user_id', user.id)
      .single();

    if (subError || !subscription) {
      throw new Error('Subscription not found');
    }

    // 🔐 RÈGLE CRITIQUE: Le montant est TOUJOURS pris du backend (prix du plan)
    // JAMAIS du frontend - protection contre manipulation de prix
    const amount_gnf = subscription.plans.price_gnf;
    console.log(`[Security] Amount calculated from backend: ${amount_gnf} GNF (plan: ${subscription.plans.name})`);
    
    if (!amount_gnf || amount_gnf <= 0) {
      throw new Error('Invalid plan price configuration');
    }

    // Process payment based on method
    if (payment_method === 'wallet') {
      // 🔐 Générer ID de transaction sécurisé et signature
      const transactionId = `SUB-${Date.now()}-${Math.random().toString(36).substr(2, 8).toUpperCase()}`;
      const signature = await generateSignature(transactionId, amount_gnf);

      // Deduct from wallet
      const { data: wallet } = await supabase
        .from('wallets')
        .select('id, balance')
        .eq('user_id', user.id)
        .single();

      if (!wallet || wallet.balance < amount_gnf) {
        throw new Error('Insufficient wallet balance');
      }

      // 🔐 Créer enregistrement sécurisé AVANT modification
      const { error: secureError } = await supabase
        .from('secure_transactions')
        .insert({
          id: transactionId,
          user_id: user.id,
          requested_amount: amount_gnf,
          fee_amount: 0,
          total_amount: amount_gnf,
          net_amount: amount_gnf,
          signature: signature,
          status: 'pending',
          transaction_type: 'subscription_renewal',
          metadata: { subscription_id, plan: subscription.plans.name }
        });

      if (secureError) {
        console.error('[Subscription] Secure transaction failed:', secureError);
        throw new Error('Transaction security error');
      }

      // Create wallet transaction
      await supabase
        .from('wallet_transactions')
        .insert({
          wallet_id: wallet.id,
          amount: -amount_gnf,
          transaction_type: 'subscription_renewal',
          description: `Renouvellement abonnement ${subscription.plans.name}`,
          status: 'completed',
          created_at: now
        });

      // 🔐 Update wallet balance avec verrouillage optimiste
      const newBalance = wallet.balance - amount_gnf;
      const { data: updateResult, error: updateWalletError } = await supabase
        .from('wallets')
        .update({ balance: newBalance, updated_at: now })
        .eq('user_id', user.id)
        .eq('balance', wallet.balance) // 🔐 Verrouillage optimiste
        .select('balance')
        .single();

      if (updateWalletError || !updateResult) {
        // 🔐 Marquer transaction comme échouée
        await supabase.from('secure_transactions').update({ status: 'failed' }).eq('id', transactionId);
        throw new Error('Balance modified during transaction - retry required');
      }

      // 🔐 Marquer transaction comme complétée
      await supabase.from('secure_transactions')
        .update({ status: 'completed', completed_at: now })
        .eq('id', transactionId);

      // 🔐 Log audit
      await supabase.from('financial_audit_logs').insert({
        user_id: user.id,
        action_type: 'subscription_renewed',
        description: `Abonnement renouvelé: ${subscription.plans.name}`,
        request_data: { transactionId, amount_gnf, newBalance, signature: signature.substring(0, 16) + '...' },
        is_suspicious: false
      });
    }

    // Calculate new period end (add plan duration to current date)
    const newPeriodEnd = new Date();
    newPeriodEnd.setDate(newPeriodEnd.getDate() + subscription.plans.duration_days);

    // Update subscription
    const { error: updateError } = await supabase
      .from('subscriptions')
      .update({
        status: 'active',
        current_period_start: now,
        current_period_end: newPeriodEnd.toISOString(),
        updated_at: now
      })
      .eq('id', subscription_id);

    if (updateError) {
      throw updateError;
    }

    // Reactivate vendor
    const { data: vendor } = await supabase
      .from('vendors')
      .select('id')
      .eq('user_id', user.id)
      .single();

    if (vendor) {
      await supabase
        .from('vendors')
        .update({ 
          is_verified: true,
          is_active: true,
          updated_at: now 
        })
        .eq('id', vendor.id);

      // Reactivate virtual cards
      await supabase
        .from('virtual_cards')
        .update({ status: 'active', updated_at: now })
        .eq('user_id', user.id)
        .eq('status', 'suspended');

      // Reactivate products
      await supabase
        .from('products')
        .update({ is_active: true, updated_at: now })
        .eq('vendor_id', vendor.id);
    }

    // Record PDG revenue via RPC `record_pdg_revenue`
    await supabase.rpc('record_pdg_revenue', {
      p_source_type: 'frais_abonnement',
      p_amount: amount_gnf,
      p_percentage: null,
      p_transaction_id: payment_reference || null,
      p_user_id: user.id,
      p_service_id: null,
      p_metadata: { subscription_id }
    });

    // Send success notification
    await supabase
      .from('notifications')
      .insert({
        user_id: user.id,
        title: 'Abonnement renouvelé',
        message: `Votre abonnement ${subscription.plans.name} a été renouvelé avec succès jusqu'au ${new Date(newPeriodEnd).toLocaleDateString('fr-FR')}.`,
        type: 'success',
        created_at: now
      });

    console.log('Subscription renewed successfully:', subscription_id);

    return new Response(
      JSON.stringify({
        success: true,
        subscription_id,
        new_period_end: newPeriodEnd.toISOString(),
        message: 'Abonnement renouvelé avec succès'
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200
      }
    );

  } catch (error) {
    console.error('Renewal error:', error);
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    
    return new Response(
      JSON.stringify({ 
        success: false,
        error: errorMessage 
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400
      }
    );
  }
});
