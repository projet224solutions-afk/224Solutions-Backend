/**
 * 💸 CHAPCHAPPAY PUSH - Envoi Mobile Money
 * Edge Function pour envoyer de l'argent vers Orange Money / MTN MoMo
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import { createChapChapPayClient } from "../_shared/chapchappay-client.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const timestamp = new Date().toISOString();
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[${timestamp}] [CCP-PUSH] ${step}${detailsStr}`);
};

import { getPdgFeeRate, FEE_KEYS } from "../_shared/pdg-fees.ts";

const MIN_WITHDRAWAL = 5000; // 5,000 GNF minimum

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const startTime = Date.now();
  
  try {
    logStep("PUSH payment started");

    const body = await req.json();
    const {
      amount,
      currency = "GNF",
      paymentMethod, // orange_money, mtn_momo
      recipientPhone,
      recipientName,
      description,
      orderId,
      useSandbox = false,
    } = body;

    logStep("Request received", { amount, paymentMethod, useSandbox });

    // Validation
    if (!amount || amount < MIN_WITHDRAWAL) {
      throw new Error(`Montant minimum: ${MIN_WITHDRAWAL} GNF`);
    }
    if (!recipientPhone || recipientPhone.length < 8) {
      throw new Error("Numéro de téléphone invalide - minimum 8 chiffres");
    }
    if (!paymentMethod || !["orange_money", "mtn_momo"].includes(paymentMethod)) {
      throw new Error("Méthode de paiement invalide. Utilisez: orange_money ou mtn_momo");
    }

    // Initialize Supabase clients
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? ""
    );

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false } }
    );

    // Verify authentication
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      throw new Error("Non autorisé");
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: userData, error: userError } = await supabaseClient.auth.getUser(token);
    
    if (userError || !userData.user) {
      throw new Error("Non autorisé");
    }
    
    const userId = userData.user.id;
    logStep("User authenticated", { userId });

    // Check wallet balance
    const { data: wallet, error: walletError } = await supabaseAdmin
      .from('wallets')
      .select('id, balance, currency')
      .eq('user_id', userId)
      .single();

    if (walletError || !wallet) {
      throw new Error("Wallet non trouvé");
    }

    if (wallet.balance < amount) {
      throw new Error(`Solde insuffisant. Disponible: ${wallet.balance} GNF`);
    }

    // Lire le taux dynamique depuis pdg_settings
    const WITHDRAWAL_FEE_RATE = await getPdgFeeRate(supabaseAdmin, FEE_KEYS.WITHDRAWAL);

    // Calculate fees
    const withdrawalFee = Math.round(amount * (WITHDRAWAL_FEE_RATE / 100));
    const netAmount = amount - withdrawalFee;

    logStep("Withdrawal details", { 
      amount, 
      withdrawalFee,
      netAmount,
      paymentMethod,
      recipientPhone
    });

    // Generate unique order ID
    const finalOrderId = orderId || `CCP-PUSH-${Date.now()}-${Math.random().toString(36).substring(2, 8).toUpperCase()}`;

    // Debit wallet first
    const newBalance = wallet.balance - amount;
    await supabaseAdmin
      .from('wallets')
      .update({
        balance: newBalance,
        updated_at: new Date().toISOString(),
      })
      .eq('id', wallet.id);

    logStep("Wallet debited", { oldBalance: wallet.balance, newBalance });

    // Initialize ChapChapPay client
    const ccpClient = createChapChapPayClient(useSandbox);

    // Call ChapChapPay PUSH API
    const ccpResult = await ccpClient.initiatePushPayment({
      amount: netAmount,
      currency,
      paymentMethod: paymentMethod as 'orange_money' | 'mtn_momo',
      recipientPhone,
      recipientName,
      description: description || `Retrait wallet 224Solutions`,
      orderId: finalOrderId,
    });

    logStep("ChapChapPay response", { 
      success: ccpResult.success, 
      transactionId: ccpResult.transactionId 
    });

    // Determine status
    const payoutStatus = ccpResult.success ? 'pending' : 'failed';

    // If failed, refund the wallet
    if (!ccpResult.success) {
      await supabaseAdmin
        .from('wallets')
        .update({
          balance: wallet.balance, // Restore original balance
          updated_at: new Date().toISOString(),
        })
        .eq('id', wallet.id);
      
      logStep("Wallet refunded due to ChapChapPay failure");
    }

    // Create wallet transaction record
    await supabaseAdmin
      .from('wallet_transactions')
      .insert({
        transaction_id: finalOrderId,
        transaction_type: 'withdraw',
        amount: -amount,
        net_amount: -netAmount,
        fee: withdrawalFee,
        currency: 'GNF',
        status: payoutStatus,
        description: `Retrait ${paymentMethod === 'orange_money' ? 'Orange Money' : 'MTN MoMo'} vers +224${recipientPhone}`,
        sender_wallet_id: wallet.id,
        metadata: {
          method: 'mobile_money',
          provider: 'chapchappay',
          payment_method: paymentMethod,
          phone: `224${recipientPhone.replace(/\s/g, "")}`,
          fee_rate: WITHDRAWAL_FEE_RATE,
          ccp_transaction_id: ccpResult.transactionId,
          ccp_response: ccpResult.data || null,
        }
      });

    if (!ccpResult.success) {
      throw new Error(ccpResult.error || "Échec du transfert ChapChapPay");
    }

    const totalDuration = Date.now() - startTime;
    logStep("✅ PUSH payment completed", { 
      transactionId: finalOrderId,
      ccpId: ccpResult.transactionId,
      totalDuration 
    });

    return new Response(
      JSON.stringify({
        success: true,
        status: payoutStatus,
        transactionId: finalOrderId,
        ccpTransactionId: ccpResult.transactionId,
        amount,
        fee: withdrawalFee,
        netAmount,
        newBalance,
        message: "Transfert initié avec succès",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("❌ ERROR", { message: errorMessage });

    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { 
        status: 200, 
        headers: { ...corsHeaders, "Content-Type": "application/json" } 
      }
    );
  }
});
