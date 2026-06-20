/**
 * 🔐 DJOMY API CLIENT - VERSION OFFICIELLE
 * Conforme à la documentation: https://developers.djomy.africa
 * 
 * Gère:
 * - Signature HMAC-SHA256 pour X-API-KEY
 * - Authentification Bearer token via /v1/auth
 * - Appels API avec double header (Bearer + X-API-KEY)
 * - Cache des tokens avec régénération automatique
 */

// ============= TYPES =============

export interface DjomyConfig {
  clientId: string;
  clientSecret: string;
  useSandbox?: boolean;
}

export interface DjomyTokenData {
  accessToken: string;
  expiresAt: number; // timestamp en ms
}

export interface DjomyPaymentRequest {
  paymentMethod: 'OM' | 'MOMO' | 'KULU' | 'SOUTRA_MONEY' | 'PAYCARD';
  payerIdentifier: string; // Format international: 00224623707722
  amount: number;
  countryCode: string; // ISO: GN, CI, etc.
  description?: string;
  merchantPaymentReference?: string;
  returnUrl?: string;
  cancelUrl?: string;
  metadata?: Record<string, unknown>;
}

export interface DjomyGatewayRequest {
  amount: number;
  countryCode: string;
  payerNumber: string; // Format international
  paymentMethodFilters?: ('OM' | 'MOMO' | 'VISA' | 'MC' | 'KULU' | 'SOUTRA_MONEY' | 'PAYCARD')[];
  description?: string;
  merchantPaymentReference?: string;
  returnUrl: string; // Obligatoire, doit être HTTPS
  cancelUrl?: string;
  metadata?: Record<string, unknown>;
}

export interface DjomyPaymentResponse {
  success: boolean;
  transactionId?: string;
  redirectUrl?: string;
  status?: string;
  error?: string;
  data?: unknown;
}

export interface DjomyStatusResponse {
  transactionId: string;
  status: 'CREATED' | 'PENDING' | 'SUCCESS' | 'FAILED' | 'CANCELLED' | 'REDIRECTED';
  paidAmount?: number;
  receivedAmount?: number;
  fees?: number;
  paymentMethod?: string;
  payerIdentifier?: string;
  merchantPaymentReference?: string;
  currency?: string;
  createdAt?: string;
}

// ============= TOKEN CACHE =============

const tokenCache: Record<string, DjomyTokenData> = {};

// ============= UTILITY FUNCTIONS =============

const logStep = (step: string, details?: Record<string, unknown>) => {
  const timestamp = new Date().toISOString();
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[${timestamp}] [DJOMY-CLIENT] ${step}${detailsStr}`);
};

/**
 * Génère la signature HMAC-SHA256 pour X-API-KEY
 * Documentation: signature = HMAC_SHA256(clientId, clientSecret)
 */
export async function generateHmacSignature(clientId: string, clientSecret: string): Promise<string> {
  const encoder = new TextEncoder();
  const keyData = encoder.encode(clientSecret);
  const messageData = encoder.encode(clientId);
  
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    keyData,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, messageData);
  const hashArray = Array.from(new Uint8Array(signature));
  const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
  
  return hashHex;
}

/**
 * Génère l'en-tête X-API-KEY au format: clientId:signature
 */
export async function generateXApiKey(clientId: string, clientSecret: string): Promise<string> {
  const signature = await generateHmacSignature(clientId, clientSecret);
  return `${clientId}:${signature}`;
}

/**
 * Vérifie une signature webhook
 * Format de l'en-tête: X-Webhook-Signature: v1:signature
 */
export async function verifyWebhookSignature(
  payload: string, 
  signatureHeader: string, 
  clientSecret: string
): Promise<boolean> {
  try {
    const parts = signatureHeader.split(":");
    if (parts.length !== 2 || parts[0] !== "v1") {
      logStep("Invalid webhook signature format", { header: signatureHeader });
      return false;
    }
    
    const providedSignature = parts[1];
    
    const encoder = new TextEncoder();
    const keyData = encoder.encode(clientSecret);
    const messageData = encoder.encode(payload);
    
    const cryptoKey = await crypto.subtle.importKey(
      "raw",
      keyData,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );
    
    const signatureBuffer = await crypto.subtle.sign("HMAC", cryptoKey, messageData);
    const hashArray = Array.from(new Uint8Array(signatureBuffer));
    const computedSignature = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
    
    const isValid = computedSignature === providedSignature;
    logStep("Webhook signature verification", { isValid });
    
    return isValid;
  } catch (error) {
    logStep("Webhook signature verification error", { error: String(error) });
    return false;
  }
}

// ============= DJOMY CLIENT CLASS =============

export class DjomyClient {
  private clientId: string;
  private clientSecret: string;
  private baseUrl: string;
  private xApiKey: string | null = null;

  constructor(config: DjomyConfig) {
    this.clientId = config.clientId;
    this.clientSecret = config.clientSecret;
    this.baseUrl = config.useSandbox 
      ? "https://sandbox-api.djomy.africa" 
      : "https://api.djomy.africa";
    
    logStep("DjomyClient initialized", { 
      clientIdPrefix: this.clientId.substring(0, 20),
      environment: config.useSandbox ? "sandbox" : "production",
      baseUrl: this.baseUrl
    });
  }

  /**
   * Récupère ou génère le X-API-KEY header
   */
  private async getXApiKey(): Promise<string> {
    if (!this.xApiKey) {
      this.xApiKey = await generateXApiKey(this.clientId, this.clientSecret);
    }
    return this.xApiKey;
  }

  /**
   * Obtient un Bearer token via POST /v1/auth
   * Documentation: Le body doit être vide {}
   */
  private async generateToken(): Promise<DjomyTokenData> {
    logStep("🔐 Generating Bearer token via /v1/auth");
    
    const xApiKey = await this.getXApiKey();
    
    const response = await fetch(`${this.baseUrl}/v1/auth`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-API-KEY": xApiKey,
        "User-Agent": "224Solutions/2.0",
      },
      body: JSON.stringify({}),
    });
    
    const responseText = await response.text();
    logStep("Token response", { 
      status: response.status, 
      bodyPreview: responseText.substring(0, 200) 
    });
    
    if (!response.ok) {
      throw new Error(`Djomy auth failed: ${response.status} - ${responseText}`);
    }
    
    const data = JSON.parse(responseText);
    
    // La réponse Djomy peut être: { data: { accessToken: "..." } } ou { accessToken: "..." }
    const tokenData = data.data || data;
    const accessToken = tokenData.access_token || tokenData.accessToken;
    const expiresIn = tokenData.expires_in || tokenData.expiresIn || data.expires_in || 3600;
    
    if (!accessToken) {
      logStep("Token parsing failed", { data });
      throw new Error("Djomy auth response missing access token");
    }
    
    const expiresAt = Date.now() + (expiresIn - 300) * 1000; // -5min de marge
    
    logStep("✅ Token obtained successfully", { 
      tokenPreview: accessToken.substring(0, 30) + "...",
      expiresIn 
    });
    
    return {
      accessToken,
      expiresAt
    };
  }

  /**
   * Récupère un token valide (depuis cache ou génère un nouveau)
   */
  async getAccessToken(): Promise<string> {
    const cacheKey = `${this.baseUrl}_${this.clientId}`;
    const cachedToken = tokenCache[cacheKey];
    
    if (cachedToken && cachedToken.expiresAt > Date.now()) {
      const remainingMinutes = Math.round((cachedToken.expiresAt - Date.now()) / 60000);
      logStep("♻️ Using cached token", { remainingMinutes });
      return cachedToken.accessToken;
    }
    
    logStep("🔄 Token expired or missing, generating new one");
    const newToken = await this.generateToken();
    tokenCache[cacheKey] = newToken;
    
    return newToken.accessToken;
  }

  /**
   * Prépare les headers pour les appels API
   * Tous les appels nécessitent: Authorization + X-API-KEY
   */
  private async getHeaders(): Promise<Record<string, string>> {
    const accessToken = await this.getAccessToken();
    const xApiKey = await this.getXApiKey();
    
    return {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "User-Agent": "224Solutions/2.0",
      "Authorization": `Bearer ${accessToken}`,
      "X-API-KEY": xApiKey,
    };
  }

  /**
   * POST /v1/payments - Paiement SANS redirection (OM, MOMO, KULU uniquement)
   * ⚠️ VISA/MC non autorisés sur cet endpoint
   */
  async initiatePayment(request: DjomyPaymentRequest): Promise<DjomyPaymentResponse> {
    logStep("💳 Initiating direct payment", { 
      method: request.paymentMethod, 
      amount: request.amount 
    });
    
    // Validation: pas de cartes sur cet endpoint
    if (['VISA', 'MC'].includes(request.paymentMethod as string)) {
      return {
        success: false,
        error: "VISA/Mastercard ne sont pas autorisés sur cet endpoint. Utilisez initiateGatewayPayment()."
      };
    }
    
    const headers = await this.getHeaders();
    
    const response = await fetch(`${this.baseUrl}/v1/payments`, {
      method: "POST",
      headers,
      body: JSON.stringify(request),
    });
    
    const responseText = await response.text();
    logStep("Direct payment response", { status: response.status });
    
    if (!response.ok) {
      return {
        success: false,
        error: `${response.status}: ${responseText}`
      };
    }
    
    const data = JSON.parse(responseText);
    return {
      success: true,
      transactionId: data.transactionId || data.id,
      redirectUrl: data.redirectUrl, // Pour KULU
      status: data.status,
      data
    };
  }

  /**
   * POST /v1/payments/gateway - Paiement AVEC redirection vers portail Djomy
   * ✅ Tous les moyens de paiement autorisés (y compris VISA/MC)
   */
  async initiateGatewayPayment(request: DjomyGatewayRequest): Promise<DjomyPaymentResponse> {
    logStep("🌐 Initiating gateway payment", { 
      amount: request.amount,
      filters: request.paymentMethodFilters 
    });
    
    // Validation: returnUrl obligatoire et HTTPS
    if (!request.returnUrl || !request.returnUrl.startsWith("https://")) {
      return {
        success: false,
        error: "returnUrl est obligatoire et doit être en HTTPS"
      };
    }
    
    const headers = await this.getHeaders();
    
    const response = await fetch(`${this.baseUrl}/v1/payments/gateway`, {
      method: "POST",
      headers,
      body: JSON.stringify(request),
    });
    
    const responseText = await response.text();
    logStep("Gateway payment response", { status: response.status });
    
    if (!response.ok) {
      return {
        success: false,
        error: `${response.status}: ${responseText}`
      };
    }
    
    const data = JSON.parse(responseText);
    return {
      success: true,
      transactionId: data.transactionId || data.id,
      redirectUrl: data.redirectUrl || data.url, // URL de redirection vers portail Djomy
      status: data.status,
      data
    };
  }

  /**
   * GET /v1/payments/{transactionId}/status - Récupère le statut d'un paiement
   */
  async getPaymentStatus(transactionId: string): Promise<DjomyStatusResponse | null> {
    logStep("🔍 Getting payment status", { transactionId });
    
    const headers = await this.getHeaders();
    
    const response = await fetch(`${this.baseUrl}/v1/payments/${transactionId}/status`, {
      method: "GET",
      headers,
    });
    
    const responseText = await response.text();
    logStep("Payment status response", { status: response.status });
    
    if (!response.ok) {
      logStep("Failed to get payment status", { error: responseText });
      return null;
    }
    
    return JSON.parse(responseText);
  }

  /**
   * POST /v1/payments/{transactionReference}/confirmOTP - Confirme un OTP
   */
  async confirmOTP(transactionReference: string, oneTimePin: string): Promise<boolean> {
    logStep("🔐 Confirming OTP", { transactionReference });
    
    const headers = await this.getHeaders();
    
    const response = await fetch(`${this.baseUrl}/v1/payments/${transactionReference}/confirmOTP`, {
      method: "POST",
      headers,
      body: JSON.stringify({ oneTimePin }),
    });
    
    return response.ok;
  }

  /**
   * POST /v1/links - Génère un lien de paiement
   */
  async generatePaymentLink(options: {
    amountToPay?: number;
    linkName?: string;
    phoneNumber?: string;
    sendSms?: boolean;
    description?: string;
    countryCode: string;
    usageType?: 'UNIQUE' | 'MULTIPLE';
    expiresAt?: string;
    merchantReference?: string;
    usageLimit?: number;
    returnUrl?: string;
    cancelUrl?: string;
    paymentMethodFilters?: string[];
    metadata?: Record<string, unknown>;
  }): Promise<{ success: boolean; reference?: string; url?: string; error?: string }> {
    logStep("🔗 Generating payment link", { linkName: options.linkName });
    
    const headers = await this.getHeaders();
    
    const response = await fetch(`${this.baseUrl}/v1/links`, {
      method: "POST",
      headers,
      body: JSON.stringify(options),
    });
    
    const responseText = await response.text();
    
    if (!response.ok) {
      return { success: false, error: `${response.status}: ${responseText}` };
    }
    
    const data = JSON.parse(responseText);
    return {
      success: true,
      reference: data.reference,
      url: data.url || data.paymentUrl,
    };
  }
}

/**
 * Crée un client Djomy à partir des variables d'environnement
 * 
 * Mode Sandbox (test):
 *   - Utilise DJOMY_CLIENT_ID_SANDBOX et DJOMY_CLIENT_SECRET_SANDBOX
 *   - Endpoint: https://sandbox-api.djomy.africa
 *   - Aucun argent réel n'est transféré
 * 
 * Mode Production:
 *   - Utilise DJOMY_CLIENT_ID et DJOMY_CLIENT_SECRET
 *   - Endpoint: https://api.djomy.africa
 *   - Paiements réels avec de l'argent réel
 * 
 * @param useSandbox - Force le mode sandbox si true
 */
export function createDjomyClient(useSandbox?: boolean): DjomyClient {
  // Détermine le mode: paramètre > env var > défaut (SANDBOX par défaut car production pas encore activée)
  // ⚠️ Quand production activée, changer: useSandbox ?? Deno.env.get("DJOMY_SANDBOX") !== "false"
  const sandboxMode = useSandbox ?? (Deno.env.get("DJOMY_SANDBOX") !== "false");
  
  let clientId: string | undefined;
  let clientSecret: string | undefined;
  
  if (sandboxMode) {
    // 🧪 Mode Sandbox - Test sans argent réel
    clientId = Deno.env.get("DJOMY_CLIENT_ID_SANDBOX")?.trim();
    clientSecret = Deno.env.get("DJOMY_CLIENT_SECRET_SANDBOX")?.trim();
    
    if (!clientId || !clientSecret) {
      throw new Error("Mode Sandbox: DJOMY_CLIENT_ID_SANDBOX et DJOMY_CLIENT_SECRET_SANDBOX sont requis");
    }
    
    console.log(`[DJOMY] 🧪 Mode SANDBOX activé - ${clientId.substring(0, 25)}...`);
  } else {
    // 💰 Mode Production - Paiements réels
    clientId = Deno.env.get("DJOMY_CLIENT_ID")?.trim();
    clientSecret = Deno.env.get("DJOMY_CLIENT_SECRET")?.trim();
    
    if (!clientId || !clientSecret) {
      throw new Error("Mode Production: DJOMY_CLIENT_ID et DJOMY_CLIENT_SECRET sont requis");
    }
    
    console.log(`[DJOMY] 💰 Mode PRODUCTION activé - ${clientId.substring(0, 25)}...`);
  }
  
  return new DjomyClient({ clientId, clientSecret, useSandbox: sandboxMode });
}
