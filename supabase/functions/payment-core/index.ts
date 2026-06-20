/**
 * 💳 PAYMENT CORE - ENDPOINT UNIQUE CENTRALISÉ
 * Gère tous les types de paiements: ORDER, SUBSCRIPTION, BOOST, DELIVERY, COMMISSION
 * Intégration Djomy avec scoring automatique et auto-déblocage
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Types de paiement supportés
type PaymentType = 'ORDER_PAYMENT' | 'SUBSCRIPTION' | 'BOOST' | 'DELIVERY' | 'COMMISSION' | 'WALLET_TOPUP' | 'TRANSFER';
type PaymentMethod = 'OM' | 'MOMO' | 'CARD' | 'MTN' | 'KULU';

interface PaymentRequest {
  type: PaymentType;
  reference_id: string;
  amount: number;
  currency?: string;
  phone: string;
  method: PaymentMethod;
  vendor_id?: string;
  metadata?: Record<string, unknown>;
  description?: string;
  idempotency_key?: string;
}

const logStep = (step: string, details?: Record<string, unknown>) => {
  const timestamp = new Date().toISOString();
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[${timestamp}] [PAYMENT-CORE] ${step}${detailsStr}`);
};

// ============= DJOMY TOKEN MANAGER =============
// Gère l'authentification par token OAuth2 avec régénération automatique

interface DjomyTokenData {
  accessToken: string;
  expiresAt: number; // timestamp en ms
}

// Cache du token en mémoire (par environnement)
const tokenCache: Record<string, DjomyTokenData> = {};

// Génère un nouveau token via l'endpoint officiel Djomy
async function generateDjomyToken(clientId: string, clientSecret: string, useSandbox: boolean): Promise<DjomyTokenData> {
  const baseUrl = useSandbox 
    ? "https://sandbox-api.djomy.africa" 
    : "https://api.djomy.africa";
  
  logStep("🔐 Generating new Djomy token", { baseUrl, useSandbox });
  
  const response = await fetch(`${baseUrl}/v1/auth/token`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "User-Agent": "224solutions-payment-core/1.0",
    },
    body: JSON.stringify({
      client_id: clientId,
      client_secret: clientSecret,
      grant_type: "client_credentials"
    }),
  });
  
  const responseText = await response.text();
  logStep("Token response", { status: response.status, bodyPreview: responseText.substring(0, 200) });
  
  if (!response.ok) {
    throw new Error(`Djomy token generation failed: ${response.status} - ${responseText}`);
  }
  
  const data = JSON.parse(responseText);
  
  // Calcule l'expiration (default 1h moins 5min de marge)
  const expiresIn = data.expires_in || 3600;
  const expiresAt = Date.now() + (expiresIn - 300) * 1000; // -5min de marge
  
  const tokenData: DjomyTokenData = {
    accessToken: data.access_token || data.accessToken,
    expiresAt
  };
  
  logStep("✅ Token generated successfully", { 
    expiresIn, 
    expiresAt: new Date(expiresAt).toISOString() 
  });
  
  return tokenData;
}

// Récupère un token valide (depuis cache ou génère un nouveau)
async function getDjomyAccessToken(clientId: string, clientSecret: string, useSandbox: boolean): Promise<string> {
  const cacheKey = `${useSandbox ? 'sandbox' : 'prod'}_${clientId}`;
  const cachedToken = tokenCache[cacheKey];
  
  // Vérifie si le token en cache est encore valide
  if (cachedToken && cachedToken.expiresAt > Date.now()) {
    const remainingMinutes = Math.round((cachedToken.expiresAt - Date.now()) / 60000);
    logStep("♻️ Using cached token", { remainingMinutes, cacheKey });
    return cachedToken.accessToken;
  }
  
  // Token expiré ou inexistant → génère un nouveau
  logStep("🔄 Token expired or missing, generating new one", { cacheKey });
  const newToken = await generateDjomyToken(clientId, clientSecret, useSandbox);
  
  // Met en cache
  tokenCache[cacheKey] = newToken;
  
  return newToken.accessToken;
}

// Initiate Djomy payment avec token Bearer
async function initiateDjomyPayment(
  accessToken: string,
  payload: {
    paymentMethod: string;
    payerIdentifier: string;
    amount: number;
    countryCode: string;
    merchantPaymentReference: string;
    description: string;
  },
  useSandbox: boolean
): Promise<{ success: boolean; transactionId?: string; error?: string; data?: unknown }> {
  const baseUrl = useSandbox 
    ? "https://sandbox-api.djomy.africa" 
    : "https://api.djomy.africa";
  
  logStep("💳 Initiating Djomy payment", { payload, baseUrl });
  
  const response = await fetch(`${baseUrl}/v1/payments`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "User-Agent": "224solutions-payment-core/1.0",
      "Authorization": `Bearer ${accessToken}`,
    },
    body: JSON.stringify(payload),
  });
  
  const responseText = await response.text();
  logStep("Djomy response", { status: response.status, body: responseText.substring(0, 300) });
  
  if (!response.ok) {
    // Si 401/403, le token pourrait être invalide
    if (response.status === 401 || response.status === 403) {
      logStep("⚠️ Token potentially invalid", { status: response.status });
    }
    return { success: false, error: `${response.status}: ${responseText}` };
  }
  
  const data = JSON.parse(responseText);
  return { 
    success: true, 
    transactionId: data.transactionId || data.id,
    data 
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  return new Response(
    JSON.stringify({
      success: false,
      error: "Djomy has been fully decommissioned from this system. Use backend Node.js payment endpoints.",
      code: "DJOMY_DECOMMISSIONED",
    }),
    { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 410 }
  );

  const startTime = Date.now();
  
  try {
    logStep("Payment Core request received");

    // Parse and validate request
    const body: PaymentRequest = await req.json();
    const {
      type,
      reference_id,
      amount,
      currency = "GNF",
      phone,
      method,
      vendor_id,
      metadata = {},
      description,
      idempotency_key,
    } = body;

    // Validation
    if (!type || !['ORDER_PAYMENT', 'SUBSCRIPTION', 'BOOST', 'DELIVERY', 'COMMISSION', 'WALLET_TOPUP', 'TRANSFER'].includes(type)) {
      throw new Error("Type de paiement invalide");
    }
    if (!reference_id) {
      throw new Error("reference_id requis");
    }
    if (!amount || amount <= 0) {
      throw new Error("Montant invalide");
    }
    if (!phone || phone.length < 8) {
      throw new Error("Numéro de téléphone invalide");
    }
    if (!method || !['OM', 'MOMO', 'CARD', 'MTN', 'KULU'].includes(method)) {
      throw new Error("Méthode de paiement invalide (OM, MOMO, CARD, MTN, KULU)");
    }

    logStep("Request validated", { type, amount, method, reference_id });

    // Get Djomy credentials
    const clientId = Deno.env.get("DJOMY_CLIENT_ID")?.trim();
    const clientSecret = Deno.env.get("DJOMY_CLIENT_SECRET")?.trim();
    const useSandbox = Deno.env.get("DJOMY_SANDBOX") === "true";

    if (!clientId || !clientSecret) {
      throw new Error("Configuration Djomy manquante");
    }

    // Initialize Supabase clients
    const supabaseAnon = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? ""
    );
    
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false } }
    );

    // Get authenticated user
    const authHeader = req.headers.get("Authorization");
    let userId: string | null = null;

    if (authHeader) {
      const token = authHeader.replace("Bearer ", "");
      const { data: userData } = await supabaseAnon.auth.getUser(token);
      if (userData.user) {
        userId = userData.user.id;
        logStep("User authenticated", { userId });
      }
    }

    // Check idempotency
    if (idempotency_key) {
      const { data: existing } = await supabaseAdmin
        .from("djomy_transactions")
        .select("id, status, djomy_transaction_id, order_id")
        .eq("idempotency_key", idempotency_key)
        .single();

      if (existing) {
        logStep("Idempotent request - returning existing", { transactionId: existing.id });
        return new Response(
          JSON.stringify({
            success: true,
            transaction_id: existing.id,
            djomy_transaction_id: existing.djomy_transaction_id,
            order_id: existing.order_id,
            status: existing.status,
            message: "Transaction existante",
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
        );
      }
    }

    // Generate unique order ID
    const orderId = `224-${type.substring(0, 3)}-${Date.now()}-${Math.random().toString(36).substring(2, 8).toUpperCase()}`;

    // Create transaction record (PENDING status, blocked by default)
    const { data: newTransaction, error: insertError } = await supabaseAdmin
      .from("djomy_transactions")
      .insert({
        order_id: orderId,
        payment_type: type,
        reference_id: reference_id,
        user_id: userId,
        vendor_id: vendor_id || null,
        amount,
        currency,
        payment_method: method,
        status: "PENDING",
        payer_phone: phone.replace(/\s/g, ""),
        country_code: "GN",
        description: description || `Paiement ${type} - ${orderId}`,
        metadata: metadata,
        idempotency_key: idempotency_key || null,
        ip_address: req.headers.get("x-forwarded-for") || req.headers.get("cf-connecting-ip"),
        user_agent: req.headers.get("user-agent"),
        auto_released: false,
        release_type: 'BLOCKED',
      })
      .select()
      .single();

    if (insertError) {
      logStep("DB insert error", { error: insertError.message });
      throw new Error("Erreur lors de la création de la transaction");
    }

    logStep("Transaction created", { id: newTransaction.id, orderId });

    // Log API request
    await supabaseAdmin.from("djomy_api_logs").insert({
      request_type: "PAYMENT_CORE_INIT",
      endpoint: "/v1/payments",
      request_payload: { type, amount, method, reference_id },
      transaction_id: newTransaction.id,
    });

    // Get Djomy access token
    const accessToken = await getDjomyAccessToken(clientId, clientSecret, useSandbox);

    // Prepare and send Djomy payment request
    const djomyPayload = {
      paymentMethod: method,
      payerIdentifier: phone.replace(/\s/g, ""),
      amount: amount,
      countryCode: "GN",
      merchantPaymentReference: orderId,
      description: description || `224Solutions - ${type} - ${orderId}`,
    };

    const djomyResult = await initiateDjomyPayment(
      accessToken,
      djomyPayload,
      useSandbox
    );

    if (!djomyResult.success) {
      // Update transaction to FAILED
      await supabaseAdmin
        .from("djomy_transactions")
        .update({
          status: "FAILED",
          error_message: djomyResult.error,
          updated_at: new Date().toISOString(),
        })
        .eq("id", newTransaction.id);

      throw new Error(`Erreur Djomy: ${djomyResult.error}`);
    }

    // Update transaction with Djomy response
    await supabaseAdmin
      .from("djomy_transactions")
      .update({
        status: "PROCESSING",
        djomy_transaction_id: djomyResult.transactionId,
        djomy_response: djomyResult.data,
        updated_at: new Date().toISOString(),
      })
      .eq("id", newTransaction.id);

    const duration = Date.now() - startTime;
    logStep("Payment initiated successfully", { 
      transactionId: newTransaction.id,
      djomyTransactionId: djomyResult.transactionId,
      duration
    });

    return new Response(
      JSON.stringify({
        success: true,
        transaction_id: newTransaction.id,
        djomy_transaction_id: djomyResult.transactionId,
        order_id: orderId,
        status: "PROCESSING",
        type: type,
        amount: amount,
        currency: currency,
        message: "Paiement initié - En attente de confirmation",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    const duration = Date.now() - startTime;
    
    logStep("ERROR", { message: errorMessage, duration });

    return new Response(
      JSON.stringify({ 
        success: false, 
        error: errorMessage,
        code: "PAYMENT_ERROR"
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  }
});
