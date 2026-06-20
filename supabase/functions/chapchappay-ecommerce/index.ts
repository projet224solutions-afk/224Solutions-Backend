import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// ChapChapPay API - Documentation: https://chapchappay.com/guide/
const CCP_API_URL = "https://chapchappay.com";

interface EcommercePaymentRequest {
  amount: number;
  currency?: string;
  description?: string;
  orderId?: string;
  customerName?: string;
  customerPhone?: string;
  returnUrl?: string;
  cancelUrl?: string;
  notifyUrl?: string;
}

const logEcom = (step: string, details?: Record<string, unknown>) => {
  const timestamp = new Date().toISOString();
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[${timestamp}] [CCP-ECOM] ${step}${detailsStr}`);
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const startTime = Date.now();

  try {
    logEcom("E-Commerce payment started");

    const apiKey = Deno.env.get("CCP_API_KEY");

    if (!apiKey) {
      logEcom("❌ CCP_API_KEY not configured");
      return new Response(
        JSON.stringify({ success: false, error: "Service de paiement non configuré" }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const body: EcommercePaymentRequest = await req.json();

    logEcom("Request received", {
      amount: body.amount,
      orderId: body.orderId,
    });

    if (!body.amount || body.amount <= 0) {
      return new Response(
        JSON.stringify({ success: false, error: "Montant invalide" }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // Build payment data according to ChapChapPay docs
    const paymentData: Record<string, unknown> = {
      amount: body.amount,
    };

    if (body.orderId) paymentData.order_id = body.orderId;
    if (body.notifyUrl) paymentData.notify_url = body.notifyUrl;
    if (body.returnUrl) paymentData.return_url = body.returnUrl;
    if (body.description) paymentData.description = body.description;

    const endpoint = `${CCP_API_URL}/api/ecommerce/create`;

    logEcom("Calling ChapChapPay API", {
      endpoint,
      amount: body.amount,
      apiKeyPrefix: apiKey.substring(0, 12),
      payload: paymentData,
    });

    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "CCP-Api-Key": apiKey,
        "User-Agent": "Vista-Flows/1.0",
      },
      body: JSON.stringify(paymentData),
    });

    const responseText = await response.text();
    logEcom("ChapChapPay response", {
      status: response.status,
      body: responseText.substring(0, 500),
    });

    let result: Record<string, unknown>;
    try {
      result = JSON.parse(responseText);
    } catch {
      logEcom("❌ Failed to parse response", { raw: responseText.substring(0, 200) });
      return new Response(
        JSON.stringify({
          success: false,
          error: "Erreur de réponse du service",
          details: responseText.substring(0, 200),
        }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    if (!response.ok || result?.error) {
      const duration = Date.now() - startTime;
      logEcom("❌ ChapChapPay error", {
        status: response.status,
        error: result?.error || result?.message,
        duration,
      });

      return new Response(
        JSON.stringify({
          success: false,
          error: result?.error || result?.message || "Échec de création du paiement",
          details: result,
        }),
        {
          status: response.status,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const duration = Date.now() - startTime;
    logEcom("✅ Payment created", {
      operationId: result.operation_id,
      paymentUrl: result.payment_url,
      duration,
    });

    return new Response(
      JSON.stringify({
        success: true,
        transactionId: result.operation_id,
        paymentUrl: result.payment_url,
        orderId: result.order_id || body.orderId,
        amount: result.amount || body.amount,
        amountFormatted: result.amount_formatted,
        currency: "GNF",
        businessName: result.business_name,
        paymentMethods: result.payment_methods,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    const duration = Date.now() - startTime;
    const errorMessage = error instanceof Error ? error.message : "Erreur interne";

    logEcom("❌ ERROR", { message: errorMessage, duration });

    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
