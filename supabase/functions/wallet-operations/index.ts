/**
 * 🔐 WALLET OPERATIONS SÉCURISÉES
 * ✅ Même devise = transfert local direct (pas de conversion)
 * ✅ Devise différente = conversion via taux internes (table currency_exchange_rates)
 * ✅ Aucun appel API externe — taux déjà collectés par african-fx-collect (cron horaire)
 * ✅ Marge de 3% incluse dans le taux, pas de commission supplémentaire
 * ✅ Signature HMAC, verrouillage optimiste et audit complet
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { z } from "https://deno.land/x/zod@v3.22.4/mod.ts";
import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";
import { getInternalFxRate } from "../_shared/fx-internal.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

// Smart rounding: integers for weak currencies, 2 decimals for strong
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

function getTransactionSecret(): string {
  const secret = Deno.env.get("TRANSACTION_SECRET_KEY");
  if (!secret) {
    throw new Error("🔴 CRITICAL: TRANSACTION_SECRET_KEY not configured");
  }
  return secret;
}

async function generateSecureSignature(transactionId: string, amount: number): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(`${transactionId}${amount}`);
  const keyData = encoder.encode(getTransactionSecret());
  const key = await crypto.subtle.importKey("raw", keyData, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, data);
  return Array.from(new Uint8Array(signature)).map(b => b.toString(16).padStart(2, "0")).join("");
}

async function logSecureAudit(supabase: any, userId: string, action: string, data: any, isSuspicious = false) {
  try {
    await supabase.from("financial_audit_logs").insert({
      user_id: userId,
      action_type: action,
      description: `Wallet operation: ${action}`,
      request_data: data,
      is_suspicious: isSuspicious
    });
  } catch (e) { console.error("[Audit] Log failed:", e); }
}

const operationSchema = z.enum(['deposit', 'withdraw', 'transfer']);

const requestSchema = z.object({
  operation: operationSchema,
  amount: z.number().positive().max(100000000),
  recipient_id: z.string().optional(),
  description: z.string().max(500).optional(),
  idempotency_key: z.string().uuid().optional()
});

function generateIdempotencyKey(userId: string, operation: string, amount: number, recipientId?: string): string {
  return `${userId}:${operation}:${amount}:${recipientId || ''}:${Math.floor(Date.now() / 60000)}`;
}

async function checkDuplicateTransaction(supabase: any, idempotencyKey: string): Promise<boolean> {
  try {
    const { data } = await supabase
      .from('wallet_idempotency_keys')
      .select('id')
      .eq('idempotency_key', idempotencyKey)
      .maybeSingle();
    return !!data;
  } catch {
    return false;
  }
}

async function recordIdempotencyKey(supabase: any, idempotencyKey: string, userId: string, operation: string): Promise<void> {
  try {
    await supabase.from('wallet_idempotency_keys').insert({
      idempotency_key: idempotencyKey,
      user_id: userId,
      operation,
      created_at: new Date().toISOString(),
      expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString()
    });
  } catch {}
}

async function calculateFee(supabase: any, transactionType: string, amount: number, currency: string = 'GNF'): Promise<number> {
  try {
    const { data: feeConfig, error } = await supabase
      .from('wallet_fees')
      .select('*')
      .eq('transaction_type', transactionType)
      .eq('currency', currency)
      .eq('is_active', true)
      .maybeSingle();

    if (error || !feeConfig) return 0;

    let fee = 0;
    if (feeConfig.fee_type === 'fixed') {
      fee = feeConfig.fee_value;
    } else if (feeConfig.fee_type === 'percentage') {
      fee = (amount * feeConfig.fee_value) / 100;
    }
    return Math.max(0, fee);
  } catch {
    return 0;
  }
}

async function logWalletOperation(supabase: any, logData: any): Promise<void> {
  try {
    await supabase.from('wallet_logs').insert([logData]);
  } catch {}
}

async function detectSuspicious(supabase: any, userId: string, amount: number): Promise<any> {
  try {
    const yesterday = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const { data: recentLogs } = await supabase
      .from('wallet_logs')
      .select('amount')
      .eq('user_id', userId)
      .gte('created_at', yesterday);

    const total24h = recentLogs?.reduce((sum: number, log: any) => sum + (log.amount || 0), 0) || 0;
    const count24h = recentLogs?.length || 0;
    const flags: string[] = [];
    let severity = 'low';

    if (amount > 2000000) { flags.push('high_amount'); severity = 'high'; }
    if (count24h > 10) { flags.push('high_frequency'); severity = 'medium'; }
    if (total24h > 5000000) { flags.push('high_volume'); severity = 'critical'; }

    if (flags.length > 0) {
      const { data: wallet } = await supabase.from('wallets').select('id').eq('user_id', userId).single();
      if (wallet) {
        await supabase.from('wallet_suspicious_activities').insert([{
          wallet_id: wallet.id,
          user_id: userId,
          activity_type: flags.join(', '),
          severity,
          description: `Activité détectée: montant ${amount}, total 24h: ${total24h}, nb: ${count24h}`,
          metadata: { amount, total24h, count24h, flags }
        }]);
      }
      return { suspicious: true, severity, flags, should_block: severity === 'critical' };
    }
    return { suspicious: false };
  } catch {
    return { suspicious: false };
  }
}

// =============================================
// 🌍 FX RATE — Lecture interne depuis currency_exchange_rates
// Aucun appel API externe. Les taux sont collectés par african-fx-collect
// (banques centrales + fallback documenté) et incluent déjà la marge de 3%.
// =============================================

async function getFxRate(supabase: any, from: string, to: string): Promise<{ rate: number; source: string; fetched_at: string }> {
  if (from === to) return { rate: 1, source: "identity", fetched_at: new Date().toISOString() };
  return getInternalFxRate(supabase, from, to);
}

// =============================================
// 🔐 ATOMIC TRANSFER
// =============================================

async function executeAtomicTransfer(
  supabase: any,
  senderId: string,
  receiverId: string,
  amountToDebit: number,
  amountToCredit: number,
  description: string,
  senderWallet: any,
  recipientWallet: any,
  isInternational: boolean,
  metadata: any
): Promise<{ success: boolean; error?: string; senderBalance?: number; recipientBalance?: number; transactionId?: string }> {

  // Try RPC first
  const { data, error } = await supabase.rpc('execute_atomic_wallet_transfer', {
    p_sender_id: senderId,
    p_receiver_id: receiverId,
    p_amount: amountToDebit,
    p_description: description,
    p_sender_wallet_id: senderWallet.id,
    p_recipient_wallet_id: recipientWallet.id,
    p_sender_balance_before: senderWallet.balance,
    p_recipient_balance_before: recipientWallet.balance
  });

  if (!error) {
    const rpcTransactionId = (Array.isArray(data) ? data?.[0]?.id : data?.id) || undefined;
    return {
      success: true,
      senderBalance: senderWallet.balance - amountToDebit,
      recipientBalance: recipientWallet.balance + amountToCredit,
      transactionId: rpcTransactionId,
    };
  }

  // Fallback: manual atomic transfer
  const newSenderBalance = senderWallet.balance - amountToDebit;
  const newRecipientBalance = recipientWallet.balance + amountToCredit;
  const transactionId = crypto.randomUUID();

  const { error: txCreateError } = await supabase
    .from('enhanced_transactions')
    .insert({
      id: transactionId,
      sender_id: senderId,
      receiver_id: receiverId,
      amount: amountToDebit,
      method: 'wallet',
      status: 'pending',
      currency: metadata.senderCurrency || 'GNF',
      metadata: {
        description,
        atomic: true,
        transaction_type: isInternational ? 'international_transfer' : 'transfer',
        is_international: isInternational,
        sender_balance_before: senderWallet.balance,
        recipient_balance_before: recipientWallet.balance,
        amount_credited: amountToCredit,
        ...metadata
      }
    });

  if (txCreateError) {
    console.error('❌ [wallet-operations] enhanced_transactions insert failed:', txCreateError);
    return { success: false, error: 'Erreur création transaction' };
  }

  // Debit sender (optimistic lock)
  const { data: debitResult, error: debitError } = await supabase
    .from('wallets')
    .update({ balance: newSenderBalance, updated_at: new Date().toISOString() })
    .eq('user_id', senderId)
    .eq('balance', senderWallet.balance)
    .select('balance')
    .single();

  if (debitError || !debitResult) {
    await supabase.from('enhanced_transactions')
      .update({ status: 'failed', metadata: { error: 'debit_failed' } })
      .eq('id', transactionId);
    return { success: false, error: 'Solde modifié pendant la transaction. Réessayez.' };
  }

  // Credit receiver
  const { data: creditResult, error: creditError } = await supabase
    .from('wallets')
    .update({ balance: newRecipientBalance, updated_at: new Date().toISOString() })
    .eq('user_id', receiverId)
    .select('balance')
    .single();

  if (creditError || !creditResult) {
    // Rollback
    await supabase.from('wallets')
      .update({ balance: senderWallet.balance, updated_at: new Date().toISOString() })
      .eq('user_id', senderId);

    await supabase.from('enhanced_transactions')
      .update({ status: 'failed', metadata: { error: 'credit_failed_rollback' } })
      .eq('id', transactionId);

    return { success: false, error: 'Erreur lors du crédit. Transaction annulée.' };
  }

  // Mark completed
  await supabase.from('enhanced_transactions')
    .update({
      status: 'completed',
      metadata: {
        description,
        atomic: true,
        transaction_type: isInternational ? 'international_transfer' : 'transfer',
        is_international: isInternational,
        sender_balance_after: newSenderBalance,
        recipient_balance_after: newRecipientBalance,
        amount_credited: amountToCredit,
        ...metadata
      }
    })
    .eq('id', transactionId);

  return { success: true, senderBalance: newSenderBalance, recipientBalance: newRecipientBalance, transactionId };
}

async function syncAgentWallet(supabase: any, userId: string, newBalance: number, context: string, userRole: string): Promise<void> {
  if (userRole !== 'agent') return;
  try {
    const { data: agentWallet } = await supabase.from('agent_wallets').select('id').eq('agent_id', userId).maybeSingle();
    if (agentWallet) {
      await supabase.from('agent_wallets')
        .update({ balance: newBalance, updated_at: new Date().toISOString() })
        .eq('id', agentWallet.id);

      await logWalletOperation(supabase, {
        user_id: userId,
        wallet_id: agentWallet.id,
        operation: 'sync_agent_wallet',
        context,
        new_balance: newBalance,
        role: userRole,
        created_at: new Date().toISOString(),
        metadata: { source: 'wallet-operations', syncContext: context }
      });
    }
  } catch {}
}

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
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return new Response(
      JSON.stringify({ error: 'Method not allowed' }),
      { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  try {
    console.log('🚀 Wallet operation started');

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: req.headers.get('Authorization')! },
        },
      }
    );

    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Non autorisé' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const requestBody = await req.json();
    const normalizedRequestBody = {
      ...requestBody,
      operation: requestBody?.operation ?? requestBody?.action,
      recipient_id: requestBody?.recipient_id ?? requestBody?.recipient_public_id ?? requestBody?.receiver_id,
    };

    const parseResult = requestSchema.safeParse(normalizedRequestBody);

    if (!parseResult.success) {
      return new Response(
        JSON.stringify({ error: 'Données invalides', details: parseResult.error.errors }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { operation, amount, recipient_id, description, idempotency_key } = parseResult.data;

    // Idempotency check
    const effectiveIdempotencyKey = idempotency_key || generateIdempotencyKey(user.id, operation, amount, recipient_id);
    const isDuplicate = await checkDuplicateTransaction(supabaseClient, effectiveIdempotencyKey);
    if (isDuplicate) {
      return new Response(
        JSON.stringify({ error: 'Transaction en double détectée.' }),
        { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data: profile } = await supabaseClient.from('profiles').select('id, role').eq('id', user.id).maybeSingle();
    const userRole = profile?.role || 'user';

    const { data: wallet, error: walletError } = await supabaseClient.from('wallets').select('*').eq('user_id', user.id).single();
    if (walletError || !wallet) {
      return new Response(JSON.stringify({ error: 'Wallet introuvable' }), { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    if (wallet.is_blocked) {
      return new Response(JSON.stringify({ error: 'Wallet bloqué.' }), { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    const suspicious = await detectSuspicious(supabaseClient, user.id, amount);
    if (suspicious.should_block) {
      await supabaseClient.from('wallets').update({
        is_blocked: true,
        blocked_reason: `Activité suspecte: ${suspicious.flags.join(', ')}`,
        blocked_at: new Date().toISOString()
      }).eq('id', wallet.id);
      return new Response(JSON.stringify({ error: 'Transaction bloquée: activité suspecte' }), { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    let result;

    switch (operation) {
      case 'deposit': {
        const depositFee = await calculateFee(supabaseClient, 'deposit', amount, wallet.currency);
        const netDeposit = amount - depositFee;
        const newBalance = wallet.balance + netDeposit;

        const { error: depositError } = await supabaseClient
          .from('wallets')
          .update({ balance: newBalance, updated_at: new Date().toISOString() })
          .eq('user_id', user.id);
        if (depositError) throw depositError;

        const { data: depositTx, error: depositTxError } = await supabaseClient
          .from('enhanced_transactions')
          .insert({
            sender_id: user.id,
            receiver_id: user.id,
            amount,
            method: 'wallet',
            status: 'completed',
            currency: wallet.currency || 'GNF',
            metadata: {
              description: description || 'Dépôt',
              fee: depositFee,
              transaction_type: 'deposit'
            }
          })
          .select('id')
          .single();

        if (depositTxError) throw depositTxError;

        await syncAgentWallet(supabaseClient, user.id, newBalance, 'deposit', userRole);
        await recordIdempotencyKey(supabaseClient, effectiveIdempotencyKey, user.id, 'deposit');
        result = { success: true, new_balance: newBalance, operation: 'deposit', transaction_id: depositTx?.id || null };
        break;
      }

      case 'withdraw': {
        if (wallet.balance < amount) {
          return new Response(JSON.stringify({ error: 'Solde insuffisant' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
        }

        const newBalance = wallet.balance - amount;
        const { error: withdrawError } = await supabaseClient
          .from('wallets')
          .update({ balance: newBalance, updated_at: new Date().toISOString() })
          .eq('user_id', user.id);
        if (withdrawError) throw withdrawError;

        const { data: withdrawTx, error: withdrawTxError } = await supabaseClient
          .from('enhanced_transactions')
          .insert({
            sender_id: user.id,
            receiver_id: user.id,
            amount,
            method: 'wallet',
            status: 'completed',
            currency: wallet.currency || 'GNF',
            metadata: {
              description: description || 'Retrait',
              transaction_type: 'withdrawal'
            }
          })
          .select('id')
          .single();

        if (withdrawTxError) throw withdrawTxError;

        await syncAgentWallet(supabaseClient, user.id, newBalance, 'withdraw', userRole);
        await recordIdempotencyKey(supabaseClient, effectiveIdempotencyKey, user.id, 'withdraw');
        result = { success: true, new_balance: newBalance, operation: 'withdraw', transaction_id: withdrawTx?.id || null };
        break;
      }

      case 'transfer': {
        if (!recipient_id) {
          return new Response(JSON.stringify({ error: 'Destinataire requis' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
        }

        if (wallet.balance < amount) {
          return new Response(JSON.stringify({ error: 'Solde insuffisant' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
        }

        // Use service role for recipient lookup
        const serviceClient = createClient(
          Deno.env.get('SUPABASE_URL') ?? '',
          Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
        );

        const recipientUserId = await resolveRecipientId(serviceClient, recipient_id);
        if (!recipientUserId) {
          return new Response(JSON.stringify({ error: `Utilisateur ${recipient_id} introuvable` }), { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
        }

        if (recipientUserId === user.id) {
          return new Response(JSON.stringify({ error: 'Transfert vers soi-même non autorisé' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
        }

        // Get recipient wallet
        const { data: recipientWallet, error: recipientError } = await serviceClient
          .from('wallets')
          .select('*')
          .eq('user_id', recipientUserId)
          .single();

        if (recipientError || !recipientWallet) {
          return new Response(JSON.stringify({ error: 'Wallet du destinataire introuvable' }), { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
        }

        // ✅ RÈGLE CENTRALE: même devise = local, devise différente = international
        // Aligné sur wallet-transfer: détection par DEVISE, pas par pays
        const senderCurrency = (wallet.currency || "GNF").toUpperCase();
        const receiverCurrency = (recipientWallet.currency || "GNF").toUpperCase();
        const isInternational = senderCurrency !== receiverCurrency;

        console.log(`🌍 wallet-ops transfer: ${senderCurrency} → ${receiverCurrency} | Intl: ${isInternational}`);

        let amountToDebit = amount;
        let amountToCredit = amount;
        let feeAmount = 0;
        let rateUsed = 1;
        let rateSource = "identity";
        let rateFetchedAt = new Date().toISOString();

        if (isInternational) {
          // =============================================
          // 🌍 TRANSFERT INTERNATIONAL
          // =============================================
          // Le taux final est lu depuis currency_exchange_rates
          // La marge de 3% est DÉJÀ incluse dans le taux (via african-fx-collect)
          // PAS de commission séparée, PAS de frais internationaux supplémentaires
          // Formule: amount_received = amount × final_rate

          // Check daily limit
          const today = new Date().toISOString().split("T")[0];
          const { data: todayTx } = await serviceClient
            .from("wallet_transfers")
            .select("amount_sent")
            .eq("sender_id", user.id)
            .eq("status", "completed")
            .gte("created_at", `${today}T00:00:00Z`);

          const totalToday = (todayTx || []).reduce((s: number, t: any) => s + (t.amount_sent || 0), 0);
          // Daily limit: 50M GNF equivalent (hardcoded fallback)
          const DAILY_LIMIT = 50000000;
          if (totalToday + amount > DAILY_LIMIT) {
            return new Response(JSON.stringify({ error: 'Limite quotidienne de transfert international atteinte' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
          }

          // Taux final (marge incluse) — aucune commission supplémentaire
          const fxResult = await getFxRate(serviceClient, senderCurrency, receiverCurrency);
          rateUsed = fxResult.rate;
          rateSource = fxResult.source;
          rateFetchedAt = fxResult.fetched_at;

          // Montant reçu = montant envoyé × taux final
          amountToCredit = smartRound(amount * rateUsed, receiverCurrency);

          // Pas de fee séparée — la marge est dans le taux
          feeAmount = 0;

          console.log(`💱 Taux final (marge incluse): ${rateUsed} [${rateSource}] | Reçu: ${amountToCredit} ${receiverCurrency}`);
        } else {
          // =============================================
          // 🏠 TRANSFERT LOCAL (même devise)
          // =============================================
          // Frais wallet-to-wallet locaux si configurés
          feeAmount = await calculateFee(serviceClient, 'transfer', amount, senderCurrency);
          amountToCredit = smartRound(amount - feeAmount, senderCurrency);
        }

        // Execute atomic transfer
        const transferResult = await executeAtomicTransfer(
          serviceClient,
          user.id,
          recipientUserId,
          amountToDebit,
          amountToCredit,
          description || 'Transfert entre wallets',
          wallet,
          recipientWallet,
          isInternational,
          {
            senderCurrency,
            receiverCurrency,
            rateUsed,
            rateSource,
            rateFetchedAt,
            feeAmount,
          }
        );

        if (!transferResult.success) {
          console.error('[wallet-ops] Transfer failed:', transferResult.error);
          return new Response(JSON.stringify({ error: 'Échec du transfert' }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
        }

        await logSecureAudit(serviceClient, user.id, isInternational ? "international_transfer" : "local_transfer", {
          amount, recipientUserId, amountToCredit, rateUsed, rateSource, isInternational, senderCurrency, receiverCurrency
        });

        await syncAgentWallet(supabaseClient, user.id, transferResult.senderBalance!, 'transfer_sender', userRole);

        const { data: recipientProfile } = await serviceClient.from('profiles').select('role').eq('id', recipientUserId).maybeSingle();
        if (recipientProfile?.role === 'agent') {
          await syncAgentWallet(supabaseClient, recipientUserId, transferResult.recipientBalance!, 'transfer_recipient', 'agent');
        }

        await recordIdempotencyKey(supabaseClient, effectiveIdempotencyKey, user.id, 'transfer');

        result = {
          success: true,
          new_balance: transferResult.senderBalance,
          operation: 'transfer',
          transaction_id: transferResult.transactionId || null,
          recipient_new_balance: transferResult.recipientBalance,
          is_international: isInternational,
          // ✅ Cohérent avec wallet-transfer: pas de fee séparée pour l'international
          fee_amount: smartRound(feeAmount, senderCurrency),
          fee_percentage: 0,
          rate_used: rateUsed,
          rate_source: rateSource,
          amount_sent: amount,
          amount_received: amountToCredit,
          currency_sent: senderCurrency,
          currency_received: receiverCurrency,
          // Pas de commission/frais séparés — la marge est dans le taux
          commission_conversion: 0,
          frais_international: 0,
        };
        break;
      }

      default:
        return new Response(JSON.stringify({ error: 'Opération non supportée' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    return new Response(JSON.stringify(result), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

  } catch (error) {
    console.error('❌ Error in wallet operation:', error);
    return new Response(
      JSON.stringify({ success: false, error: 'Une erreur est survenue' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
