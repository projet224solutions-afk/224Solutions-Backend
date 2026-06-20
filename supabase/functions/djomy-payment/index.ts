import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[DJOMY-PAYMENT] ${step}${detailsStr}`);
};

// Generate HMAC-SHA256 signature - Djomy format: HmacSHA256(clientId, clientSecret)
// Doc Djomy: CryptoJS.HmacSHA256(key, secret) où key=clientId et secret=clientSecret
async function generateHmacSignature(clientId: string, clientSecret: string): Promise<string> {
  const encoder = new TextEncoder();
  // IMPORTANT: Djomy utilise clientSecret comme clé HMAC et clientId comme message
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
  
  logStep("Getting access token", { 
    baseUrl, 
    clientIdLength: clientId.length,
    signatureLength: signature.length,
    xApiKeyPreview: xApiKey.substring(0, 30) + "..." 
  });
  
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
  
  const responseText = await response.text();
  logStep("Auth response", { 
    status: response.status, 
    statusText: response.statusText,
    responsePreview: responseText.substring(0, 200)
  });
  
  if (!response.ok) {
    throw new Error(`Authentication failed: ${response.status} - ${responseText}`);
  }
  
  const data = JSON.parse(responseText);
  logStep("Access token obtained", { tokenLength: data.accessToken?.length });
  return data.accessToken;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    const body = await req.json();
    const {
      amount,
      payerPhone,
      paymentMethod, // OM, MOMO, KULU, etc.
      description,
      orderId,
      returnUrl,
      cancelUrl,
      countryCode = "GN",
      useGateway = true, // Use gateway (redirect) or direct payment
      useSandbox = true, // ⚠️ SANDBOX par défaut - Changer à false quand production Djomy activée
    } = body;

    // Get and validate Djomy credentials
    const clientId = Deno.env.get("DJOMY_CLIENT_ID");
    const clientSecret = Deno.env.get("DJOMY_CLIENT_SECRET");

    if (!clientId || !clientSecret) {
      logStep("❌ Credentials missing", { 
        hasClientId: !!clientId, 
        hasSecret: !!clientSecret 
      });
      throw new Error("🔴 Credentials Djomy manquants. Configurez DJOMY_CLIENT_ID et DJOMY_CLIENT_SECRET dans les secrets Supabase.");
    }

    // Clean credentials
    const cleanClientId = clientId.trim();
    const cleanClientSecret = clientSecret.trim();

    // Validate Client ID format (must be djomy-merchant-XXXXX for production)
    if (!cleanClientId.startsWith("djomy-merchant-") && !useSandbox) {
      logStep("⚠️ Suspicious Client ID format", {
        clientIdPrefix: cleanClientId.substring(0, 15),
        expected: "djomy-merchant-XXXXX",
        hint: "Utilisez les credentials de l'espace marchand Djomy"
      });
      throw new Error(`🔴 Format Client ID invalide: "${cleanClientId.substring(0, 20)}..." doit commencer par "djomy-merchant-" en production. Vos credentials actuels ressemblent à des identifiants de test. Contactez support@djomy.africa.`);
    }

    logStep("Credentials verified", {
      env: useSandbox ? "sandbox" : "production",
      clientIdPrefix: cleanClientId.substring(0, 12) + "...",
      clientIdSuffix: cleanClientId.length >= 4 ? "..." + cleanClientId.slice(-4) : undefined,
      clientIdLength: cleanClientId.length,
      clientSecretLength: cleanClientSecret.length,
    });

    logStep("Payment request received", {
      amount,
      paymentMethod,
      orderId,
      useGateway,
      useSandbox,
    });

    // Initialize Supabase client
    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? ""
    );

    // Verify user authentication (optionnel, on garde userId null si non connecté)
    const authHeader = req.headers.get("Authorization");
    let userId: string | null = null;

    if (authHeader) {
      const token = authHeader.replace("Bearer ", "");
      const { data: userData, error: userError } = await supabaseClient.auth.getUser(token);
      if (!userError && userData.user) {
        userId = userData.user.id;
        logStep("User authenticated", { userId });
      }
    }

    // Validate required fields
    if (!amount || amount <= 0) {
      throw new Error("Invalid amount");
    }
    if (!payerPhone) {
      throw new Error("Payer phone number is required");
    }

    // Get access token with cleaned credentials
    const accessToken = await getAccessToken(cleanClientId, cleanClientSecret, useSandbox);
    
    // Generate API signature with cleaned credentials
    const signature = await generateHmacSignature(cleanClientId, cleanClientSecret);
    const xApiKey = `${cleanClientId}:${signature}`;

    const baseUrl = useSandbox 
      ? "https://sandbox-api.djomy.africa" 
      : "https://api.djomy.africa";

    let paymentResponse;
    
    if (useGateway) {
      // Payment with redirect to Djomy portal
      logStep("Initiating gateway payment");
      
      const gatewayPayload = {
        amount: amount,
        countryCode: countryCode,
        payerNumber: payerPhone.replace(/\s/g, ""),
        description: description || `Paiement commande ${orderId}`,
        merchantPaymentReference: orderId || `224SOL-${Date.now()}`,
        returnUrl: returnUrl,
        cancelUrl: cancelUrl || returnUrl,
      };

      logStep("Gateway payload", gatewayPayload);

      const response = await fetch(`${baseUrl}/v1/payments/gateway`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "User-Agent": "224solutions/1.0 (supabase-edge)",
          "Authorization": `Bearer ${accessToken}`,
          "X-API-KEY": xApiKey,
        },
        body: JSON.stringify(gatewayPayload),
      });

      if (!response.ok) {
        const errorText = await response.text();
        logStep("Gateway payment error", { status: response.status, error: errorText });
        throw new Error(`Payment initiation failed: ${response.status} - ${errorText}`);
      }

      paymentResponse = await response.json();
      logStep("Gateway payment response", paymentResponse);

    } else {
      // Direct payment (without redirect)
      if (!paymentMethod) {
        throw new Error("Payment method is required for direct payments");
      }

      logStep("Initiating direct payment", { paymentMethod });
      
      const directPayload = {
        paymentMethod: paymentMethod, // OM, MOMO, KULU
        payerIdentifier: payerPhone.replace(/\s/g, ""),
        amount: amount,
        countryCode: countryCode,
        description: description || `Paiement commande ${orderId}`,
        merchantPaymentReference: orderId || `224SOL-${Date.now()}`,
        returnUrl: returnUrl,
        cancelUrl: cancelUrl,
      };

      logStep("Direct payload", directPayload);

      const response = await fetch(`${baseUrl}/v1/payments`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
          "User-Agent": "224solutions/1.0 (supabase-edge)",
          "Authorization": `Bearer ${accessToken}`,
          "X-API-KEY": xApiKey,
        },
        body: JSON.stringify(directPayload),
      });

      if (!response.ok) {
        const errorText = await response.text();
        logStep("Direct payment error", { status: response.status, error: errorText });
        throw new Error(`Payment initiation failed: ${response.status} - ${errorText}`);
      }

      paymentResponse = await response.json();
      logStep("Direct payment response", paymentResponse);
    }

    // Save payment record to database
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false } }
    );

    const { error: insertError } = await supabaseAdmin
      .from("djomy_payments")
      .insert({
        user_id: userId,
        transaction_id: paymentResponse.transactionId || paymentResponse.id,
        amount: amount,
        currency: "GNF",
        payment_method: paymentMethod || "gateway",
        status: "pending",
        order_id: orderId,
        payer_phone: payerPhone,
        country_code: countryCode,
        redirect_url: paymentResponse.redirectUrl || paymentResponse.paymentUrl,
        response_data: paymentResponse,
      });

    if (insertError) {
      logStep("Database insert error (non-blocking)", { error: insertError.message });
    } else {
      logStep("Payment record saved to database");
    }

    return new Response(
      JSON.stringify({
        success: true,
        transactionId: paymentResponse.transactionId || paymentResponse.id,
        redirectUrl: paymentResponse.redirectUrl || paymentResponse.paymentUrl,
        status: paymentResponse.status || "pending",
        data: paymentResponse,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );

  } catch (error) {
    const errorMessageRaw = error instanceof Error ? error.message : String(error);

    // Transform technical errors into user-friendly messages
    let errorMessage = errorMessageRaw;
    let errorCode = "UNKNOWN";
    
    if (errorMessageRaw.includes('Authentication failed: 403')) {
      errorCode = "AUTH_403";
      errorMessage = "🔴 ERREUR 403: L'API Djomy refuse l'accès. Causes possibles:\n" +
                     "1. Client ID/Secret invalides (format attendu: djomy-merchant-XXXXX)\n" +
                     "2. Serveurs Supabase pas whitelistés par Djomy\n" +
                     "3. Credentials de test utilisés en production\n" +
                     "➡️ Action: Contactez support@djomy.africa pour vérifier vos credentials et demander la whitelist.";
    } else if (errorMessageRaw.includes('Authentication failed: 401')) {
      errorCode = "AUTH_401";
      errorMessage = "🔴 ERREUR 401: Signature HMAC invalide. Vérifiez que DJOMY_CLIENT_ID et DJOMY_CLIENT_SECRET correspondent exactement à vos identifiants Djomy (pas d'espaces, copié-collé exact).";
    } else if (errorMessageRaw.includes('Payment initiation failed: 400')) {
      errorCode = "PAYMENT_400";
      errorMessage = "⚠️ ERREUR 400: Données de paiement invalides. Vérifiez le numéro de téléphone, le montant et la méthode de paiement.";
    } else if (errorMessageRaw.includes('Payment initiation failed: 500')) {
      errorCode = "PAYMENT_500";
      errorMessage = "🔴 ERREUR 500: Problème serveur Djomy. Réessayez dans quelques minutes ou contactez support@djomy.africa.";
    } else if (errorMessageRaw.includes('Format Client ID invalide')) {
      errorCode = "INVALID_CREDENTIALS";
      errorMessage = errorMessageRaw; // Déjà user-friendly
    } else if (errorMessageRaw.includes('Credentials Djomy manquants')) {
      errorCode = "MISSING_CREDENTIALS";
      errorMessage = errorMessageRaw; // Déjà user-friendly
    }

    logStep("ERROR", { 
      code: errorCode,
      message: errorMessageRaw,
      userMessage: errorMessage 
    });

    // IMPORTANT: on renvoie 200 pour que le frontend reçoive le JSON d'erreur (au lieu d'un 'non-2xx status code')
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: errorMessage,
        errorCode: errorCode,
        details: errorMessageRaw !== errorMessage ? errorMessageRaw : undefined
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );
  }
});
