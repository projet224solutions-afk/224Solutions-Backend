/**
 * 🪝 CHAPCHAPPAY WEBHOOK - Recevoir les notifications de paiement
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-ccp-signature, x-timestamp",
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const timestamp = new Date().toISOString();
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[${timestamp}] [CCP-WEBHOOK] ${step}${detailsStr}`);
};

// Web Crypto API pour HMAC-SHA256
const encoder = new TextEncoder();

async function hmacSha256(key: string, message: string): Promise<string> {
  const keyData = encoder.encode(key);
  const messageData = encoder.encode(message);
  
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, messageData);
  const hashArray = Array.from(new Uint8Array(signature));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Vérifier la signature du webhook
 */
async function verifySignature(payload: string, signature: string, timestamp: string): Promise<boolean> {
  const secretKey = Deno.env.get("CCP_SECRET_KEY") || Deno.env.get("CCP_ENCRYPTION_KEY");
  if (!secretKey) {
    logStep("⚠️ No secret key configured for webhook verification");
    return true; // Allow if not configured (dev mode)
  }

  const data = `${timestamp}${payload}`;
  const expectedSignature = await hmacSha256(secretKey, data);

  return signature === expectedSignature;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Webhook received");

    // Get signature headers
    const signature = req.headers.get("x-ccp-signature") || req.headers.get("X-CCP-Signature") || "";
    const timestamp = req.headers.get("x-timestamp") || req.headers.get("X-Timestamp") || "";

    // Parse body
    const bodyText = await req.text();
    logStep("Webhook payload", { bodyPreview: bodyText.substring(0, 200) });

    // Verify signature
    if (signature && !(await verifySignature(bodyText, signature, timestamp))) {
      logStep("❌ Invalid webhook signature");
      return new Response(
        JSON.stringify({ success: false, error: "Invalid signature" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 }
      );
    }

    const payload = JSON.parse(bodyText);
    const {
      event_type,
      transaction_id,
      order_id,
      status,
      amount,
      paid_amount,
      fees,
      payment_method,
      customer_phone,
      completed_at,
    } = payload;

    logStep("Webhook data", { 
      event_type, 
      transaction_id, 
      status,
      amount 
    });

    // Initialize Supabase admin client
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false } }
    );

    // Store webhook event
    await supabaseAdmin
      .from("chapchappay_webhooks")
      .insert({
        event_type,
        transaction_id,
        order_id,
        payload,
        processed: false,
      });

    // Map ChapChapPay status to internal status
    const statusMap: Record<string, string> = {
      "PENDING": "pending",
      "PROCESSING": "processing",
      "SUCCESS": "completed",
      "COMPLETED": "completed",
      "FAILED": "failed",
      "CANCELLED": "cancelled",
      "EXPIRED": "failed",
    };

    const internalStatus = statusMap[status?.toUpperCase()] || status?.toLowerCase() || "unknown";

    // Update mobile_money_transactions
    const { data: transaction } = await supabaseAdmin
      .from("mobile_money_transactions")
      .update({
        status: internalStatus,
        paid_amount: paid_amount,
        fees: fees,
        completed_at: completed_at,
        provider_response: payload,
        updated_at: new Date().toISOString(),
      })
      .or(`provider_transaction_id.eq.${transaction_id},order_id.eq.${order_id}`)
      .select()
      .single();

    logStep("Transaction updated", { 
      id: transaction?.id, 
      status: internalStatus 
    });

    // If payment completed, credit wallet for PULL payments
    if (internalStatus === "completed" && transaction?.payment_type === "pull" && transaction?.user_id) {
      logStep("Crediting wallet for completed PULL payment");
      
      // Get user's wallet
      const { data: wallet } = await supabaseAdmin
        .from("wallets")
        .select("id, balance")
        .eq("user_id", transaction.user_id)
        .single();

      if (wallet) {
        const newBalance = wallet.balance + (paid_amount || amount);
        
        await supabaseAdmin
          .from("wallets")
          .update({
            balance: newBalance,
            updated_at: new Date().toISOString(),
          })
          .eq("id", wallet.id);

        // Create wallet transaction
        await supabaseAdmin
          .from("wallet_transactions")
          .insert({
            transaction_id: `CCP-${transaction_id}`,
            transaction_type: "deposit",
            amount: paid_amount || amount,
            net_amount: (paid_amount || amount) - (fees || 0),
            fee: fees || 0,
            currency: "GNF",
            status: "completed",
            description: `Dépôt Mobile Money (${payment_method})`,
            receiver_wallet_id: wallet.id,
            metadata: {
              provider: "chapchappay",
              ccp_transaction_id: transaction_id,
              payment_method,
              customer_phone,
            }
          });

        logStep("Wallet credited", { 
          walletId: wallet.id, 
          amount: paid_amount || amount,
          newBalance 
        });
      }
    }

    // Mark webhook as processed
    await supabaseAdmin
      .from("chapchappay_webhooks")
      .update({ processed: true })
      .eq("transaction_id", transaction_id);

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: "Webhook processed",
        status: internalStatus 
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("❌ Webhook ERROR", { message: errorMessage });

    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  }
});
