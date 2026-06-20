/**
 * STRIPE WITHDRAWAL - Retrait bancaire (Flux Manuel Admin)
 * Edge Function — Appelle le RPC atomique request_bank_withdrawal
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[STRIPE-WITHDRAWAL] ${step}${detailsStr}`);
};

import { getPdgFeeRate, FEE_KEYS } from "../_shared/pdg-fees.ts";

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    // Vérifier l'authentification
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: req.headers.get('Authorization')! },
        },
      }
    );

    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) {
      throw new Error("Non autorisé");
    }
    logStep("User authenticated", { userId: user.id });

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Lire le taux dynamique depuis pdg_settings
    const WITHDRAWAL_FEE_RATE = await getPdgFeeRate(supabaseAdmin, FEE_KEYS.WITHDRAWAL);

    // Récupérer les données
    const { amount, currency = 'gnf', bankDetails } = await req.json();

    // Validation des données bancaires
    if (!bankDetails?.account_holder || !bankDetails?.bank_name || !bankDetails?.iban) {
      throw new Error("Informations bancaires incomplètes: titulaire, banque et IBAN requis");
    }

    if (bankDetails.account_holder.trim().length < 3) {
      throw new Error("Nom du titulaire trop court (3 caractères minimum)");
    }

    if (bankDetails.bank_name.trim().length < 2) {
      throw new Error("Nom de la banque trop court");
    }

    if (bankDetails.iban.replace(/\s/g, '').length < 10) {
      throw new Error("IBAN/numéro de compte invalide (10 caractères minimum)");
    }

    if (!amount || amount < 50000) {
      throw new Error(`Montant minimum de retrait: 50 000 ${currency.toUpperCase()}`);
    }

    logStep("Calling atomic RPC", { 
      amount, 
      feeRate: WITHDRAWAL_FEE_RATE,
      bankHolder: bankDetails.account_holder,
      bankName: bankDetails.bank_name,
    });

    // Appeler le RPC atomique
    const { data: result, error: rpcError } = await supabaseAdmin
      .rpc('request_bank_withdrawal', {
        p_user_id: user.id,
        p_amount: amount,
        p_currency: currency.toUpperCase(),
        p_fee_rate: WITHDRAWAL_FEE_RATE,
        p_bank_account_name: bankDetails.account_holder.trim(),
        p_bank_account_number: bankDetails.iban.replace(/\s/g, '').trim(),
        p_bank_details: {
          bank_name: bankDetails.bank_name.trim(),
          iban: bankDetails.iban.replace(/\s/g, '').trim(),
          account_holder: bankDetails.account_holder.trim(),
          requested_at: new Date().toISOString(),
          fee_rate: WITHDRAWAL_FEE_RATE,
        },
      });

    if (rpcError) {
      logStep("RPC Error", { error: rpcError.message });
      throw new Error(rpcError.message || "Erreur lors de la demande de retrait");
    }

    if (!result?.success) {
      throw new Error(result?.error || "Erreur lors de la demande de retrait");
    }

    logStep("Withdrawal request created", { 
      withdrawalId: result.withdrawal_id,
      newBalance: result.new_balance,
      status: result.status,
    });

    return new Response(
      JSON.stringify({
        success: true,
        withdrawalId: result.withdrawal_id,
        amount: result.amount,
        withdrawalFee: result.fee,
        netAmount: result.net_amount,
        newBalance: result.new_balance,
        status: result.status,
        message: 'Votre demande de retrait a été enregistrée et sera examinée par notre équipe. Les fonds sont réservés.',
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Erreur inconnue';
    logStep("ERROR", { message: errorMessage });

    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
