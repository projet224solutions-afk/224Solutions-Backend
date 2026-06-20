/**
 * PAYPAL WITHDRAWAL - Retrait du wallet vers compte PayPal
 * Utilise PayPal Payouts API pour envoyer l'argent
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[PAYPAL-WITHDRAWAL] ${step}${detailsStr}`);
};

import { getPdgFeeRate, FEE_KEYS } from "../_shared/pdg-fees.ts";

const MIN_WITHDRAWAL = 5; // $5 minimum
const PAYPAL_API_BASE = "https://api-m.paypal.com";

async function getPayPalAccessToken(): Promise<string> {
  const clientId = Deno.env.get("PAYPAL_CLIENT_ID");
  const secret = Deno.env.get("PAYPAL_SECRET_KEY");
  if (!clientId || !secret) throw new Error("PayPal credentials not configured");

  const res = await fetch(`${PAYPAL_API_BASE}/v1/oauth2/token`, {
    method: "POST",
    headers: {
      "Authorization": `Basic ${btoa(`${clientId}:${secret}`)}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`PayPal auth failed [${res.status}]: ${err}`);
  }

  const data = await res.json();
  return data.access_token;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    // 🔐 HMAC signature validation + idempotency + fraud scoring
    const rawBody = await req.text();
    const { validateHmacRequest, hmacErrorResponse, assessFraudRisk } = await import("../_shared/hmac-guard.ts");
    if (req.headers.get("x-signature")) {
      const hmacResult = await validateHmacRequest(req, rawBody, { checkIdempotency: true });
      if (!hmacResult.valid) {
        logStep("HMAC validation failed", { code: hmacResult.code });
        return hmacErrorResponse(hmacResult, corsHeaders);
      }
      logStep("HMAC signature verified ✅");
    }

    // Auth
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: req.headers.get("Authorization")! } } }
    );

    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) throw new Error("Non autorisé");
    logStep("User authenticated", { userId: user.id });

    const parsedBody = JSON.parse(rawBody);
    
    // 🔍 Fraud scoring
    const fraudResult = assessFraudRisk(req, parsedBody, user.id);
    if (fraudResult.action === "block") {
      logStep("🚨 FRAUD BLOCKED", { score: fraudResult.score, flags: fraudResult.flags });
      return new Response(
        JSON.stringify({ success: false, error: "Transaction bloquée pour raisons de sécurité" }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { amount, currency = "USD", paypalEmail } = parsedBody;

    if (!paypalEmail) throw new Error("Email PayPal requis");
    if (!amount || amount < MIN_WITHDRAWAL) {
      throw new Error(`Montant minimum de retrait: ${MIN_WITHDRAWAL} ${currency.toUpperCase()}`);
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // Lire le taux dynamique depuis pdg_settings
    const WITHDRAWAL_FEE_RATE = await getPdgFeeRate(supabaseAdmin, FEE_KEYS.WITHDRAWAL);

    // Check wallet balance
    const { data: wallet, error: walletError } = await supabaseAdmin
      .from("wallets")
      .select("id, balance, currency")
      .eq("user_id", user.id)
      .single();

    if (walletError || !wallet) throw new Error("Wallet non trouvé");
    if (wallet.balance < amount) {
      throw new Error(`Solde insuffisant. Disponible: ${wallet.balance} ${wallet.currency}`);
    }

    // Calculate fees
    const withdrawalFee = Math.round(amount * (WITHDRAWAL_FEE_RATE / 100) * 100) / 100;
    const netAmount = Math.round((amount - withdrawalFee) * 100) / 100;

    logStep("Withdrawal details", { amount, withdrawalFee, netAmount, paypalEmail });

    // PayPal Payout
    const accessToken = await getPayPalAccessToken();
    const batchId = `WD-${Date.now()}-${Math.random().toString(36).substring(2, 8)}`;

    const payoutRes = await fetch(`${PAYPAL_API_BASE}/v1/payments/payouts`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        sender_batch_header: {
          sender_batch_id: batchId,
          email_subject: "Retrait 224Solutions",
          email_message: "Vous avez reçu un paiement de 224Solutions.",
        },
        items: [{
          recipient_type: "EMAIL",
          amount: {
            value: netAmount.toFixed(2),
            currency: currency.toUpperCase(),
          },
          receiver: paypalEmail,
          note: `Retrait wallet 224Solutions - Ref: ${batchId}`,
          sender_item_id: `ITEM-${batchId}`,
        }],
      }),
    });

    if (!payoutRes.ok) {
      const err = await payoutRes.text();
      throw new Error(`PayPal payout failed [${payoutRes.status}]: ${err}`);
    }

    const payoutData = await payoutRes.json();
    logStep("PayPal payout created", {
      batchId: payoutData.batch_header?.payout_batch_id,
      status: payoutData.batch_header?.batch_status,
    });

    // Debit wallet
    const newBalance = wallet.balance - amount;
    await supabaseAdmin.from("wallets").update({
      balance: newBalance,
      updated_at: new Date().toISOString(),
    }).eq("id", wallet.id);

    // Record transaction
    const referenceNumber = `PP-WD-${Date.now()}`;
    await supabaseAdmin.from("wallet_transactions").insert({
      transaction_id: referenceNumber,
      transaction_type: "withdrawal",
      wallet_id: wallet.id,
      amount: -amount,
      net_amount: netAmount,
      fee: withdrawalFee,
      currency: currency.toUpperCase(),
      status: "completed",
      description: `Retrait PayPal vers ${paypalEmail}`,
      sender_wallet_id: wallet.id,
      sender_user_id: user.id,
      metadata: {
        paypal_batch_id: payoutData.batch_header?.payout_batch_id,
        paypal_email: paypalEmail,
        gross_amount: amount,
        fee_rate: WITHDRAWAL_FEE_RATE,
      },
    } as any);

    logStep("Wallet debited", { walletId: wallet.id, newBalance });

    return new Response(JSON.stringify({
      success: true,
      batchId: payoutData.batch_header?.payout_batch_id,
      amount,
      withdrawalFee,
      netAmount,
      newBalance,
      paypalEmail,
      message: `Retrait de ${netAmount.toFixed(2)} ${currency.toUpperCase()} envoyé vers ${paypalEmail}`,
    }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : "Erreur inconnue";
    logStep("ERROR", { message: errorMessage });
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
