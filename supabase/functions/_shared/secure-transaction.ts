/**
 * 🔐 MODULE PARTAGÉ: TRANSACTIONS SÉCURISÉES
 * Signature HMAC-SHA256 + Validation + Audit
 * 224Solutions - Règles de sécurité financières absolues
 */

import { crypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";

// Secret partagé pour signature (chargé depuis env)
export const getTransactionSecret = (): string => {
  const secret = Deno.env.get("TRANSACTION_SECRET_KEY");
  if (!secret) {
    throw new Error("🔴 ERREUR CRITIQUE: TRANSACTION_SECRET_KEY non configuré - sécurité compromise");
  }
  return secret;
};

/**
 * 🔐 Génère une signature HMAC-SHA256 pour une transaction
 */
export async function generateTransactionSignature(
  transactionId: string,
  amount: number
): Promise<string> {
  const secret = getTransactionSecret();
  const encoder = new TextEncoder();
  const data = encoder.encode(`${transactionId}${amount}`);
  const keyData = encoder.encode(secret);
  
  const key = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  
  const signature = await crypto.subtle.sign("HMAC", key, data);
  const hashArray = Array.from(new Uint8Array(signature));
  return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
}

/**
 * 🔐 Vérifie une signature HMAC-SHA256
 */
export async function verifyTransactionSignature(
  transactionId: string,
  amount: number,
  providedSignature: string
): Promise<boolean> {
  const expectedSignature = await generateTransactionSignature(transactionId, amount);
  return expectedSignature === providedSignature;
}

/**
 * 🔐 Génère un ID de transaction unique
 */
export function generateSecureTransactionId(prefix: string = "TXN"): string {
  const timestamp = Date.now().toString(36);
  const random = Math.random().toString(36).substring(2, 10);
  return `${prefix}-${timestamp}-${random}`.toUpperCase();
}

/**
 * 🔐 Calcule les frais de transaction (2.5% par défaut)
 */
export function calculateTransactionFees(
  amount: number,
  feeRate: number = 0.025
): { fee: number; netAmount: number; totalAmount: number } {
  const fee = Math.round(amount * feeRate);
  const netAmount = amount;
  const totalAmount = amount + fee;
  
  return { fee, netAmount, totalAmount };
}

/**
 * 🔐 Structure d'une transaction sécurisée
 */
export interface SecureTransaction {
  id: string;
  userId: string;
  requestedAmount: number;
  feeAmount: number;
  totalAmount: number;
  netAmount: number;
  signature: string;
  status: "pending" | "completed" | "failed" | "rejected";
  transactionType: string;
  createdAt: string;
  metadata?: Record<string, unknown>;
}

/**
 * 🔐 Crée une transaction sécurisée immutable
 */
export async function createSecureTransaction(
  supabase: any,
  userId: string,
  amount: number,
  transactionType: string,
  metadata?: Record<string, unknown>
): Promise<{ success: boolean; transaction?: SecureTransaction; error?: string }> {
  try {
    const transactionId = generateSecureTransactionId("SEC");
    const { fee, netAmount, totalAmount } = calculateTransactionFees(amount);
    const signature = await generateTransactionSignature(transactionId, totalAmount);
    
    const transaction: SecureTransaction = {
      id: transactionId,
      userId,
      requestedAmount: amount,
      feeAmount: fee,
      totalAmount,
      netAmount,
      signature,
      status: "pending",
      transactionType,
      createdAt: new Date().toISOString(),
      metadata
    };
    
    // Enregistrer dans secure_transactions
    const { error } = await supabase
      .from("secure_transactions")
      .insert({
        id: transactionId,
        user_id: userId,
        requested_amount: amount,
        fee_amount: fee,
        total_amount: totalAmount,
        net_amount: netAmount,
        signature,
        status: "pending",
        transaction_type: transactionType,
        metadata: metadata || {}
      });
    
    if (error) {
      console.error("[SecureTransaction] Insert error:", error);
      return { success: false, error: error.message };
    }
    
    // Log audit
    await supabase.from("financial_audit_logs").insert({
      user_id: userId,
      action_type: "transaction_created",
      description: `Transaction sécurisée créée: ${transactionType}`,
      request_data: { transactionId, amount, totalAmount, fee },
      is_suspicious: false
    });
    
    console.log(`[SecureTransaction] Created: ${transactionId} - ${amount} GNF`);
    
    return { success: true, transaction };
    
  } catch (error) {
    console.error("[SecureTransaction] Error:", error);
    return { 
      success: false, 
      error: error instanceof Error ? error.message : "Unknown error" 
    };
  }
}

/**
 * 🔐 Valide et complète une transaction sécurisée
 */
export async function validateAndCompleteTransaction(
  supabase: any,
  transactionId: string,
  amountPaid: number,
  externalRef?: string
): Promise<{ success: boolean; error?: string }> {
  try {
    // Récupérer la transaction
    const { data: transaction, error: fetchError } = await supabase
      .from("secure_transactions")
      .select("*")
      .eq("id", transactionId)
      .single();
    
    if (fetchError || !transaction) {
      return { success: false, error: "TRANSACTION_NOT_FOUND" };
    }
    
    // ❌ Vérifier que la transaction est encore PENDING
    if (transaction.status !== "pending") {
      console.warn(`[SecureValidation] Transaction ${transactionId} not pending: ${transaction.status}`);
      return { success: false, error: "TRANSACTION_ALREADY_PROCESSED" };
    }
    
    // ❌ Vérifier le montant exact
    if (Math.abs(amountPaid - transaction.total_amount) > 0.01) {
      console.error(`[SecureValidation] Amount mismatch: paid=${amountPaid}, expected=${transaction.total_amount}`);
      
      await supabase.from("financial_audit_logs").insert({
        user_id: transaction.user_id,
        action_type: "validation_failed",
        description: "Montant payé différent du montant attendu",
        request_data: { transactionId, amountPaid, expected: transaction.total_amount },
        is_suspicious: true,
        security_flags: ["amount_mismatch"]
      });
      
      // Marquer comme rejetée
      await supabase
        .from("secure_transactions")
        .update({ status: "rejected", rejected_at: new Date().toISOString() })
        .eq("id", transactionId);
      
      return { success: false, error: "AMOUNT_MISMATCH" };
    }
    
    // ❌ Vérifier la signature
    const isValidSignature = await verifyTransactionSignature(
      transactionId,
      transaction.total_amount,
      transaction.signature
    );
    
    if (!isValidSignature) {
      console.error(`[SecureValidation] Invalid signature for ${transactionId}`);
      
      await supabase.from("financial_security_alerts").insert({
        user_id: transaction.user_id,
        alert_type: "signature_invalid",
        severity: "critical",
        description: "Signature de transaction invalide détectée",
        transaction_id: transactionId,
        details: { amountPaid }
      });
      
      await supabase
        .from("secure_transactions")
        .update({ status: "rejected", rejected_at: new Date().toISOString() })
        .eq("id", transactionId);
      
      return { success: false, error: "INVALID_SIGNATURE" };
    }
    
    // ✅ Tout est OK - Créditer le wallet
    const { data: wallet } = await supabase
      .from("wallets")
      .select("id, balance")
      .eq("user_id", transaction.user_id)
      .single();
    
    if (!wallet) {
      return { success: false, error: "WALLET_NOT_FOUND" };
    }
    
    const newBalance = wallet.balance + transaction.net_amount;
    
    await supabase
      .from("wallets")
      .update({ balance: newBalance, updated_at: new Date().toISOString() })
      .eq("id", wallet.id);
    
    // Marquer comme complétée
    await supabase
      .from("secure_transactions")
      .update({ 
        status: "completed", 
        completed_at: new Date().toISOString(),
        external_ref: externalRef || null
      })
      .eq("id", transactionId);
    
    // Log audit
    await supabase.from("financial_audit_logs").insert({
      user_id: transaction.user_id,
      action_type: "transaction_completed",
      description: `Transaction validée et créditée: ${transaction.net_amount} GNF`,
      request_data: { transactionId, newBalance },
      is_suspicious: false
    });
    
    console.log(`[SecureValidation] ✅ Transaction ${transactionId} completed - Credited ${transaction.net_amount} GNF`);
    
    return { success: true };
    
  } catch (error) {
    console.error("[SecureValidation] Error:", error);
    return { 
      success: false, 
      error: error instanceof Error ? error.message : "Unknown error" 
    };
  }
}

/**
 * 🔐 Log d'audit pour toute opération financière
 */
export async function logFinancialAudit(
  supabase: any,
  userId: string,
  actionType: string,
  description: string,
  data: Record<string, unknown>,
  isSuspicious: boolean = false,
  securityFlags: string[] = []
): Promise<void> {
  try {
    await supabase.from("financial_audit_logs").insert({
      user_id: userId,
      action_type: actionType,
      description,
      request_data: data,
      is_suspicious: isSuspicious,
      security_flags: securityFlags.length > 0 ? securityFlags : null
    });
  } catch (error) {
    console.error("[AuditLog] Failed to log:", error);
  }
}

/**
 * 🔐 Crée une alerte de sécurité financière
 */
export async function createSecurityAlert(
  supabase: any,
  userId: string,
  alertType: string,
  severity: "low" | "medium" | "high" | "critical",
  description: string,
  transactionId?: string,
  details?: Record<string, unknown>
): Promise<void> {
  try {
    await supabase.from("financial_security_alerts").insert({
      user_id: userId,
      alert_type: alertType,
      severity,
      description,
      transaction_id: transactionId || null,
      details: details || {}
    });
    
    console.log(`[SecurityAlert] Created: ${alertType} - ${severity} - User: ${userId}`);
  } catch (error) {
    console.error("[SecurityAlert] Failed to create:", error);
  }
}
