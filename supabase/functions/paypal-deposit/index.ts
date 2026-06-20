/**
 * PAYPAL DEPOSIT - Dépôt via PayPal vers wallet
 * Crée un order PayPal, puis capture le paiement et crédite le wallet
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { getInternalFxRate } from "../_shared/fx-internal.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[PAYPAL-DEPOSIT] ${step}${detailsStr}`);
};

import { getPdgFeeRate, FEE_KEYS } from "../_shared/pdg-fees.ts";

const PAYPAL_API_BASE = "https://api-m.paypal.com";

// PayPal supported currencies
const PAYPAL_SUPPORTED_CURRENCIES = [
  "AUD","BRL","CAD","CNY","CZK","DKK","EUR","HKD","HUF","ILS",
  "JPY","MYR","MXN","TWD","NZD","NOK","PHP","PLN","GBP","SGD",
  "SEK","CHF","THB","USD","RUB"
];

function isCurrencyCode(value: unknown): value is string {
  return typeof value === "string" && /^[A-Z]{3}$/.test(value.toUpperCase());
}

function deriveWalletCurrencyFromProfile(country: unknown, detectedCurrency: unknown): string {
  const c = String(country || "").trim().toLowerCase();

  // Priorité: pays déclaré (origine de l'utilisateur), pas la géolocalisation.
  if (c.includes("guin") || c === "gn" || c.includes("guinea")) return "GNF";
  if (c.includes("sénégal") || c.includes("senegal") || c === "sn") return "XOF";

  // Zone euro (liste courte mais utile)
  const euroCountries = [
    "france","espagne","spain","italie","italy","allemagne","germany",
    "belgique","belgium","portugal","pays-bas","netherlands","luxembourg",
  ];
  if (euroCountries.some((k) => c.includes(k))) return "EUR";

  // Fallback: detected_currency si valide
  if (isCurrencyCode(detectedCurrency)) return detectedCurrency.toUpperCase();

  // Défaut système
  return "GNF";
}

function getSafePayPalReturnUrl(rawUrl: unknown, fallbackUrl: string): string {
  if (typeof rawUrl !== "string" || rawUrl.trim().length === 0) return fallbackUrl;

  try {
    const parsed = new URL(rawUrl);
    const isHttp = parsed.protocol === "https:" || parsed.protocol === "http:";
    const isLovableHost = parsed.hostname.endsWith(".lovable.app");
    const isLocalHost = parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1";

    if (!isHttp || (!isLovableHost && !isLocalHost)) {
      return fallbackUrl;
    }

    return parsed.toString();
  } catch {
    return fallbackUrl;
  }
}

async function getFxRateForDeposit(supabaseAdmin: any, from: string, to: string): Promise<number> {
  const result = await getInternalFxRate(supabaseAdmin, from, to);
  return result.rate;
}

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
    const { validateHmacRequest, hmacErrorResponse, storeIdempotencyResponse, assessFraudRisk } = await import("../_shared/hmac-guard.ts");
    if (req.headers.get("x-signature")) {
      const hmacResult = await validateHmacRequest(req, rawBody, { checkIdempotency: true });
      if (!hmacResult.valid) {
        logStep("HMAC validation failed", { code: hmacResult.code });
        return hmacErrorResponse(hmacResult, corsHeaders);
      }
      logStep("HMAC signature verified ✅");
    }

    // Auth - validate JWT using getUser (verify_jwt=false)
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      throw new Error("Non autorisé - header manquant");
    }

    const token = authHeader.replace("Bearer ", "");

    const supabaseAuth = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supabaseAuth.auth.getUser(token);
    if (authError || !user) {
      logStep("Auth failed", { error: authError?.message });
      throw new Error("Non autorisé - token invalide");
    }

    const userId = user.id;
    logStep("User authenticated", { userId });

    const {
      amount,
      currency = "USD",
      action = "create",
      orderId,
      returnUrl,
      cancelUrl,
    } = JSON.parse(rawBody);

    const accessToken = await getPayPalAccessToken();
    logStep("PayPal access token obtained");

    // --- ACTION: CREATE ORDER ---
    if (action === "create") {
      if (!amount || amount <= 0) throw new Error("Montant invalide");

      // Lire le taux dynamique depuis pdg_settings
      const supabaseAdminCreate = createClient(
        Deno.env.get("SUPABASE_URL") ?? "",
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
      );
      const DEPOSIT_FEE_RATE = await getPdgFeeRate(supabaseAdminCreate, FEE_KEYS.DEPOSIT);

      // Force USD if currency not supported by PayPal
      const upperCurrency = currency.toUpperCase();
      const paypalCurrency = PAYPAL_SUPPORTED_CURRENCIES.includes(upperCurrency) ? upperCurrency : "USD";
      
      const depositFee = Math.round(amount * (DEPOSIT_FEE_RATE / 100) * 100) / 100;
      const netAmount = Math.round((amount - depositFee) * 100) / 100;

      logStep("Creating PayPal order", { amount, depositFee, netAmount, originalCurrency: upperCurrency, paypalCurrency });

      const orderRes = await fetch(`${PAYPAL_API_BASE}/v2/checkout/orders`, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          intent: "CAPTURE",
          purchase_units: [{
            amount: {
              currency_code: paypalCurrency,
              value: amount.toFixed(2),
            },
            description: `Dépôt wallet - 224Solutions`,
            custom_id: userId,
          }],
          application_context: {
            brand_name: "224Solutions",
            shipping_preference: "NO_SHIPPING",
            user_action: "PAY_NOW",
            // Force l'expérience saisie carte directement (guest checkout)
            landing_page: "BILLING",
            return_url: getSafePayPalReturnUrl(
              returnUrl,
              "https://vista-flows.lovable.app/wallet?paypal=success"
            ),
            cancel_url: getSafePayPalReturnUrl(
              cancelUrl,
              getSafePayPalReturnUrl(returnUrl, "https://vista-flows.lovable.app/wallet?paypal=cancel")
            ),
          },
        }),
      });

      if (!orderRes.ok) {
        const err = await orderRes.text();
        throw new Error(`PayPal create order failed [${orderRes.status}]: ${err}`);
      }

      const order = await orderRes.json();
      const approveLink = order.links?.find((l: any) => l.rel === "approve")?.href 
        || `https://www.paypal.com/checkoutnow?token=${order.id}`;
      logStep("PayPal order created", { orderId: order.id, status: order.status, approveLink });

      return new Response(JSON.stringify({
        success: true,
        orderId: order.id,
        status: order.status,
        approveUrl: approveLink,
        amount,
        depositFee,
        netAmount,
        paypalCurrency,
      }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    // --- ACTION: CHECK STATUS ---
    if (action === "check-status") {
      if (!orderId) throw new Error("orderId requis");
      const statusRes = await fetch(`${PAYPAL_API_BASE}/v2/checkout/orders/${orderId}`, {
        headers: { "Authorization": `Bearer ${accessToken}` },
      });
      if (!statusRes.ok) throw new Error("Impossible de vérifier le statut");
      const statusData = await statusRes.json();
      logStep("Order status check", { orderId, status: statusData.status });
      return new Response(JSON.stringify({
        success: true,
        orderId,
        status: statusData.status,
      }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    // --- ACTION: CAPTURE ORDER ---
    if (action === "capture") {
      if (!orderId) throw new Error("orderId requis pour capture");

      // Check order status first
      const checkRes = await fetch(`${PAYPAL_API_BASE}/v2/checkout/orders/${orderId}`, {
        headers: { "Authorization": `Bearer ${accessToken}` },
      });
      if (checkRes.ok) {
        const checkData = await checkRes.json();
        logStep("Pre-capture status check", { orderId, status: checkData.status });
        if (checkData.status !== "APPROVED") {
          throw new Error(`L'ordre n'est pas encore approuvé (statut: ${checkData.status}). Veuillez d'abord approuver le paiement dans PayPal.`);
        }
      }

      logStep("Capturing PayPal order", { orderId });

      const captureRes = await fetch(`${PAYPAL_API_BASE}/v2/checkout/orders/${orderId}/capture`, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
      });

      if (!captureRes.ok) {
        const err = await captureRes.text();
        throw new Error(`PayPal capture failed [${captureRes.status}]: ${err}`);
      }

      const captureData = await captureRes.json();
      logStep("PayPal capture result", { status: captureData.status });

      if (captureData.status !== "COMPLETED") {
        throw new Error(`Capture non complétée: ${captureData.status}`);
      }

      // Extract captured amount
      const capturedAmount = parseFloat(
        captureData.purchase_units[0].payments.captures[0].amount.value
      );
      const capturedCurrency = captureData.purchase_units[0].payments.captures[0].amount.currency_code;
      // Get or create wallet (devise native de l'utilisateur)
      const supabaseAdmin = createClient(
        Deno.env.get("SUPABASE_URL") ?? "",
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
      );

      // Lire le taux dynamique depuis pdg_settings
      const DEPOSIT_FEE_RATE = await getPdgFeeRate(supabaseAdmin, FEE_KEYS.DEPOSIT);
      const depositFee = Math.round(capturedAmount * (DEPOSIT_FEE_RATE / 100) * 100) / 100;
      const netAmount = Math.round((capturedAmount - depositFee) * 100) / 100;

      // Profil (pays déclaré) pour déterminer la devise du wallet à la création
      const { data: profile } = await supabaseAdmin
        .from("profiles")
        .select("country, detected_currency")
        .eq("id", userId)
        .maybeSingle();

      // Get existing wallet (if any)
      let { data: wallet } = await supabaseAdmin
        .from("wallets")
        .select("id, balance, currency")
        .eq("user_id", userId)
        .single();

      // Devise à utiliser pour la balance du wallet
      const walletCurrency = wallet?.currency || deriveWalletCurrencyFromProfile(profile?.country, profile?.detected_currency);

      if (!wallet) {
        const { data: newWallet, error: createErr } = await supabaseAdmin
          .from("wallets")
          .insert({ user_id: userId, balance: 0, currency: walletCurrency, wallet_status: "active" })
          .select("id, balance, currency")
          .single();
        if (createErr) throw new Error("Impossible de créer le wallet");
        wallet = newWallet;
      }

      // Convertir le montant capturé dans la devise du wallet (si nécessaire)
      let rateUsed = 1;
      let creditedNetAmount = netAmount;
      let creditedFeeAmount = depositFee;

      if (capturedCurrency.toUpperCase() !== walletCurrency.toUpperCase()) {
        rateUsed = await getFxRateForDeposit(supabaseAdmin, capturedCurrency, walletCurrency);
        creditedNetAmount = Math.round(netAmount * rateUsed * 100) / 100;
        creditedFeeAmount = Math.round(depositFee * rateUsed * 100) / 100;
      }

      const newBalance = (wallet!.balance || 0) + creditedNetAmount;
      const referenceNumber = `PP-DEP-${Date.now()}`;

      // Update balance + insert transaction
      await supabaseAdmin.from("wallets").update({
        balance: newBalance,
        updated_at: new Date().toISOString(),
      }).eq("id", wallet!.id);

      await supabaseAdmin.from("wallet_transactions").insert({
        transaction_id: referenceNumber,
        transaction_type: "deposit",
        wallet_id: wallet!.id,
        amount: creditedNetAmount,
        net_amount: creditedNetAmount,
        fee: creditedFeeAmount,
        currency: walletCurrency,
        status: "completed",
        description: `Dépôt PayPal - Order ${orderId}`,
        receiver_wallet_id: wallet!.id,
        receiver_user_id: userId,
        metadata: {
          paypal_order_id: orderId,
          paypal_capture_id: captureData.purchase_units[0].payments.captures[0].id,
          gross_amount_original: capturedAmount,
          currency_original: capturedCurrency,
          fee_original: depositFee,
          net_amount_original: netAmount,
          credited_amount: creditedNetAmount,
          wallet_currency: walletCurrency,
          fx_rate_used: rateUsed,
          fee_rate: DEPOSIT_FEE_RATE,
        },
      } as any);

      logStep("Wallet credited", { walletId: wallet!.id, walletCurrency, newBalance, creditedNetAmount, fxRate: rateUsed });

      return new Response(JSON.stringify({
        success: true,
        orderId,
        capturedAmount,
        depositFee,
        netAmount,
        newBalance,
        message: "Dépôt PayPal réussi !",
      }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    throw new Error(`Action inconnue: ${action}`);

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : "Erreur inconnue";
    logStep("ERROR", { message: errorMessage });
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
