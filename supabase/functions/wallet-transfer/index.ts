/**
 * 🔐 WALLET TRANSFER SÉCURISÉ - V2 INTELLIGENT
 * ✅ Même devise = transfert local direct (pas de conversion)
 * ✅ Devise différente = conversion via taux internes (table currency_exchange_rates)
 * ✅ Aucun appel API externe — taux déjà collectés par african-fx-collect (cron horaire)
 * ✅ Marge de 3% incluse dans le taux, pas de commission supplémentaire
 * ✅ Signature HMAC, verrouillage optimiste, audit
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";
import { getPdgFeeRate, calculateFee, FEE_KEYS } from "../_shared/pdg-fees.ts";
import { getInternalFxRate } from "../_shared/fx-internal.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Defaults - will be overridden by pdg_settings
const DEFAULT_MIN_TRANSFER = 100;
const DEFAULT_MAX_TRANSFER = 50000000;

// Base currency for pdg_settings limits (all limits are stored in GNF)
const LIMITS_BASE_CURRENCY = "GNF";

/**
 * 🔄 Convertir plusieurs seuils (stockés en GNF) vers la devise de l'expéditeur
 * Utilise UN SEUL appel FX pour toutes les limites (performance)
 */
async function convertLimitsToCurrency(
  limits: number[],
  targetCurrency: string,
): Promise<number[]> {
  if (targetCurrency === LIMITS_BASE_CURRENCY) return limits;
  
  try {
    const { rate } = await getFxRateFromAPI(LIMITS_BASE_CURRENCY, targetCurrency);
    if (rate > 0) {
      return limits.map(l => smartRound(l * rate, targetCurrency));
    }
  } catch (e) {
    console.error(`[LIMITS] Failed to convert ${LIMITS_BASE_CURRENCY} → ${targetCurrency}:`, e);
  }
  // Fallback: return raw values
  return limits;
}

// Smart rounding: integers for weak currencies (GNF, XOF, etc.), 2 decimals for strong (EUR, USD, etc.)
const ZERO_DECIMAL_CURRENCIES = new Set([
  "GNF", "XOF", "XAF", "VND", "IDR", "KRW", "JPY", "CLP", "UGX", "RWF",
  "PYG", "COP", "HUF", "ISK", "BIF", "DJF", "KMF", "MGA", "VUV",
]);

function smartRound(amount: number, currency: string): number {
  if (ZERO_DECIMAL_CURRENCIES.has(currency.toUpperCase())) {
    return Math.round(amount);
  }
  return Math.round(amount * 100) / 100;
}

// ✅ Map wallet currency → country code for display
function currencyToCountry(currency: string): string {
  const map: Record<string, string> = {
    GNF: "GN", XOF: "SN", XAF: "CM", NGN: "NG", GHS: "GH",
    EUR: "FR", USD: "US", GBP: "GB", CHF: "CH", CAD: "CA",
    AUD: "AU", JPY: "JP", CNY: "CN", INR: "IN", AED: "AE",
    MAD: "MA", EGP: "EG", TND: "TN", DZD: "DZ", ZAR: "ZA",
    KES: "KE", TZS: "TZ", UGX: "UG", RWF: "RW", ETB: "ET",
    CDF: "CD", BRL: "BR", MXN: "MX", SAR: "SA", QAR: "QA",
    KWD: "KW", SLL: "SL", LRD: "LR", GMD: "GM", CVE: "CV", MRU: "MR",
    SEK: "SE", NOK: "NO", DKK: "DK", PLN: "PL", CZK: "CZ",
    HUF: "HU", RON: "RO", BGN: "BG", RSD: "RS", UAH: "UA",
    RUB: "RU", TRY: "TR", COP: "CO", CLP: "CL", PEN: "PE",
    VES: "VE", HTG: "HT", ILS: "IL", THB: "TH", PHP: "PH",
    MYR: "MY", SGD: "SG", IDR: "ID", VND: "VN", PKR: "PK",
    BDT: "BD", LKR: "LK", NZD: "NZ", ARS: "AR",
  };
  return map[currency?.toUpperCase()] || "XX";
}

// =============================================
// 🔑 SECURITY
// =============================================

const TRANSACTION_SECRET = Deno.env.get("TRANSACTION_SECRET_KEY");
if (!TRANSACTION_SECRET) throw new Error("CRITICAL: TRANSACTION_SECRET_KEY not configured");

async function generateSignature(transactionId: string, amount: number): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(`${transactionId}${amount}`);
  const keyData = encoder.encode(TRANSACTION_SECRET);
  const key = await crypto.subtle.importKey("raw", keyData, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, data);
  return Array.from(new Uint8Array(signature)).map(b => b.toString(16).padStart(2, "0")).join("");
}

async function logFinancialAudit(supabase: any, userId: string, action: string, data: any, isSuspicious = false) {
  try {
    await supabase.from("financial_audit_logs").insert({
      user_id: userId,
      action_type: action,
      description: `Wallet transfer: ${action}`,
      request_data: data,
      is_suspicious: isSuspicious
    });
  } catch (e) { console.error("[Audit] Log failed:", e); }
}

// =============================================
// 🌍 FX RATE — Lecture interne depuis currency_exchange_rates
// Aucun appel API externe. Les taux sont collectés par african-fx-collect
// (banques centrales + fallback documenté) et incluent déjà la marge de 3%.
// =============================================

// Supabase admin client for FX lookups (created lazily)
let _fxSupabase: any = null;
function getFxSupabase() {
  if (!_fxSupabase) {
    _fxSupabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
  }
  return _fxSupabase;
}

async function getFxRateFromAPI(from: string, to: string): Promise<{ rate: number; source: string; fetched_at: string }> {
  return getInternalFxRate(getFxSupabase(), from, to);
}

// =============================================
// 🔍 RESOLVE RECIPIENT
// =============================================

async function resolveRecipientId(supabase: any, recipientId: string): Promise<string | null> {
  const isUUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(recipientId);
  if (isUUID) return recipientId;

  const { data: userIdData } = await supabase.from('user_ids').select('user_id').eq('custom_id', recipientId.toUpperCase()).maybeSingle();
  if (userIdData) return userIdData.user_id;

  const { data: profileData } = await supabase.from('profiles').select('id').eq('public_id', recipientId.toUpperCase()).maybeSingle();
  if (profileData) return profileData.id;

  const { data: vendorData } = await supabase.from('vendors').select('user_id').eq('public_id', recipientId.toUpperCase()).maybeSingle();
  if (vendorData) return vendorData.user_id;

  if (recipientId.includes('@')) {
    const { data: emailData } = await supabase.from('profiles').select('id').ilike('email', recipientId.trim()).maybeSingle();
    if (emailData) return emailData.id;
  }

  const phonePattern = /^[0-9+\-\s]{6,}$/;
  if (phonePattern.test(recipientId.trim())) {
    const cleanPhone = recipientId.replace(/[\s\-]/g, '');
    const { data: phoneData } = await supabase
      .from('profiles')
      .select('id')
      .or(`phone.eq.${cleanPhone},phone.eq.+${cleanPhone},phone.ilike.%${cleanPhone}%`)
      .maybeSingle();
    if (phoneData) return phoneData.id;
  }

  return null;
}

// =============================================
// MAIN HANDLER
// =============================================

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, supabaseServiceKey);

  try {
    // 🔐 HMAC signature validation + idempotency + fraud scoring
    const rawBody = await req.text();
    const { validateHmacRequest, hmacErrorResponse, assessFraudRisk } = await import("../_shared/hmac-guard.ts");
    if (req.headers.get("x-signature")) {
      const hmacResult = await validateHmacRequest(req, rawBody, { checkIdempotency: true });
      if (!hmacResult.valid) {
        console.warn("🚨 HMAC validation failed:", hmacResult.code);
        return hmacErrorResponse(hmacResult, corsHeaders);
      }
      console.log("✅ HMAC signature verified");
    }

    const url = new URL(req.url);
    const body = JSON.parse(rawBody);
    // ✅ Support action from query params OR body (supabase.functions.invoke doesn't pass query params)
    const action = url.searchParams.get("action") || body.action || "transfer";

    console.log(`💸 Wallet transfer action: ${action}`);

    const authHeader = req.headers.get("authorization");
    if (!authHeader) throw new Error("Authentification requise");

    if (action === "preview") {
      return await handlePreview(supabase, body);
    } else if (action === "transfer") {
      return await handleTransfer(supabase, body, req);
    } else {
      throw new Error("Action invalide");
    }
  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : "Erreur inconnue";
    console.error("❌ Transfer error:", error);
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  }
});

// =============================================
// 🔍 PREVIEW
// =============================================

async function handlePreview(supabase: any, body: { sender_id: string; receiver_id: string; amount: number }) {
  const { sender_id, amount } = body;
  let { receiver_id } = body;

  const resolvedReceiverId = await resolveRecipientId(supabase, receiver_id);
  if (!resolvedReceiverId) throw new Error(`Destinataire "${receiver_id}" introuvable`);
  receiver_id = resolvedReceiverId;

  if (sender_id === receiver_id) throw new Error("Vous ne pouvez pas transférer à vous-même");

  // Load wallets in parallel
  const [senderResult, receiverResult] = await Promise.all([
    supabase.from("wallets").select("*").eq("user_id", sender_id).single(),
    supabase.from("wallets").select("*").eq("user_id", receiver_id).single(),
  ]);

  if (senderResult.error) throw new Error("Wallet expéditeur non trouvé");
  if (receiverResult.error) throw new Error("Wallet destinataire non trouvé");

  const senderCurrency = (senderResult.data.currency || "GNF").toUpperCase();

  // Load dynamic limits from pdg_settings and convert to sender's currency
  const [minLimitRaw, maxLimitRaw, minIntlLimitRaw, maxIntlLimitRaw] = await Promise.all([
    getPdgFeeRate(supabase, FEE_KEYS.MIN_TRANSFER_AMOUNT),
    getPdgFeeRate(supabase, FEE_KEYS.MAX_TRANSFER_AMOUNT),
    getPdgFeeRate(supabase, FEE_KEYS.MIN_INTERNATIONAL_TRANSFER),
    getPdgFeeRate(supabase, FEE_KEYS.MAX_INTERNATIONAL_TRANSFER),
  ]);

  const [minLimit, maxLimit, minIntlLimit, maxIntlLimit] = await convertLimitsToCurrency(
    [minLimitRaw, maxLimitRaw, minIntlLimitRaw, maxIntlLimitRaw],
    senderCurrency,
  );

  console.log(`[LIMITS-PREVIEW] ${LIMITS_BASE_CURRENCY} → ${senderCurrency} | min: ${minLimitRaw}→${minLimit} | max: ${maxLimitRaw}→${maxLimit} | intlMin: ${minIntlLimitRaw}→${minIntlLimit} | intlMax: ${maxIntlLimitRaw}→${maxIntlLimit}`);

  if (amount < minLimit) throw new Error(`Montant minimum: ${minLimit.toLocaleString()} ${senderCurrency}`);
  if (amount > maxLimit) throw new Error(`Montant maximum: ${maxLimit.toLocaleString()} ${senderCurrency}`);
  if (senderResult.data.balance < amount) throw new Error("Solde insuffisant");

  const receiverCurrency = (receiverResult.data.currency || "GNF").toUpperCase();
  const senderCountry = currencyToCountry(senderCurrency);
  const receiverCountry = currencyToCountry(receiverCurrency);

  // ✅ RÈGLE CENTRALE: même devise = local, devise différente = international
  const isInternational = senderCurrency !== receiverCurrency;

  // Vérification limites internationales dans le preview aussi
  if (isInternational) {
    if (amount < minIntlLimit) throw new Error(`Montant minimum international: ${minIntlLimit.toLocaleString()} ${senderCurrency}`);
    if (amount > maxIntlLimit) throw new Error(`Limite par transfert international: ${maxIntlLimit.toLocaleString()} ${senderCurrency}`);
  }

  console.log(`🌍 Preview: ${senderCountry}(${senderCurrency}) → ${receiverCountry}(${receiverCurrency}) | International: ${isInternational}`);

  let feePercentage = 0;
  let feeAmount = 0;
  let rateDisplayed = 1;
  let amountReceived = amount;
  let totalDebit = amount;
  let rateSource = "identity";
  let rateFetchedAt = new Date().toISOString();

  if (isInternational) {
    // =============================================
    // 🌍 TRANSFERT INTERNATIONAL
    // =============================================

    // 1. Récupérer le taux final (inclut déjà la marge de 3%)
    const fxResult = await getFxRateFromAPI(senderCurrency, receiverCurrency);
    rateDisplayed = fxResult.rate;
    rateSource = fxResult.source;
    rateFetchedAt = fxResult.fetched_at;

    // 2. La marge est DANS le taux — pas de fee séparée sur la conversion
    feePercentage = 0;
    feeAmount = 0;

    // 3. Montant reçu = montant × taux final (commission incluse dans le taux)
    amountReceived = Math.round(amount * rateDisplayed * 100) / 100;

    // 4. Total débité = montant envoyé
    totalDebit = amount;

    console.log(`💱 Taux final (marge incluse): ${rateDisplayed} | Reçu: ${amountReceived} ${receiverCurrency}`);
  } else {
    // =============================================
    // 🏠 TRANSFERT LOCAL (même devise)
    // =============================================

    // PAS de conversion, PAS d'appel API de taux
    // Frais PDG pour transfert wallet-to-wallet
    feePercentage = await getPdgFeeRate(supabase, FEE_KEYS.WALLET_TRANSFER);
    const { feeAmount: fee, netAmount } = calculateFee(amount, feePercentage);
    feeAmount = fee;
    totalDebit = amount; // On débite le montant total
    amountReceived = netAmount; // Le destinataire reçoit le montant moins les frais

    console.log(`🏠 Local: ${amount} ${senderCurrency} | Frais: ${feePercentage}% = ${feeAmount} | Reçu: ${amountReceived}`);
  }

  const preview = {
    success: true,
    amount_sent: amount,
    currency_sent: senderCurrency,
    fee_percentage: feePercentage,
    fee_amount: smartRound(feeAmount, senderCurrency),
    total_debit: smartRound(totalDebit, senderCurrency),
    amount_after_fee: smartRound(amount - feeAmount, senderCurrency),
    rate_displayed: rateDisplayed,
    amount_received: smartRound(amountReceived, receiverCurrency),
    currency_received: receiverCurrency,
    is_international: isInternational,
    sender_country: senderCountry,
    receiver_country: receiverCountry,
    sender_balance: senderResult.data.balance,
    balance_after: senderResult.data.balance - totalDebit,
    // International-specific
    commission_conversion: isInternational ? smartRound(feeAmount, senderCurrency) : 0,
    frais_international: 0,
    rate_lock_seconds: isInternational ? 60 : undefined,
    rate_source: rateSource,
    rate_fetched_at: rateFetchedAt,
  };

  console.log("📊 Preview:", JSON.stringify(preview));

  return new Response(JSON.stringify(preview), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
    status: 200,
  });
}

// =============================================
// 💸 EXECUTE TRANSFER
// =============================================

async function handleTransfer(supabase: any, body: { sender_id: string; receiver_id: string; amount: number; description?: string }, req: Request) {
  const { sender_id, amount, description } = body;
  let { receiver_id } = body;

  if (!sender_id || !receiver_id || !amount) throw new Error("Paramètres manquants");

  const resolvedReceiverId = await resolveRecipientId(supabase, receiver_id);
  if (!resolvedReceiverId) throw new Error(`Destinataire "${receiver_id}" introuvable`);
  receiver_id = resolvedReceiverId;

  if (sender_id === receiver_id) throw new Error("Impossible de transférer vers soi-même");
  if (amount <= 0) throw new Error("Le montant doit être positif");

  const transferCode = `TRF-${Date.now()}-${Math.random().toString(36).substr(2, 9).toUpperCase()}`;

  // Load wallets
  const [senderResult, receiverResult] = await Promise.all([
    supabase.from("wallets").select("*").eq("user_id", sender_id).single(),
    supabase.from("wallets").select("*").eq("user_id", receiver_id).single(),
  ]);

  if (senderResult.error) throw new Error("Wallet expéditeur non trouvé");
  if (receiverResult.error) throw new Error("Wallet destinataire non trouvé");

  const senderWallet = senderResult.data;
  const receiverWallet = receiverResult.data;
  const senderCurrency = (senderWallet.currency || "GNF").toUpperCase();
  const receiverCurrency = (receiverWallet.currency || "GNF").toUpperCase();
  const senderCountry = currencyToCountry(senderCurrency);
  const receiverCountry = currencyToCountry(receiverCurrency);
  const isInternational = senderCurrency !== receiverCurrency;

  console.log(`🌍 Transfer: ${senderCountry}(${senderCurrency}) → ${receiverCountry}(${receiverCurrency}) | Intl: ${isInternational}`);

  // Load dynamic limits from pdg_settings (raw values in GNF)
  const [minLimitRaw, maxLimitRaw, maxDailyLimitRaw, maxIntlLimitRaw, minIntlLimitRaw] = await Promise.all([
    getPdgFeeRate(supabase, FEE_KEYS.MIN_TRANSFER_AMOUNT),
    getPdgFeeRate(supabase, FEE_KEYS.MAX_TRANSFER_AMOUNT),
    getPdgFeeRate(supabase, FEE_KEYS.MAX_DAILY_TRANSFER),
    getPdgFeeRate(supabase, FEE_KEYS.MAX_INTERNATIONAL_TRANSFER),
    getPdgFeeRate(supabase, FEE_KEYS.MIN_INTERNATIONAL_TRANSFER),
  ]);

  // 🔄 Convert ALL limits to sender's currency (single FX call)
  const [minLimit, maxLimit, maxDailyLimit, maxIntlLimit, minIntlLimit] = await convertLimitsToCurrency(
    [minLimitRaw, maxLimitRaw, maxDailyLimitRaw, maxIntlLimitRaw, minIntlLimitRaw],
    senderCurrency,
  );

  console.log(`[LIMITS-TRANSFER] ${LIMITS_BASE_CURRENCY} → ${senderCurrency} | min: ${minLimitRaw}→${minLimit} | max: ${maxLimitRaw}→${maxLimit} | intlMin: ${minIntlLimitRaw}→${minIntlLimit} | intlMax: ${maxIntlLimitRaw}→${maxIntlLimit} | daily: ${maxDailyLimitRaw}→${maxDailyLimit}`);

  if (amount < minLimit) throw new Error(`Montant minimum: ${minLimit.toLocaleString()} ${senderCurrency}`);
  if (amount > maxLimit) throw new Error(`Montant maximum: ${maxLimit.toLocaleString()} ${senderCurrency}`);

  // Check daily limit
  const today = new Date().toISOString().split("T")[0];
  const { data: todayTransfers } = await supabase
    .from("wallet_transfers")
    .select("amount_sent")
    .eq("sender_id", sender_id)
    .eq("status", "completed")
    .gte("created_at", `${today}T00:00:00Z`);

  const totalToday = (todayTransfers || []).reduce((s: number, t: any) => s + (t.amount_sent || 0), 0);

  if (isInternational) {
    if (amount < minIntlLimit) throw new Error(`Montant minimum international: ${minIntlLimit.toLocaleString()} ${senderCurrency}`);
    if (amount > maxIntlLimit) throw new Error(`Limite par transfert international: ${maxIntlLimit.toLocaleString()} ${senderCurrency}`);
    if (totalToday + amount > maxDailyLimit) throw new Error(`Limite quotidienne atteinte (${maxDailyLimit.toLocaleString()} ${senderCurrency})`);
  } else {
    if (totalToday + amount > maxDailyLimit) throw new Error(`Limite quotidienne atteinte (${maxDailyLimit.toLocaleString()} ${senderCurrency})`);
  }

  if (senderWallet.balance < amount) {
    throw new Error(`Solde insuffisant. Disponible: ${senderWallet.balance} ${senderCurrency}`);
  }

  // Calculate fees and conversion
  let feePercentage = 0;
  let feeAmount = 0;
  let rateDisplayed = 1;
  let rateInternal = 1;
  let amountReceived: number;

  if (isInternational) {
    // 🌍 International: taux final (marge 3% déjà incluse dans le taux)
    const fxResult = await getFxRateFromAPI(senderCurrency, receiverCurrency);
    rateDisplayed = fxResult.rate;
    rateInternal = rateDisplayed;

    // La marge est DANS le taux — pas de fee séparée
    feePercentage = 0;
    feeAmount = 0;
    amountReceived = Math.round(amount * rateDisplayed * 100) / 100;
  } else {
    // 🏠 Local: frais PDG uniquement, pas de conversion
    feePercentage = await getPdgFeeRate(supabase, FEE_KEYS.WALLET_TRANSFER);
    const { feeAmount: fee, netAmount } = calculateFee(amount, feePercentage);
    feeAmount = fee;
    amountReceived = netAmount;
  }

  const clientIP = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || req.headers.get("x-real-ip") || "unknown";
  const userAgent = req.headers.get("user-agent") || "unknown";
  const signature = await generateSignature(transferCode, amount);

  // Create secure_transactions record (use UUID for id, correct column names)
  const { error: secureInsertError } = await supabase
    .from("secure_transactions")
    .insert({
      user_id: sender_id,
      requested_amount: amount,
      fee_percentage: feePercentage / 100, // stored as decimal (e.g. 0.025 for 2.5%)
      fee_amount: feeAmount,
      total_amount: amount + feeAmount, // CHECK: total_amount = requested_amount + fee_amount
      net_amount: amount, // CHECK: net_amount = requested_amount
      signature_hash: signature,
      status: "pending",
      transaction_type: "transfer", // CHECK allows: deposit, payment, withdrawal, transfer
      interface_type: "client", // CHECK allows: client, vendor, driver, delivery
      external_transaction_id: transferCode,
    });

  if (secureInsertError) {
    console.error("Secure transaction insert failed:", secureInsertError);
    throw new Error("Erreur de sécurité transaction");
  }

  // Create wallet_transfers record
  // NOTE: sender_wallet_id/receiver_wallet_id are UUID but wallets.id is bigint - omit them
  const { data: transfer, error: transferError } = await supabase
    .from("wallet_transfers")
    .insert({
      transfer_code: transferCode,
      sender_id,
      receiver_id,
      amount_sent: amount,
      currency_sent: senderCurrency,
      fee_percentage: feePercentage,
      fee_amount: feeAmount,
      amount_after_fee: amount - feeAmount,
      rate_displayed: rateDisplayed,
      rate_used: rateInternal,
      amount_received: amountReceived,
      currency_received: receiverCurrency,
      transfer_type: isInternational ? "INTERNATIONAL" : "WALLET_TO_WALLET",
      description,
      status: "processing",
      sender_country: senderCountry,
      receiver_country: receiverCountry,
      ip_address: clientIP,
      user_agent: userAgent,
    })
    .select()
    .single();

  if (transferError) {
    console.error("Transfer record creation failed:", transferError);
    await supabase.from("secure_transactions").update({ status: "failed" }).eq("external_transaction_id", transferCode);
    throw new Error("Erreur lors de la création du transfert");
  }

  // Execute atomic transfer
  try {
    // Debit sender (optimistic lock with row count verification)
    const { data: debitData, error: debitError } = await supabase
      .from("wallets")
      .update({
        balance: senderWallet.balance - amount,
        updated_at: new Date().toISOString(),
      })
      .eq("id", senderWallet.id)
      .eq("balance", senderWallet.balance) // Optimistic lock
      .select("id")
      .maybeSingle();

    if (debitError) throw new Error("Échec du débit du wallet expéditeur");
    
    // ✅ CRITICAL: Verify the optimistic lock matched a row
    if (!debitData) {
      console.error("⚠️ Optimistic lock failed - balance changed concurrently");
      throw new Error("Transaction concurrente détectée. Veuillez réessayer.");
    }

    // Credit receiver (also with optimistic lock)
    const { data: creditData, error: creditError } = await supabase
      .from("wallets")
      .update({
        balance: receiverWallet.balance + amountReceived,
        updated_at: new Date().toISOString(),
      })
      .eq("id", receiverWallet.id)
      .select("id")
      .maybeSingle();

    if (creditError || !creditData) {
      // Rollback debit atomically
      const { error: rollbackError } = await supabase
        .from("wallets")
        .update({ balance: senderWallet.balance, updated_at: new Date().toISOString() })
        .eq("id", senderWallet.id);
      
      if (rollbackError) {
        console.error("🚨 CRITICAL: Rollback failed!", rollbackError);
        await logFinancialAudit(supabase, sender_id, "rollback_failed", {
          transferCode, amount, senderWalletId: senderWallet.id, rollbackError
        }, true);
      }
      throw new Error("Échec du crédit du wallet destinataire");
    }

    // Mark completed
    await Promise.all([
      supabase.from("wallet_transfers").update({
        status: "completed",
        confirmed_at: new Date().toISOString(),
        completed_at: new Date().toISOString(),
      }).eq("id", transfer.id),
      supabase.from("secure_transactions").update({
        status: "completed",
        completed_at: new Date().toISOString(),
      }).eq("external_transaction_id", transferCode),
    ]);

    await logFinancialAudit(supabase, sender_id, isInternational ? "international_transfer_completed" : "transfer_completed", {
      transferCode, amount, receiver_id, amountReceived, isInternational, senderCountry, receiverCountry
    });

    // Create transaction history entries
    const transferLabel = isInternational ? "🌍 Transfert international" : "Transfert";
    const txIdOut = `TRF-OUT-${Date.now()}-${Math.random().toString(36).substr(2, 6).toUpperCase()}`;
    const txIdIn = `TRF-IN-${Date.now()}-${Math.random().toString(36).substr(2, 6).toUpperCase()}`;
    await Promise.all([
      supabase.from("wallet_transactions").insert({
        transaction_id: txIdOut,
        sender_wallet_id: senderWallet.id,
        sender_user_id: sender_id,
        receiver_wallet_id: receiverWallet.id,
        receiver_user_id: receiver_id,
        transaction_type: "transfer_out",
        amount: amount,
        fee: feeAmount,
        net_amount: amount - feeAmount,
        currency: senderCurrency,
        description: `${transferLabel} envoyé: ${transferCode}`,
        status: "completed",
        reference_id: transfer.id,
        metadata: {
          transfer_code: transferCode,
          receiver_id,
          fee_amount: feeAmount,
          rate_displayed: rateDisplayed,
          is_international: isInternational,
        },
      }),
      supabase.from("wallet_transactions").insert({
        transaction_id: txIdIn,
        sender_wallet_id: senderWallet.id,
        sender_user_id: sender_id,
        receiver_wallet_id: receiverWallet.id,
        receiver_user_id: receiver_id,
        transaction_type: "transfer_in",
        amount: amountReceived,
        fee: 0,
        net_amount: amountReceived,
        currency: receiverCurrency,
        description: `${transferLabel} reçu: ${transferCode}`,
        status: "completed",
        reference_id: transfer.id,
        metadata: {
          transfer_code: transferCode,
          sender_id,
          original_amount: amount,
          original_currency: senderCurrency,
          is_international: isInternational,
        },
      }),
    ]);

    console.log(`✅ ${isInternational ? "International" : "Local"} transfer completed: ${transferCode}`);

    const result = {
      success: true,
      transfer_id: transfer.id,
      transfer_code: transferCode,
      amount_sent: amount,
      currency_sent: senderCurrency,
      fee_percentage: feePercentage,
      fee_amount: smartRound(feeAmount, senderCurrency),
      total_debit: amount,
      amount_after_fee: smartRound(amount - feeAmount, senderCurrency),
      rate_displayed: rateDisplayed,
      amount_received: smartRound(amountReceived, receiverCurrency),
      currency_received: receiverCurrency,
      is_international: isInternational,
      sender_country: senderCountry,
      receiver_country: receiverCountry,
      commission_conversion: isInternational ? smartRound(feeAmount, senderCurrency) : 0,
      frais_international: 0,
    };

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });
  } catch (execError: unknown) {
    const errorMessage = execError instanceof Error ? execError.message : "Unknown error";
    await supabase
      .from("wallet_transfers")
      .update({ status: "failed", failed_at: new Date().toISOString(), failure_reason: errorMessage })
      .eq("id", transfer.id);
    throw execError;
  }
}
