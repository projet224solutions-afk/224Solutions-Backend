/**
 * 🔐 SECURE PAYMENT VALIDATION - SERVER-TO-SERVER ONLY
 * Validation stricte: signature + montant exact + statut SUCCESS
 * Aucun crédit sans validation complète
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-signature",
};

const TRANSACTION_SECRET = Deno.env.get("TRANSACTION_SECRET_KEY");
if (!TRANSACTION_SECRET) throw new Error("CRITICAL: TRANSACTION_SECRET_KEY not configured");

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[SECURE-VALIDATE] ${step}${detailsStr}`);
};

// 🔐 Generate expected HMAC-SHA256 signature
async function generateExpectedSignature(transactionId: string, totalAmount: number): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(`${transactionId}${totalAmount}`);
  const keyData = encoder.encode(TRANSACTION_SECRET);
  
  const key = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  
  const signature = await crypto.subtle.sign("HMAC", key, data);
  const hashArray = Array.from(new Uint8Array(signature));
  return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    { auth: { persistSession: false } }
  );

  try {
    logStep("Secure payment validation started");

    const body = await req.json();
    const {
      transaction_id,
      external_transaction_id,
      amount_paid,
      payment_status,
      signature
    } = body;

    logStep("Validation request received", {
      transaction_id,
      external_transaction_id,
      amount_paid,
      payment_status,
      hasSignature: !!signature
    });

    // 🔐 Retrieve the transaction
    const { data: transaction, error: fetchError } = await supabaseAdmin
      .from("secure_transactions")
      .select("*")
      .eq("id", transaction_id)
      .single();

    if (fetchError || !transaction) {
      logStep("ERROR: Transaction not found", { transaction_id });
      
      await supabaseAdmin.from("financial_audit_logs").insert({
        user_id: "00000000-0000-0000-0000-000000000000",
        action_type: "attempt",
        description: "Tentative validation avec ID transaction invalide",
        request_data: { transaction_id },
        is_suspicious: true,
        security_flags: ["invalid_transaction_id"]
      });

      return new Response(
        JSON.stringify({ success: false, error: "TRANSACTION_NOT_FOUND" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 404 }
      );
    }

    const userId = transaction.user_id;

    // 🔐 RULE 0: Check transaction is pending
    if (transaction.status !== "pending") {
      logStep("ERROR: Transaction not pending", { status: transaction.status });
      
      await supabaseAdmin.from("financial_audit_logs").insert({
        transaction_id,
        user_id: userId,
        action_type: "attempt",
        description: `Tentative validation transaction non-pending (status: ${transaction.status})`,
        old_status: transaction.status,
        is_suspicious: true,
        security_flags: ["invalid_status"]
      });

      return new Response(
        JSON.stringify({ 
          success: false, 
          error: "INVALID_TRANSACTION_STATUS", 
          current_status: transaction.status 
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 400 }
      );
    }

    // 🔐 RULE 1: Verify API signature
    const expectedSignature = await generateExpectedSignature(transaction_id, transaction.total_amount);
    
    if (!signature || signature !== expectedSignature) {
      logStep("SECURITY ALERT: Invalid signature", { 
        expected: expectedSignature.substring(0, 20) + "...",
        received: signature?.substring(0, 20) + "..." 
      });

      // Create security alert
      await supabaseAdmin.from("financial_security_alerts").insert({
        transaction_id,
        user_id: userId,
        alert_type: "signature_invalid",
        severity: "critical",
        title: "Signature API invalide",
        description: "Tentative de validation avec signature incorrecte",
        expected_value: expectedSignature,
        received_value: signature || "NULL"
      });

      // Flag user
      await supabaseAdmin
        .from("user_security_flags")
        .upsert({
          user_id: userId,
          suspicious_activity_count: 1,
          is_flagged: true,
          flag_reason: "Signature API invalide",
          flagged_at: new Date().toISOString(),
          updated_at: new Date().toISOString()
        }, { onConflict: "user_id" });

      // Update transaction
      await supabaseAdmin
        .from("secure_transactions")
        .update({ 
          status: "rejected", 
          rejection_reason: "INVALID_SIGNATURE",
          failed_at: new Date().toISOString()
        })
        .eq("id", transaction_id);

      // Audit log
      await supabaseAdmin.from("financial_audit_logs").insert({
        transaction_id,
        user_id: userId,
        action_type: "reject",
        description: "SIGNATURE INVALIDE - Paiement REFUSÉ",
        old_status: "pending",
        new_status: "rejected",
        is_suspicious: true,
        security_flags: ["invalid_signature"]
      });

      return new Response(
        JSON.stringify({ 
          success: false, 
          error: "INVALID_SIGNATURE", 
          message: "Paiement REFUSÉ - Signature invalide" 
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 403 }
      );
    }

    logStep("Signature verified successfully");

    // 🔐 RULE 2: Verify payment status
    if (payment_status !== "SUCCESS" && payment_status !== "completed") {
      logStep("Payment failed", { status: payment_status });

      // Increment failed count
      const { data: flags } = await supabaseAdmin
        .from("user_security_flags")
        .select("failed_payment_count")
        .eq("user_id", userId)
        .single();

      await supabaseAdmin
        .from("user_security_flags")
        .upsert({
          user_id: userId,
          failed_payment_count: (flags?.failed_payment_count || 0) + 1,
          updated_at: new Date().toISOString()
        }, { onConflict: "user_id" });

      // Update transaction
      await supabaseAdmin
        .from("secure_transactions")
        .update({ 
          status: "failed", 
          rejection_reason: `PAYMENT_${payment_status?.toUpperCase() || "FAILED"}`,
          external_transaction_id,
          failed_at: new Date().toISOString()
        })
        .eq("id", transaction_id);

      // Audit log
      await supabaseAdmin.from("financial_audit_logs").insert({
        transaction_id,
        user_id: userId,
        action_type: "reject",
        description: `Paiement échoué: ${payment_status}`,
        old_status: "pending",
        new_status: "failed"
      });

      return new Response(
        JSON.stringify({ 
          success: false, 
          error: "PAYMENT_FAILED", 
          status: payment_status 
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 400 }
      );
    }

    // 🔐 RULE 3: Verify exact amount
    const amountDifference = Math.abs(amount_paid - transaction.total_amount);
    if (!amount_paid || amountDifference > 0.01) {
      logStep("SECURITY ALERT: Amount mismatch", { 
        expected: transaction.total_amount, 
        received: amount_paid 
      });

      // Create security alert
      await supabaseAdmin.from("financial_security_alerts").insert({
        transaction_id,
        user_id: userId,
        alert_type: "amount_mismatch",
        severity: "critical",
        title: "Montant payé différent",
        description: "Le montant payé ne correspond pas au montant attendu",
        expected_value: transaction.total_amount.toString(),
        received_value: amount_paid?.toString() || "NULL"
      });

      // Update transaction
      await supabaseAdmin
        .from("secure_transactions")
        .update({ 
          status: "rejected", 
          rejection_reason: "AMOUNT_MISMATCH",
          amount_paid,
          failed_at: new Date().toISOString()
        })
        .eq("id", transaction_id);

      // Audit log
      await supabaseAdmin.from("financial_audit_logs").insert({
        transaction_id,
        user_id: userId,
        action_type: "reject",
        description: `MONTANT DIFFÉRENT - Attendu: ${transaction.total_amount}, Reçu: ${amount_paid}`,
        is_suspicious: true,
        security_flags: ["amount_mismatch"],
        request_data: { expected: transaction.total_amount, received: amount_paid }
      });

      return new Response(
        JSON.stringify({ 
          success: false, 
          error: "AMOUNT_MISMATCH",
          expected: transaction.total_amount,
          received: amount_paid
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 400 }
      );
    }

    logStep("Amount verified successfully");

    // 🔐 ALL VALIDATIONS PASSED - Credit the account

    // Get or create wallet
    let walletId: string;
    let currentBalance: number;

    const { data: wallet, error: walletError } = await supabaseAdmin
      .from("wallets")
      .select("id, balance")
      .eq("user_id", userId)
      .single();

    if (walletError || !wallet) {
      // Create wallet
      const { data: newWallet, error: createError } = await supabaseAdmin
        .from("wallets")
        .insert({ user_id: userId, balance: 0, currency: "GNF" })
        .select("id, balance")
        .single();

      if (createError || !newWallet) {
        logStep("ERROR: Failed to create wallet", { error: createError?.message });
        return new Response(
          JSON.stringify({ success: false, error: "WALLET_CREATION_FAILED" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 500 }
        );
      }

      walletId = newWallet.id;
      currentBalance = newWallet.balance;
    } else {
      walletId = wallet.id;
      currentBalance = wallet.balance;
    }

    // Calculate new balance (credit NET amount only, not total!)
    const newBalance = currentBalance + transaction.net_amount;

    // Update wallet
    const { error: updateError } = await supabaseAdmin
      .from("wallets")
      .update({ balance: newBalance, updated_at: new Date().toISOString() })
      .eq("id", walletId);

    if (updateError) {
      logStep("ERROR: Failed to update wallet", { error: updateError.message });
      return new Response(
        JSON.stringify({ success: false, error: "WALLET_UPDATE_FAILED" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 500 }
      );
    }

    // Mark transaction as completed
    await supabaseAdmin
      .from("secure_transactions")
      .update({
        status: "completed",
        signature_verified: true,
        external_transaction_id,
        amount_paid,
        validated_at: new Date().toISOString(),
        completed_at: new Date().toISOString()
      })
      .eq("id", transaction_id);

    // Create wallet transaction record
    await supabaseAdmin.from("wallet_transactions").insert({
      wallet_id: walletId,
      user_id: userId,
      type: "deposit",
      amount: transaction.net_amount,
      description: `Recharge sécurisée via ${transaction.payment_method || "Jomy"}`,
      status: "completed",
      reference: external_transaction_id,
      metadata: {
        secure_transaction_id: transaction_id,
        fee_amount: transaction.fee_amount,
        total_paid: transaction.total_amount,
        signature_verified: true
      }
    });

    // Audit log - success
    await supabaseAdmin.from("financial_audit_logs").insert({
      transaction_id,
      user_id: userId,
      action_type: "complete",
      description: `Paiement validé et crédité - Net: ${transaction.net_amount} GNF`,
      old_status: "pending",
      new_status: "completed",
      request_data: {
        old_balance: currentBalance,
        new_balance: newBalance,
        net_credited: transaction.net_amount,
        fee_collected: transaction.fee_amount
      }
    });

    logStep("Payment validated and credited successfully", {
      transaction_id,
      net_credited: transaction.net_amount,
      new_balance: newBalance
    });

    return new Response(
      JSON.stringify({
        success: true,
        transaction_id,
        status: "completed",
        net_credited: transaction.net_amount,
        new_balance: newBalance,
        message: "Paiement validé avec succès"
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("CRITICAL ERROR", { message: errorMessage });
    
    return new Response(
      JSON.stringify({ success: false, error: "INTERNAL_ERROR" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 500 }
    );
  }
});
