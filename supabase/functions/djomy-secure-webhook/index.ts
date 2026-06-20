import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-webhook-signature",
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const timestamp = new Date().toISOString();
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[${timestamp}] [DJOMY-WEBHOOK-SECURE] ${step}${detailsStr}`);
};

// Verify HMAC signature from Djomy webhook
async function verifyWebhookSignature(payload: string, signature: string, secret: string): Promise<boolean> {
  try {
    const signatureParts = signature.split(":");
    if (signatureParts.length !== 2 || signatureParts[0] !== "v1") {
      logStep("Invalid signature format", { signatureParts });
      return false;
    }
    
    const providedSignature = signatureParts[1];
    
    const encoder = new TextEncoder();
    const keyData = encoder.encode(secret);
    const messageData = encoder.encode(payload);
    
    const key = await crypto.subtle.importKey(
      "raw",
      keyData,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );
    
    const signatureBuffer = await crypto.subtle.sign("HMAC", key, messageData);
    const hashArray = Array.from(new Uint8Array(signatureBuffer));
    const computedSignature = hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
    
    const isValid = computedSignature === providedSignature;
    logStep("Signature verification", { isValid, providedLength: providedSignature.length });
    
    return isValid;
  } catch (error) {
    logStep("Signature verification error", { error: String(error) });
    return false;
  }
}

interface TrustScoreResult {
  totalScore: number;
  breakdown: Record<string, { score: number; maxScore: number; details: string }>;
  decision: 'AUTO_RELEASE' | 'BLOCKED' | 'MANUAL_REVIEW';
  autoReleased: boolean;
}

// ============= DJOMY TOKEN MANAGER =============
interface DjomyTokenData {
  accessToken: string;
  expiresAt: number;
}

const tokenCache: Record<string, DjomyTokenData> = {};

// Génère un nouveau token via l'endpoint officiel Djomy OAuth2
async function generateDjomyToken(clientId: string, clientSecret: string, useSandbox: boolean): Promise<DjomyTokenData> {
  const baseUrl = useSandbox 
    ? "https://sandbox-api.djomy.africa" 
    : "https://api.djomy.africa";
  
  logStep("🔐 Generating new Djomy token for verification", { baseUrl });
  
  const response = await fetch(`${baseUrl}/v1/auth/token`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
    },
    body: JSON.stringify({
      client_id: clientId,
      client_secret: clientSecret,
      grant_type: "client_credentials"
    }),
  });
  
  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Djomy token generation failed: ${response.status} - ${errorText}`);
  }
  
  const data = await response.json();
  const expiresIn = data.expires_in || 3600;
  
  return {
    accessToken: data.access_token || data.accessToken,
    expiresAt: Date.now() + (expiresIn - 300) * 1000
  };
}

// Récupère un token valide
async function getDjomyAccessToken(clientId: string, clientSecret: string, useSandbox: boolean): Promise<string> {
  const cacheKey = `webhook_${useSandbox ? 'sandbox' : 'prod'}_${clientId}`;
  const cachedToken = tokenCache[cacheKey];
  
  if (cachedToken && cachedToken.expiresAt > Date.now()) {
    return cachedToken.accessToken;
  }
  
  const newToken = await generateDjomyToken(clientId, clientSecret, useSandbox);
  tokenCache[cacheKey] = newToken;
  return newToken.accessToken;
}

// Secondary verification with Djomy API (utilise token OAuth2)
async function verifyTransactionWithDjomy(
  transactionId: string,
  clientId: string,
  clientSecret: string,
  useSandbox: boolean
): Promise<{ verified: boolean; status: string; data: unknown }> {
  try {
    logStep("🔍 Secondary verification with Djomy API", { transactionId });
    
    const baseUrl = useSandbox 
      ? "https://sandbox-api.djomy.africa" 
      : "https://api.djomy.africa";
    
    // Get access token (avec cache)
    const accessToken = await getDjomyAccessToken(clientId, clientSecret, useSandbox);
    
    // Verify transaction
    const verifyResponse = await fetch(`${baseUrl}/v1/payments/${transactionId}`, {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Accept": "application/json",
      },
    });
    
    const verifyData = await verifyResponse.json();
    
    logStep("Verification response", { 
      status: verifyResponse.status, 
      transactionStatus: verifyData.status 
    });
    
    return {
      verified: verifyResponse.ok && verifyData.status === "SUCCESS",
      status: verifyData.status || "UNKNOWN",
      data: verifyData
    };
  } catch (error) {
    logStep("Secondary verification failed", { error: String(error) });
    return { verified: false, status: "ERROR", data: { error: String(error) } };
  }
}

// Calculate trust score for auto-release decision
// deno-lint-ignore no-explicit-any
async function calculateTrustScore(
  supabase: any,
  transaction: Record<string, unknown>,
  djomyVerificationResult: { verified: boolean; status: string; data: unknown }
): Promise<TrustScoreResult> {
  logStep("Calculating trust score", { 
    transactionId: transaction.id, 
    vendorId: transaction.vendor_id,
    amount: transaction.amount 
  });

  // Get config values
  const { data: configs } = await supabase
    .from("trust_score_config")
    .select("config_key, config_value");
  
  const config: Record<string, number> = {};
  if (configs) {
    for (const c of configs as { config_key: string; config_value: number }[]) {
      config[c.config_key] = Number(c.config_value);
    }
  }

  const threshold = config.auto_release_threshold || 70;
  const maxAutoAmount = config.max_auto_release_amount || 5000000;
  const weights = {
    djomy: config.weight_djomy_confirmed || 25,
    userAge: config.weight_user_age || 15,
    phoneHistory: config.weight_phone_history || 15,
    vendorKyc: config.weight_vendor_kyc || 20,
    transactionAmount: config.weight_transaction_amount || 15,
    noDisputes: config.weight_no_disputes || 10
  };

  const breakdown: Record<string, { score: number; maxScore: number; details: string }> = {};
  let totalScore = 0;
  const amount = Number(transaction.amount) || 0;

  // 1. Djomy API confirmation (25 points)
  const djomyConfirmed = djomyVerificationResult.verified && djomyVerificationResult.status === "SUCCESS";
  breakdown.djomy_confirmed = {
    score: djomyConfirmed ? weights.djomy : 0,
    maxScore: weights.djomy,
    details: djomyConfirmed ? "Transaction confirmée par API Djomy" : "Transaction non confirmée par API"
  };
  totalScore += breakdown.djomy_confirmed.score;

  // 2. User age (15 points)
  if (transaction.user_id) {
    const { data: profileData } = await supabase
      .from("profiles")
      .select("created_at")
      .eq("id", transaction.user_id)
      .single();
    
    const profile = profileData as { created_at: string } | null;
    if (profile) {
      const accountAgeDays = Math.floor(
        (Date.now() - new Date(profile.created_at).getTime()) / (1000 * 60 * 60 * 24)
      );
      
      let userAgeScore = 0;
      if (accountAgeDays > 365) userAgeScore = weights.userAge;
      else if (accountAgeDays > 180) userAgeScore = weights.userAge * 0.8;
      else if (accountAgeDays > 90) userAgeScore = weights.userAge * 0.6;
      else if (accountAgeDays > 30) userAgeScore = weights.userAge * 0.4;
      else if (accountAgeDays > 7) userAgeScore = weights.userAge * 0.2;
      
      breakdown.user_age = {
        score: Math.round(userAgeScore),
        maxScore: weights.userAge,
        details: `Compte créé il y a ${accountAgeDays} jours`
      };
    } else {
      breakdown.user_age = { score: 0, maxScore: weights.userAge, details: "Profil introuvable" };
    }
  } else {
    breakdown.user_age = { score: 0, maxScore: weights.userAge, details: "Utilisateur non identifié" };
  }
  totalScore += breakdown.user_age.score;

  // 3. Phone history (15 points)
  const payerPhone = String(transaction.payer_phone || "");
  const { data: phoneDataRaw } = await supabase
    .from("phone_history")
    .select("*")
    .eq("phone_number", payerPhone)
    .single();
  
  const phoneData = phoneDataRaw as {
    is_blacklisted: boolean;
    fraud_reports: number;
    usage_count: number;
    success_count: number;
  } | null;
  
  if (phoneData) {
    if (phoneData.is_blacklisted) {
      breakdown.phone_history = {
        score: 0,
        maxScore: weights.phoneHistory,
        details: "Téléphone blacklisté"
      };
    } else if (phoneData.fraud_reports > 0) {
      breakdown.phone_history = {
        score: 0,
        maxScore: weights.phoneHistory,
        details: `${phoneData.fraud_reports} signalement(s) de fraude`
      };
    } else {
      const successRate = phoneData.usage_count > 0 
        ? phoneData.success_count / phoneData.usage_count 
        : 0;
      const historyScore = Math.round(
        weights.phoneHistory * Math.min(successRate, 1) * (phoneData.usage_count >= 3 ? 1 : 0.5)
      );
      breakdown.phone_history = {
        score: historyScore,
        maxScore: weights.phoneHistory,
        details: `${phoneData.usage_count} transactions, ${Math.round(successRate * 100)}% réussite`
      };
    }
  } else {
    breakdown.phone_history = {
      score: Math.round(weights.phoneHistory * 0.3),
      maxScore: weights.phoneHistory,
      details: "Nouveau numéro de téléphone"
    };
  }
  totalScore += breakdown.phone_history.score;

  // 4. Vendor KYC status (20 points)
  let disputeCount = 0;
  if (transaction.vendor_id) {
    const { data: vendorDataRaw } = await supabase
      .from("vendors")
      .select("kyc_status, is_verified, dispute_count")
      .eq("id", transaction.vendor_id)
      .single();
    
    const vendor = vendorDataRaw as { 
      kyc_status: string | null; 
      is_verified: boolean; 
      dispute_count: number | null 
    } | null;
    
    if (vendor) {
      let kycScore = 0;
      if (vendor.kyc_status === "verified" || vendor.is_verified) {
        kycScore = weights.vendorKyc;
      } else if (vendor.kyc_status === "pending") {
        kycScore = weights.vendorKyc * 0.3;
      }
      breakdown.vendor_kyc = {
        score: Math.round(kycScore),
        maxScore: weights.vendorKyc,
        details: `KYC: ${vendor.kyc_status || "pending"}, Vérifié: ${vendor.is_verified}`
      };
      disputeCount = vendor.dispute_count || 0;
    } else {
      breakdown.vendor_kyc = { score: 0, maxScore: weights.vendorKyc, details: "Vendeur introuvable" };
    }
  } else {
    breakdown.vendor_kyc = { 
      score: Math.round(weights.vendorKyc * 0.5), 
      maxScore: weights.vendorKyc, 
      details: "Pas de vendeur (paiement direct)" 
    };
  }
  totalScore += breakdown.vendor_kyc.score;

  // 5. Transaction amount (15 points)
  let amountScore = weights.transactionAmount;
  if (amount > maxAutoAmount) {
    amountScore = 0;
  } else if (amount > maxAutoAmount * 0.5) {
    amountScore = weights.transactionAmount * 0.5;
  } else if (amount > maxAutoAmount * 0.2) {
    amountScore = weights.transactionAmount * 0.8;
  }
  breakdown.transaction_amount = {
    score: Math.round(amountScore),
    maxScore: weights.transactionAmount,
    details: `Montant: ${amount.toLocaleString()} GNF (max auto: ${maxAutoAmount.toLocaleString()} GNF)`
  };
  totalScore += breakdown.transaction_amount.score;

  // 6. No disputes (10 points)
  const disputeScore = disputeCount === 0 
    ? weights.noDisputes 
    : Math.max(0, weights.noDisputes - disputeCount * 2);
  breakdown.no_disputes = {
    score: Math.round(disputeScore),
    maxScore: weights.noDisputes,
    details: `${disputeCount} litige(s) enregistré(s)`
  };
  totalScore += breakdown.no_disputes.score;

  // Determine decision
  let decision: 'AUTO_RELEASE' | 'BLOCKED' | 'MANUAL_REVIEW';
  let autoReleased = false;

  if (totalScore >= threshold && amount <= maxAutoAmount && djomyConfirmed) {
    decision = 'AUTO_RELEASE';
    autoReleased = true;
  } else if (totalScore < threshold * 0.5) {
    decision = 'BLOCKED';
  } else {
    decision = 'MANUAL_REVIEW';
  }

  logStep("Trust score calculated", { totalScore, threshold, decision, autoReleased });

  return { totalScore, breakdown, decision, autoReleased };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const startTime = Date.now();
  
  try {
    logStep("Webhook received", {
      method: req.method,
      url: req.url,
      contentType: req.headers.get("content-type"),
    });

    const clientSecret = Deno.env.get("DJOMY_CLIENT_SECRET")?.trim();
    const clientId = Deno.env.get("DJOMY_CLIENT_ID")?.trim();
    
    const webhookSignature = req.headers.get("X-Webhook-Signature");
    const sourceIp = req.headers.get("x-forwarded-for") || req.headers.get("cf-connecting-ip");
    
    logStep("Webhook headers", { hasSignature: !!webhookSignature, sourceIp });

    const rawBody = await req.text();
    logStep("Webhook body received", { bodyLength: rawBody.length });

    // Verify signature if provided
    let signatureValid = false;
    if (webhookSignature && clientSecret) {
      signatureValid = await verifyWebhookSignature(rawBody, webhookSignature, clientSecret);
      if (!signatureValid) {
        logStep("SECURITY: Invalid webhook signature - rejecting");
        
        const supabaseAdmin = createClient(
          Deno.env.get("SUPABASE_URL") ?? "",
          Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
          { auth: { persistSession: false } }
        );
        
        await supabaseAdmin
          .from("djomy_webhook_logs")
          .insert({
            event_type: "SIGNATURE_INVALID",
            payload: { raw: rawBody.substring(0, 500) },
            signature_valid: false,
            ip_address: sourceIp,
            error_message: "Invalid webhook signature",
          });

        return new Response(
          JSON.stringify({ error: "Invalid signature" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 }
        );
      }
    }

    const payload = JSON.parse(rawBody);
    logStep("Webhook payload parsed", {
      eventType: payload.eventType,
      eventId: payload.eventId,
      transactionId: payload.data?.transactionId,
      status: payload.data?.status,
    });

    const { eventType, eventId, data } = payload;

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false } }
    );

    // Check for duplicate webhook
    if (eventId) {
      const { data: existingLog } = await supabaseAdmin
        .from("djomy_webhook_logs")
        .select("id, processed")
        .eq("event_id", eventId)
        .single();

      if (existingLog?.processed) {
        logStep("Duplicate webhook - already processed", { eventId });
        return new Response(
          JSON.stringify({ success: true, message: "Already processed" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
        );
      }
    }

    // Log webhook event
    const { data: webhookLog } = await supabaseAdmin
      .from("djomy_webhook_logs")
      .insert({
        event_id: eventId,
        event_type: eventType,
        transaction_id: data?.transactionId,
        payload: payload,
        signature_valid: signatureValid,
        ip_address: sourceIp,
        processed: false,
      })
      .select()
      .single();

    // Map Djomy event types to our status
    const statusMap: Record<string, string> = {
      "payment.created": "PROCESSING",
      "payment.redirected": "PROCESSING",
      "payment.pending": "PROCESSING",
      "payment.success": "SUCCESS",
      "payment.failed": "FAILED",
      "payment.cancelled": "CANCELLED",
    };

    const internalStatus = statusMap[eventType] || "PROCESSING";
    logStep("Status mapping", { eventType, internalStatus });

    // Find and update transaction
    if (data?.transactionId) {
      let tx = null;
      
      const { data: transaction } = await supabaseAdmin
        .from("djomy_transactions")
        .select("*")
        .eq("djomy_transaction_id", data.transactionId)
        .single();

      if (!transaction) {
        const { data: txByOrder } = await supabaseAdmin
          .from("djomy_transactions")
          .select("*")
          .eq("order_id", data.merchantPaymentReference)
          .single();
        tx = txByOrder;
      } else {
        tx = transaction;
      }

      if (!tx) {
        logStep("Transaction not found", { 
          djomyId: data.transactionId,
          orderRef: data.merchantPaymentReference 
        });
        
        await supabaseAdmin
          .from("djomy_webhook_logs")
          .update({ processed: true, processed_at: new Date().toISOString(), error_message: "Transaction not found" })
          .eq("id", webhookLog?.id);

        return new Response(
          JSON.stringify({ success: true, message: "Transaction not found but logged" }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
        );
      }

      // Update transaction basic data
      const updateData: Record<string, unknown> = {
        status: internalStatus,
        djomy_response: payload,
        updated_at: new Date().toISOString(),
      };

      if (data.paidAmount) updateData.received_amount = data.paidAmount;
      if (data.fees) updateData.fees = data.fees;
      if (["SUCCESS", "FAILED", "CANCELLED"].includes(internalStatus)) {
        updateData.completed_at = new Date().toISOString();
      }

      await supabaseAdmin
        .from("djomy_transactions")
        .update(updateData)
        .eq("id", tx.id);

      logStep("Transaction updated", { txId: tx.id, status: internalStatus });

      // Process SUCCESS with trust score evaluation
      if (eventType === "payment.success") {
        logStep("Processing successful payment with trust score evaluation", { 
          txId: tx.id, 
          amount: data.paidAmount || tx.amount,
          vendorId: tx.vendor_id 
        });

        // Secondary verification with Djomy API
        let djomyVerification = { verified: true, status: "SUCCESS", data: null as unknown };
        if (clientId && clientSecret) {
          djomyVerification = await verifyTransactionWithDjomy(
            data.transactionId,
            clientId,
            clientSecret,
            false
          );
          logStep("Secondary verification result", djomyVerification);
        }

        // Calculate trust score
        const trustResult = await calculateTrustScore(supabaseAdmin, tx, djomyVerification);

        // Log trust score
        await supabaseAdmin.from("trust_score_logs").insert({
          transaction_id: tx.id,
          vendor_id: tx.vendor_id,
          user_id: tx.user_id,
          total_score: trustResult.totalScore,
          threshold_used: 70,
          auto_released: trustResult.autoReleased,
          score_breakdown: trustResult.breakdown,
          djomy_verification_result: djomyVerification,
          decision: trustResult.decision
        });

        // Update phone history
        await supabaseAdmin.rpc("update_phone_history", {
          p_phone: tx.payer_phone || "",
          p_user_id: tx.user_id,
          p_success: true
        });

        const paidAmount = Number(data.paidAmount || tx.amount);
        const fees = Number(data.fees || paidAmount * 0.02);
        const receivedAmount = paidAmount - fees;

        // Handle vendor funds with auto-release logic
        if (tx.vendor_id) {
          // Create blocked funds record
          const { data: blockedFund } = await supabaseAdmin
            .from("vendor_blocked_funds")
            .insert({
              vendor_id: tx.vendor_id,
              transaction_id: tx.id,
              amount: receivedAmount,
              original_amount: paidAmount,
              fees: fees,
              currency: "GNF",
              status: trustResult.autoReleased ? "RELEASED" : "BLOCKED",
              trust_score: trustResult.totalScore,
              auto_released: trustResult.autoReleased,
              release_type: trustResult.autoReleased ? "AUTO_RELEASE" : null,
              released_at: trustResult.autoReleased ? new Date().toISOString() : null
            })
            .select()
            .single();

          if (trustResult.autoReleased) {
            logStep("AUTO-RELEASING funds based on trust score", { 
              vendorId: tx.vendor_id, 
              amount: receivedAmount,
              trustScore: trustResult.totalScore 
            });

            // Get vendor user_id
            const { data: vendor } = await supabaseAdmin
              .from("vendors")
              .select("user_id")
              .eq("id", tx.vendor_id)
              .single();

            if (vendor?.user_id) {
              // Get or create vendor wallet
              const { data: wallet } = await supabaseAdmin
                .from("wallets")
                .select("id, balance")
                .eq("user_id", vendor.user_id)
                .single();

              if (wallet) {
                await supabaseAdmin
                  .from("wallets")
                  .update({ 
                    balance: Number(wallet.balance) + receivedAmount,
                    updated_at: new Date().toISOString()
                  })
                  .eq("id", wallet.id);

                await supabaseAdmin.from("wallet_transactions").insert({
                  wallet_id: wallet.id,
                  amount: receivedAmount,
                  type: "credit",
                  description: `Paiement auto-libéré (score: ${trustResult.totalScore}) - ${tx.order_id}`,
                  reference_id: tx.id
                });
              }
            }

            // Log admin action for auto-release
            await supabaseAdmin.from("admin_action_logs").insert({
              admin_id: "00000000-0000-0000-0000-000000000000",
              action_type: "AUTO_RELEASE_FUNDS",
              target_type: "vendor_blocked_funds",
              target_id: blockedFund?.id || tx.id,
              reason: `Score de confiance: ${trustResult.totalScore}/100 >= seuil (auto-release)`,
              new_value: { 
                amount: receivedAmount, 
                trust_score: trustResult.totalScore,
                breakdown: trustResult.breakdown,
                djomy_verification: djomyVerification.status
              }
            });

          } else {
            logStep("Funds BLOCKED - notifying admin", { 
              decision: trustResult.decision,
              trustScore: trustResult.totalScore 
            });

            // Create admin notification
            await supabaseAdmin.rpc("create_admin_notification", {
              p_type: "PAYMENT_REVIEW_REQUIRED",
              p_title: "Paiement nécessitant révision manuelle",
              p_message: `Transaction ${tx.order_id} de ${paidAmount.toLocaleString()} GNF bloquée. Score: ${trustResult.totalScore}/100. Décision: ${trustResult.decision}`,
              p_priority: trustResult.totalScore < 35 ? "high" : "medium",
              p_entity_type: "djomy_transaction",
              p_entity_id: tx.id,
              p_metadata: {
                vendor_id: tx.vendor_id,
                amount: paidAmount,
                received_amount: receivedAmount,
                trust_score: trustResult.totalScore,
                decision: trustResult.decision,
                breakdown: trustResult.breakdown,
                djomy_verification: djomyVerification
              }
            });
          }
        } else if (tx.user_id) {
          // Direct user payment - credit wallet
          const { data: wallet } = await supabaseAdmin
            .from("wallets")
            .select("id, balance")
            .eq("user_id", tx.user_id)
            .single();

          if (wallet) {
            await supabaseAdmin
              .from("wallets")
              .update({ 
                balance: Number(wallet.balance) + receivedAmount,
                updated_at: new Date().toISOString()
              })
              .eq("id", wallet.id);

            await supabaseAdmin.from("wallet_transactions").insert({
              wallet_id: wallet.id,
              amount: receivedAmount,
              type: "credit",
              description: `Dépôt Djomy - ${tx.order_id}`,
              reference_id: tx.id
            });
          }
        }
      } else if (eventType === "payment.failed" || eventType === "payment.cancelled") {
        // Update phone history for failure
        await supabaseAdmin.rpc("update_phone_history", {
          p_phone: tx.payer_phone || "",
          p_user_id: tx.user_id,
          p_success: false
        });
      }
    }

    // Mark webhook as processed
    await supabaseAdmin
      .from("djomy_webhook_logs")
      .update({ processed: true, processed_at: new Date().toISOString() })
      .eq("id", webhookLog?.id);

    const duration = Date.now() - startTime;
    logStep("Webhook processed successfully", { duration });

    return new Response(
      JSON.stringify({ success: true, message: "Webhook processed" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    const duration = Date.now() - startTime;
    
    logStep("ERROR processing webhook", { message: errorMessage, duration });
    
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  }
});
