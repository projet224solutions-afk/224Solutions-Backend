/**
 * 🔐 CHAPCHAPPAY API CLIENT - 224SOLUTIONS
 * Client partagé pour les paiements Mobile Money via ChapChapPay
 *
 * Docs publiques: https://chapchappay.com/guide/
 *
 * NOTE IMPORTANTE:
 * - Le mode E-Commerce génère un payment_url (le client doit ouvrir un lien)
 * - Le mode PULL API déclenche une demande de débit sur le téléphone du client
 *   (nécessite un Agent API + permission PULL + signature HMAC)
 */

// ============= TYPES =============

export interface ChapChapPayConfig {
  apiKey: string;
  secretKey?: string;
  encryptionKey?: string;
  useSandbox?: boolean;
}

export interface CCPPaymentRequest {
  amount: number;
  currency?: string; // GNF, XOF, etc.
  paymentMethod?: "orange_money" | "mtn_momo" | "paycard" | "wave" | "card";
  customerPhone?: string;
  customerName?: string;
  customerEmail?: string;
  description?: string;
  orderId?: string;
  returnUrl?: string;
  cancelUrl?: string;
  webhookUrl?: string;
  metadata?: Record<string, unknown>;
}

export interface CCPPushRequest {
  amount: number;
  currency?: string;
  paymentMethod: "orange_money" | "mtn_momo";
  recipientPhone: string;
  recipientName?: string;
  description?: string;
  orderId?: string;
}

export interface CCPPaymentResponse {
  success: boolean;
  transactionId?: string;
  operationId?: string;
  paymentUrl?: string;
  status?: "pending" | "processing" | "completed" | "failed" | "cancelled";
  requiresOtp?: boolean;
  /** true si ChapChapPay a déclenché la demande sur le téléphone */
  ussdTriggered?: boolean;
  error?: string;
  data?: unknown;
}

export interface CCPStatusResponse {
  success: boolean;
  transactionId?: string;
  operationId?: string;
  status?: "pending" | "processing" | "completed" | "failed" | "cancelled";
  amount?: number;
  paidAmount?: number;
  fees?: number;
  paymentMethod?: string;
  customerPhone?: string;
  createdAt?: string;
  completedAt?: string;
  error?: string;
}

// ============= UTILS =============

const logStep = (step: string, details?: Record<string, unknown>) => {
  const timestamp = new Date().toISOString();
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[${timestamp}] [CHAPCHAPPAY] ${step}${detailsStr}`);
};

function toHex(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let hex = "";
  for (const b of bytes) hex += b.toString(16).padStart(2, "0");
  return hex;
}

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const keyData = enc.encode(secret);
  const msgData = enc.encode(message);

  const key = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const sig = await crypto.subtle.sign("HMAC", key, msgData);
  return toHex(sig);
}

async function postJson(url: string, payload: unknown, headers: Record<string, string>) {
  const body = JSON.stringify(payload);
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      ...headers,
    },
    body,
  });
  const text = await res.text();
  let json: any = null;
  try {
    json = JSON.parse(text);
  } catch {
    // ignore
  }
  return { res, text, json };
}

// ============= CLIENT =============

export class ChapChapPayClient {
  private config: ChapChapPayConfig;
  private baseUrl: string;

  constructor(config: ChapChapPayConfig) {
    this.config = config;
    this.baseUrl = "https://chapchappay.com";

    logStep("ChapChapPay Client initialized", {
      environment: config.useSandbox ? "sandbox" : "production",
      baseUrl: this.baseUrl,
      hasEncryptionKey: !!(config.encryptionKey || config.secretKey),
    });
  }

  private getSignatureKey(): string {
    const key = this.config.encryptionKey || this.config.secretKey;
    if (!key) throw new Error("ChapChapPay: CCP_ENCRYPTION_KEY/CCP_SECRET_KEY requis pour PULL/PUSH");
    return key;
  }

  private formatPhoneNumber(phone: string): string {
    const cleaned = phone.replace(/\D/g, "");

    if (cleaned.startsWith("224") && cleaned.length === 12) return cleaned;
    if (cleaned.startsWith("00224")) return cleaned.substring(2);
    if (cleaned.length === 9) return `224${cleaned}`;

    return cleaned;
  }

  /**
   * E-Commerce: crée une opération et retourne payment_url
   */
  async createEcommercePayment(request: CCPPaymentRequest): Promise<CCPPaymentResponse> {
    logStep("Creating E-Commerce payment", { amount: request.amount, method: request.paymentMethod });

    const orderId = request.orderId || `224SOL-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
    const payload: Record<string, unknown> = {
      amount: Math.round(request.amount),
      order_id: orderId,
    };

    if (request.description) payload.description = request.description;
    if (request.returnUrl) payload.return_url = request.returnUrl;
    if (request.webhookUrl) payload.notify_url = request.webhookUrl;
    if (request.customerName) payload.customer_name = request.customerName;
    if (request.customerPhone) payload.customer_phone = this.formatPhoneNumber(request.customerPhone);
    if (request.customerEmail) payload.customer_email = request.customerEmail;
    if (request.metadata) payload.metadata = JSON.stringify(request.metadata);

    const endpoints = [
      `${this.baseUrl}/api/ecommerce/operation`,
      `${this.baseUrl}/api/ecommerce/create`,
    ];

    let lastError = "";

    for (const url of endpoints) {
      const { res, text, json } = await postJson(url, payload, {
        "CCP-Api-Key": this.config.apiKey,
        "User-Agent": "224Solutions/2.0",
      });

      logStep("E-Commerce response", { url, status: res.status, body: text.substring(0, 200) });

      if (!res.ok) {
        lastError = (json?.error || json?.message || text || `HTTP ${res.status}`) as string;
        continue;
      }

      const paymentUrl = String(json?.payment_url || "");
      const opId = String(json?.operation_id || "");

      if (paymentUrl || opId) {
        return {
          success: true,
          transactionId: opId || orderId,
          operationId: opId,
          paymentUrl,
          status: "pending",
          ussdTriggered: false,
          data: json,
        };
      }

      lastError = "Réponse ChapChapPay inattendue";
    }

    return { success: false, error: lastError || "Erreur ChapChapPay E-Commerce" };
  }

  /**
   * PULL API: doit déclencher la demande de paiement sur le téléphone
   */
  async initiatePullPayment(request: CCPPaymentRequest): Promise<CCPPaymentResponse> {
    const orderId = request.orderId || `224SOL-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
    const phone = this.formatPhoneNumber(request.customerPhone || "");

    logStep("Initiating PULL payment", {
      amount: request.amount,
      method: request.paymentMethod,
      phone: phone ? `${phone.slice(0, 6)}...` : "",
    });

    const notifyUrl = request.webhookUrl || `${Deno.env.get("SUPABASE_URL")}/functions/v1/chapchappay-webhook`;

    const payload: Record<string, unknown> = {
      amount: Math.round(request.amount),
      order_id: orderId,
      payment_method: request.paymentMethod || "orange_money",
      description: request.description || "Paiement 224Solutions",
      notify_url: notifyUrl,
      // champs téléphone (les APIs varient, on en met 2 pour compat)
      customer_phone: phone,
      phone,
    };

    if (request.customerName) payload.customer_name = request.customerName;
    if (request.customerEmail) payload.customer_email = request.customerEmail;
    if (request.metadata) payload.metadata = request.metadata;

    const payloadStr = JSON.stringify(payload);
    const signature = await hmacSha256Hex(this.getSignatureKey(), payloadStr);

    // Tous les endpoints sont sur chapchappay.com (pas de sous-domaine api.*)
    const candidates: string[] = [
      `${this.baseUrl}/api/pull/operation`,
      `${this.baseUrl}/api/pull/collect`,
      `${this.baseUrl}/api/pull/initiate`,
      `${this.baseUrl}/api/collect/create`,
    ];

    let lastStatus = 0;
    let lastBody = "";

    for (const url of candidates) {
      logStep("PULL attempt", { url });

      try {
        const { res, text, json } = await postJson(url, payload, {
          "CCP-Api-Key": this.config.apiKey,
          "CCP-HMAC-Signature": signature,
          "User-Agent": "224Solutions/2.0",
        });

        lastStatus = res.status;
        lastBody = text;

        logStep("PULL response", { url, status: res.status, body: text.substring(0, 200) });

        // Endpoint inexistant -> on essaie le prochain
        if (res.status === 404) continue;

        // Permission/Signature
        if (res.status === 401 || res.status === 403) {
          return {
            success: false,
            error: "ChapChapPay PULL API non autorisée (permission PULL / signature HMAC).",
            data: { status: res.status, body: json || text },
          };
        }

        if (!res.ok) {
          return {
            success: false,
            error: (json?.error || json?.message || `Erreur PULL: ${res.status}`) as string,
            data: { status: res.status, body: json || text },
          };
        }

        const opId = String(json?.operation_id || json?.transaction_id || "");
        if (opId || json?.success) {
          return {
            success: true,
            transactionId: opId || orderId,
            operationId: opId,
            status: "processing",
            ussdTriggered: true,
            data: json,
          };
        }

        // Réponse OK mais inattendue -> stop
        return {
          success: false,
          error: "Réponse PULL inattendue",
          data: json,
        };
      } catch (err) {
        // Erreur réseau (DNS, connexion) -> on passe au suivant
        logStep("PULL network error", { url, error: err instanceof Error ? err.message : String(err) });
        continue;
      }
    }

    // Si aucun endpoint PULL n'a répondu (404 partout), on fallback E-Commerce
    logStep("PULL endpoints not found - falling back to E-Commerce", { lastStatus, lastBody: lastBody.substring(0, 100) });
    const fallback = await this.createEcommercePayment({ ...request, orderId, customerPhone: phone, webhookUrl: notifyUrl });

    if (fallback.success) {
      return {
        ...fallback,
        ussdTriggered: false,
        data: {
          ...(typeof fallback.data === "object" && fallback.data ? (fallback.data as Record<string, unknown>) : {}),
          pull_fallback: true,
          pull_last_status: lastStatus,
        },
      };
    }

    return {
      success: false,
      error: "PULL indisponible (endpoint introuvable) et E-Commerce a échoué",
    };
  }

  /**
   * PUSH: (inchangé côté logique, si besoin on pourra aussi signer pareil)
   */
  async initiatePushPayment(request: CCPPushRequest): Promise<CCPPaymentResponse> {
    logStep("Initiating PUSH payment", { amount: request.amount, method: request.paymentMethod });

    try {
      const orderId = request.orderId || `224SOL-PUSH-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;

      const payload = {
        amount: Math.round(request.amount),
        order_id: orderId,
        recipient_phone: this.formatPhoneNumber(request.recipientPhone),
        recipient_name: request.recipientName || "Destinataire",
        payment_method: request.paymentMethod,
        description: request.description || "Transfert 224Solutions",
      };

      const { res, text, json } = await postJson(`${this.baseUrl}/api/transfer/create`, payload, {
        "CCP-Api-Key": this.config.apiKey,
        "User-Agent": "224Solutions/2.0",
      });

      logStep("PUSH response", { status: res.status, body: text.substring(0, 200) });

      if (!res.ok) {
        return { success: false, error: (json?.error || json?.message || `Erreur ${res.status}`) as string };
      }

      const opId = String(json?.operation_id || "");
      return {
        success: true,
        transactionId: opId || orderId,
        operationId: opId,
        status: (json?.status || "pending") as CCPPaymentResponse["status"],
        data: json,
      };
    } catch (error) {
      return { success: false, error: error instanceof Error ? error.message : String(error) };
    }
  }

  /**
   * Statut: notre endpoint actuel renvoie 404 chez vous, on le gardera à corriger ensuite.
   */
  async checkStatus(transactionId?: string, orderId?: string): Promise<CCPStatusResponse> {
    logStep("Checking payment status", { transactionId, orderId });

    try {
      const identifier = transactionId || orderId;
      if (!identifier) return { success: false, error: "Transaction ID ou Order ID requis" };

      const { res, text, json } = await postJson(`${this.baseUrl}/api/payment/status`, {
        operation_id: transactionId,
        order_id: orderId,
      }, {
        "CCP-Api-Key": this.config.apiKey,
        "User-Agent": "224Solutions/2.0",
      });

      logStep("Status response", { status: res.status, body: text.substring(0, 200) });

      if (!res.ok) {
        return { success: false, error: (json?.error || json?.message || `HTTP ${res.status}`) as string };
      }

      const statusMapping: Record<string, CCPStatusResponse["status"]> = {
        SUCCESS: "completed",
        COMPLETED: "completed",
        PAID: "completed",
        FAILED: "failed",
        CANCELLED: "cancelled",
        CANCELED: "cancelled",
        PENDING: "pending",
        PROCESSING: "processing",
      };

      const rawStatus = String(json?.status || "pending").toUpperCase();

      return {
        success: true,
        transactionId: String(json?.operation_id || transactionId),
        operationId: String(json?.operation_id || ""),
        status: statusMapping[rawStatus] || "pending",
        amount: Number(json?.amount) || undefined,
        paidAmount: Number(json?.paid_amount || json?.amount) || undefined,
        paymentMethod: String(json?.payment_method || ""),
        customerPhone: String(json?.customer_phone || ""),
        createdAt: String(json?.created_at || ""),
        completedAt: String(json?.completed_at || ""),
      };
    } catch (error) {
      return { success: false, error: error instanceof Error ? error.message : String(error) };
    }
  }
}

export function createChapChapPayClient(useSandbox = false): ChapChapPayClient {
  const apiKey = Deno.env.get("CCP_API_KEY");
  const secretKey = Deno.env.get("CCP_SECRET_KEY");
  const encryptionKey = Deno.env.get("CCP_ENCRYPTION_KEY");

  if (!apiKey) throw new Error("ChapChapPay: CCP_API_KEY requis");

  return new ChapChapPayClient({
    apiKey,
    secretKey: secretKey || undefined,
    encryptionKey: encryptionKey || undefined,
    useSandbox,
  });
}
