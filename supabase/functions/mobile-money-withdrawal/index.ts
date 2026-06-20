/**
 * MOBILE MONEY WITHDRAWAL - Retrait du wallet vers Mobile Money
 * Edge Function pour effectuer un payout Orange Money / MTN MoMo
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[MOBILE-MONEY-WITHDRAWAL] ${step}${detailsStr}`);
};

import { getPdgFeeRate, FEE_KEYS } from "../_shared/pdg-fees.ts";

const MIN_WITHDRAWAL = 5000; // 5,000 GNF minimum

// Generate HMAC-SHA256 signature - Djomy format
async function generateHmacSignature(clientId: string, clientSecret: string): Promise<string> {
  const encoder = new TextEncoder();
  const keyData = encoder.encode(clientSecret);
  const messageData = encoder.encode(clientId);
  
  const key = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  
  const signature = await crypto.subtle.sign("HMAC", key, messageData);
  const hashArray = Array.from(new Uint8Array(signature));
  return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
}

// Get Bearer token from Djomy
async function getAccessToken(clientId: string, clientSecret: string, useSandbox: boolean): Promise<string> {
  const baseUrl = useSandbox 
    ? "https://sandbox-api.djomy.africa" 
    : "https://api.djomy.africa";
  
  const signature = await generateHmacSignature(clientId, clientSecret);
  const xApiKey = `${clientId}:${signature}`;
  
  logStep("Getting access token", { baseUrl });
  
  const response = await fetch(`${baseUrl}/v1/auth`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "User-Agent": "224solutions/1.0 (supabase-edge)",
      "X-API-KEY": xApiKey,
    },
    body: JSON.stringify({}),
  });
  
  if (!response.ok) {
    const responseText = await response.text();
    throw new Error(`Authentication failed: ${response.status} - ${responseText}`);
  }
  
  const data = await response.json();
  return data.accessToken;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  return new Response(
    JSON.stringify({
      success: false,
      error: "Djomy has been fully decommissioned from this system.",
      code: "DJOMY_DECOMMISSIONED",
    }),
    { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 410 }
  );

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

    const body = JSON.parse(rawBody);
    const {
      amount,
      phoneNumber,
      provider, // 'orange' ou 'mtn'
      useSandbox = false,
    } = body;

    // Validation
    if (!amount || amount < MIN_WITHDRAWAL) {
      throw new Error(`Montant minimum de retrait: ${MIN_WITHDRAWAL} GNF`);
    }

    if (!phoneNumber) {
      throw new Error("Numéro de téléphone requis");
    }

    if (!provider || !['orange', 'mtn'].includes(provider)) {
      throw new Error("Fournisseur invalide (orange ou mtn)");
    }

    // Vérifier l'authentification
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? ""
    );

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

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // Lire le taux dynamique depuis pdg_settings
    const WITHDRAWAL_FEE_RATE = await getPdgFeeRate(supabaseAdmin, FEE_KEYS.WITHDRAWAL);

    // Vérifier le solde du wallet
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

    // Calculer les frais
    const withdrawalFee = Math.round(amount * (WITHDRAWAL_FEE_RATE / 100));
    const netAmount = amount - withdrawalFee;

    logStep("Withdrawal details", { 
      amount, 
      withdrawalFee,
      netAmount,
      provider,
      phoneNumber
    });

    // Récupérer les credentials Djomy
    const clientId = Deno.env.get("DJOMY_CLIENT_ID");
    const clientSecret = Deno.env.get("DJOMY_CLIENT_SECRET");

    if (!clientId || !clientSecret) {
      // Si pas de credentials Djomy, créer une demande de retrait manuelle
      logStep("No Djomy credentials, creating manual withdrawal request");
      
      // Débiter le wallet
      const newBalance = wallet.balance - amount;
      await supabaseAdmin
        .from('wallets')
        .update({
          balance: newBalance,
          updated_at: new Date().toISOString(),
        })
        .eq('id', wallet.id);

      // Créer la transaction
      const referenceNumber = `WDR-MM-${Date.now()}`;
      await supabaseAdmin
        .from('wallet_transactions')
        .insert({
          transaction_id: referenceNumber,
          transaction_type: 'withdraw',
          amount: -amount,
          net_amount: -netAmount,
          fee: withdrawalFee,
          currency: 'GNF',
          status: 'pending',
          description: `Retrait ${provider === 'orange' ? 'Orange Money' : 'MTN MoMo'} vers +224${phoneNumber}`,
          sender_wallet_id: wallet.id,
          metadata: {
            method: 'mobile_money',
            provider,
            phone: `224${phoneNumber}`,
            fee_rate: WITHDRAWAL_FEE_RATE,
          }
        });

      return new Response(
        JSON.stringify({
          success: true,
          status: 'pending',
          amount,
          fee: withdrawalFee,
          netAmount,
          newBalance,
          message: 'Demande de retrait enregistrée. Le transfert sera effectué sous 24-48h.',
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Avec credentials Djomy, effectuer le payout
    const cleanClientId = clientId.trim();
    const cleanClientSecret = clientSecret.trim();

    const accessToken = await getAccessToken(cleanClientId, cleanClientSecret, useSandbox);
    const signature = await generateHmacSignature(cleanClientId, cleanClientSecret);
    const xApiKey = `${cleanClientId}:${signature}`;

    const baseUrl = useSandbox 
      ? "https://sandbox-api.djomy.africa" 
      : "https://api.djomy.africa";

    // Mapper le provider vers le code Djomy
    const paymentMethod = provider === 'orange' ? 'OM' : 'MOMO';
    const referenceNumber = `WDR-MM-${Date.now()}`;

    const payoutPayload = {
      paymentMethod,
      recipientIdentifier: `224${phoneNumber.replace(/\s/g, "")}`,
      amount: netAmount, // Montant net après frais
      countryCode: "GN",
      description: `Retrait wallet 224solutions`,
      merchantPaymentReference: referenceNumber,
    };

    logStep("Payout payload", payoutPayload);

    const response = await fetch(`${baseUrl}/v1/payouts`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "224solutions/1.0 (supabase-edge)",
        "Authorization": `Bearer ${accessToken}`,
        "X-API-KEY": xApiKey,
      },
      body: JSON.stringify(payoutPayload),
    });

    const responseText = await response.text();
    logStep("Payout response", { status: response.status, body: responseText });

    let payoutResult;
    let payoutStatus = 'pending';
    
    if (response.ok) {
      payoutResult = JSON.parse(responseText);
      payoutStatus = payoutResult.status === 'SUCCESS' ? 'completed' : 'pending';
    } else {
      // En cas d'échec de l'API, on crée quand même une demande manuelle
      logStep("Payout API failed, creating manual request");
      payoutStatus = 'pending';
    }

    // Débiter le wallet
    const newBalance = wallet.balance - amount;
    await supabaseAdmin
      .from('wallets')
      .update({
        balance: newBalance,
        updated_at: new Date().toISOString(),
      })
      .eq('id', wallet.id);

    // Créer la transaction
    await supabaseAdmin
      .from('wallet_transactions')
      .insert({
        transaction_id: referenceNumber,
        transaction_type: 'withdraw',
        amount: -amount,
        net_amount: -netAmount,
        fee: withdrawalFee,
        currency: 'GNF',
        status: payoutStatus,
        description: `Retrait ${provider === 'orange' ? 'Orange Money' : 'MTN MoMo'} vers +224${phoneNumber}`,
        sender_wallet_id: wallet.id,
        metadata: {
          method: 'mobile_money',
          provider,
          phone: `224${phoneNumber}`,
          fee_rate: WITHDRAWAL_FEE_RATE,
          djomy_response: payoutResult || null,
        }
      });

    return new Response(
      JSON.stringify({
        success: true,
        status: payoutStatus,
        transactionId: referenceNumber,
        amount,
        fee: withdrawalFee,
        netAmount,
        newBalance,
        message: payoutStatus === 'completed' 
          ? 'Retrait effectué avec succès!' 
          : 'Demande de retrait enregistrée. Le transfert sera effectué sous 24-48h.',
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("ERROR", { message: errorMessage });

    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { 
        status: 200, 
        headers: { ...corsHeaders, "Content-Type": "application/json" } 
      }
    );
  }
});
