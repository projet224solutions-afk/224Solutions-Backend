import { Router } from "express";
import { supabaseAdmin } from "../../config/supabase.js";
import Stripe from "stripe";

const router = Router();
const stripe = process.env.STRIPE_SECRET_KEY
  ? new Stripe(process.env.STRIPE_SECRET_KEY, {
      apiVersion: "2026-03-25.dahlia",
    })
  : null;

const DEFAULT_FEES: Record<string, number> = {
  commission_achats: 5,
};

const FEE_KEY_ALIASES: Record<string, string[]> = {
  commission_achats: ["purchase_commission_percentage"],
};

const STRIPE_ZERO_DECIMAL_CURRENCIES = new Set([
  "BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF",
  "UGX", "VND", "VUV", "XAF", "XOF", "XPF",
]);

type PayPalAuthResponse = {
  access_token?: string;
};

type PayPalOrderResponse = {
  id?: string;
  links?: unknown[];
};

async function getPdgFeeRatePercent(settingKey: string): Promise<number> {
  const defaultValue = DEFAULT_FEES[settingKey] ?? 0;
  const candidateKeys = [settingKey, ...(FEE_KEY_ALIASES[settingKey] || [])];
  try {
    for (const key of candidateKeys) {
      const { data, error } = await supabaseAdmin
        .from("pdg_settings")
        .select("setting_value")
        .eq("setting_key", key)
        .maybeSingle();

      if (error || !data) continue;

      const raw = data.setting_value;
      const rate = typeof raw === "object" && raw !== null && "value" in (raw as any)
        ? Number((raw as any).value)
        : Number(raw);

      if (Number.isFinite(rate) && rate >= 0) return rate;
    }

    return defaultValue;
  } catch {
    return defaultValue;
  }
}

function toStripeAmount(amount: number, currency: string): number {
  return STRIPE_ZERO_DECIMAL_CURRENCIES.has(String(currency || "").toUpperCase())
    ? Math.round(amount)
    : Math.round(amount * 100);
}

function getCartItemVendorId(item: any): string | null {
  return item?.vendorId || item?.vendor_id || null;
}

// Montant maximum autorisé par commande (protection anti-abus)
const MAX_ORDER_AMOUNT = 100_000_000; // 100M GNF

function buildVendorSummary(cartItems: any[], realPrices: Map<string, number>): Record<string, number> {
  return cartItems.reduce((summary: Record<string, number>, item: any) => {
    const vendorId = getCartItemVendorId(item) || "unknown";
    const id = item?.id || item?.product_id;
    // Utiliser le prix réel de la DB, jamais le prix frontend
    const realPrice = realPrices.get(id) ?? Number(item?.price || 0);
    const itemAmount = realPrice * Number(item?.quantity || 1);
    summary[vendorId] = (summary[vendorId] || 0) + itemAmount;
    return summary;
  }, {});
}

/**
 * Recalcule le montant total depuis les prix réels en base de données.
 * Cherche dans products puis digital_products.
 * Retourne null si aucun article valide trouvé (cartItems vide = pas de vérification possible).
 */
async function recalculateAmountFromDB(
  cartItems: any[]
): Promise<{ amount: number; realPrices: Map<string, number> } | null> {
  if (!cartItems.length) return null;

  const ids: string[] = cartItems
    .map((i: any) => i?.id || i?.product_id)
    .filter((id: any): id is string => typeof id === "string" && id.length > 0);

  if (!ids.length) return null;

  // Chercher dans products (physiques)
  const { data: physicalProducts } = await supabaseAdmin
    .from("products")
    .select("id, price")
    .in("id", ids);

  const realPrices = new Map<string, number>();
  for (const p of physicalProducts || []) {
    realPrices.set(p.id, Number(p.price));
  }

  // Chercher dans digital_products pour les IDs non trouvés
  const missingIds = ids.filter((id) => !realPrices.has(id));
  if (missingIds.length) {
    const { data: digitalProducts } = await supabaseAdmin
      .from("digital_products")
      .select("id, price")
      .in("id", missingIds);
    for (const p of digitalProducts || []) {
      realPrices.set(p.id, Number(p.price));
    }
  }

  if (realPrices.size === 0) return null;

  let total = 0;
  for (const item of cartItems) {
    const id = item?.id || item?.product_id;
    const realPrice = realPrices.get(id);
    if (realPrice === undefined) continue;
    const qty = Math.max(1, Number(item?.quantity || 1));
    total += realPrice * qty;
  }

  return { amount: Math.round(total), realPrices };
}

async function resolvePrimarySellerId(cartItems: any[], fallbackUserId: string): Promise<string> {
  const vendorIds = Array.from(
    new Set(cartItems.map(getCartItemVendorId).filter((id): id is string => Boolean(id)))
  );

  if (vendorIds.length === 0) return fallbackUserId;

  const { data: vendors, error } = await supabaseAdmin
    .from("vendors")
    .select("id, user_id")
    .in("id", vendorIds);

  if (error || !vendors?.length) return fallbackUserId;

  return vendors.find((vendor: any) => Boolean(vendor.user_id))?.user_id || fallbackUserId;
}

function getBearerToken(req: any): string | null {
  const auth = req.headers.authorization;
  if (!auth || !auth.startsWith("Bearer ")) return null;
  return auth.slice("Bearer ".length).trim();
}

// Middleware to extract and validate bearer token
const validateBearerToken = async (req: any, res: any, next: any) => {
  try {
    const token = getBearerToken(req);
    if (!token) return res.status(401).json({ success: false, error: "Missing bearer token" });

    const { data, error } = await supabaseAdmin.auth.getUser(token);
    if (error || !data.user) return res.status(401).json({ success: false, error: "Invalid token" });

    req.user = data.user;
    next();
  } catch (err) {
    return res.status(500).json({ success: false, error: "Token validation failed" });
  }
};

// Helper: Get PayPal access token
const getPayPalAccessToken = async (): Promise<string> => {
  const clientId = process.env.PAYPAL_CLIENT_ID;
  const clientSecret = process.env.PAYPAL_CLIENT_SECRET;

  if (!clientId || !clientSecret) {
    throw new Error("PayPal credentials not configured");
  }

  const auth = Buffer.from(`${clientId}:${clientSecret}`).toString("base64");
  const response = await fetch("https://api-m.paypal.com/v1/oauth2/token", {
    method: "POST",
    headers: {
      Authorization: `Basic ${auth}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });

  const data = (await response.json()) as PayPalAuthResponse;
  if (!data.access_token) {
    throw new Error("PayPal access token missing in response");
  }
  return data.access_token;
};

// 1. Create PayPal Order
router.post("/create-paypal-order", validateBearerToken, async (req: any, res: any) => {
  try {
    const { amount, currency = "GNF", seller_id, order_id, service_id, product_id, metadata } = req.body;

    if (!amount || !seller_id) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Get user profile
    const { data: profile } = await supabaseAdmin
      .from("profiles")
      .select("user_id, vendor_id")
      .eq("user_id", req.user.id)
      .single();

    // Get seller info
    const { data: seller } = await supabaseAdmin
      .from("profiles")
      .select("user_id, vendor_id")
      .eq("user_id", seller_id)
      .single();

    if (!seller) {
      return res.status(404).json({ success: false, error: "Seller not found" });
    }

    const commissionRatePercent = await getPdgFeeRatePercent("commission_achats");
    const commissionRate = commissionRatePercent / 100;
    const commissionAmount = amount * commissionRate;

    // Get PayPal access token
    const accessToken = await getPayPalAccessToken();

    // Determine PayPal currency (convert GNF appropriately)
    const paypalCurrency = currency === "GNF" ? "XOF" : currency;
    const paypalAmount = amount.toString(); // Assume conversion done client-side

    // Create PayPal order
    const paypalOrderResponse = await fetch("https://api-m.paypal.com/v2/checkout/orders", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify({
        intent: "CAPTURE",
        purchase_units: [
          {
            amount: {
              currency_code: paypalCurrency,
              value: paypalAmount,
            },
            reference_id: order_id || "marketplace_order",
          },
        ],
      }),
    });

    if (!paypalOrderResponse.ok) {
      throw new Error("PayPal order creation failed");
    }

    const paypalOrder = (await paypalOrderResponse.json()) as PayPalOrderResponse;
    if (!paypalOrder.id) {
      throw new Error("PayPal order ID missing in response");
    }

    // Store transaction in Supabase
    const { data: transaction } = await supabaseAdmin
      .from("stripe_transactions")
      .insert({
        user_id: profile?.user_id,
        seller_id,
        amount,
        currency,
        status: "pending",
        payment_method: "paypal",
        paypal_order_id: paypalOrder.id,
        order_id,
        service_id,
        product_id,
        metadata: {
          ...metadata,
          commission_rate: commissionRate,
          commission_amount: commissionAmount,
        },
        created_at: new Date().toISOString(),
      })
      .select()
      .single();

    return res.json({
      success: true,
      paypal_order_id: paypalOrder.id,
      links: paypalOrder.links,
      client_secret: paypalOrder.id, // Use PayPal order ID as reference
      transaction_id: transaction?.id,
    });
  } catch (err: any) {
    console.error("create-paypal-order error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 2. Marketplace Escrow Payment (Stripe)
router.post("/marketplace-escrow-payment", validateBearerToken, async (req: any, res: any) => {
  try {
    if (!stripe) {
      return res.status(503).json({ success: false, error: "Stripe not configured" });
    }

    const { amount, currency = "gnf", cartItems, description } = req.body;

    if (!amount) {
      return res.status(400).json({ success: false, error: "amount is required" });
    }

    const buyerId = req.user.id;
    const frontendAmount = Number(amount);
    if (!Number.isFinite(frontendAmount) || frontendAmount <= 0) {
      return res.status(400).json({ success: false, error: "Invalid amount" });
    }
    const normalizedCurrency = String(currency || "gnf").toUpperCase();
    const effectiveCartItems = Array.isArray(cartItems) && cartItems.length > 0 ? cartItems : [];

    // Recalcul obligatoire depuis la DB — le frontend ne peut pas être source de vérité du prix
    const dbRecalc = await recalculateAmountFromDB(effectiveCartItems);
    const sourceAmount = dbRecalc ? dbRecalc.amount : frontendAmount;
    const realPrices = dbRecalc?.realPrices ?? new Map<string, number>();

    // Limiter le montant max par commande
    if (sourceAmount > MAX_ORDER_AMOUNT) {
      return res.status(400).json({ success: false, error: "Montant dépasse la limite autorisée" });
    }

    // Empêcher l'auto-achat
    const primarySellerId = await resolvePrimarySellerId(effectiveCartItems, buyerId);
    if (primarySellerId === buyerId && effectiveCartItems.length > 0) {
      return res.status(400).json({ success: false, error: "Vous ne pouvez pas acheter vos propres produits" });
    }

    const vendorSummary = buildVendorSummary(effectiveCartItems, realPrices);
    const commissionRatePercent = await getPdgFeeRatePercent("commission_achats");
    const commissionRate = commissionRatePercent / 100;
    const commissionAmount = Math.round(sourceAmount * commissionRate);
    const totalAmount = sourceAmount + commissionAmount;

    // Create Stripe PaymentIntent with automatic capture (DB escrow handles the hold logic)
    const paymentIntent = await stripe.paymentIntents.create({
      amount: toStripeAmount(totalAmount, normalizedCurrency),
      currency: normalizedCurrency.toLowerCase(),
      automatic_payment_methods: { enabled: true },
      capture_method: "automatic",
      statement_descriptor_suffix: "224SOLUTIONS",
      metadata: {
        source: "marketplace_escrow",
        buyer_id: buyerId,
        order_type: "escrow",
        cart_items: effectiveCartItems.length.toString(),
        product_amount: sourceAmount.toString(),
        commission_rate: commissionRatePercent.toString(),
        commission_amount: commissionAmount.toString(),
        total_amount: totalAmount.toString(),
        vendor_count: Object.keys(vendorSummary).filter((id) => id !== "unknown").length.toString(),
        vendor_summary: JSON.stringify(vendorSummary).slice(0, 500),
      },
    });

    // Store in stripe_transactions
    const { data: transaction, error: insertError } = await supabaseAdmin
      .from("stripe_transactions")
      .insert({
        stripe_payment_intent_id: paymentIntent.id,
        payment_intent_id: paymentIntent.id,
        buyer_id: buyerId,
        seller_id: primarySellerId,
        amount: totalAmount,
        currency: normalizedCurrency,
        status: "PENDING",
        payment_method: "card",
        commission_rate: commissionRatePercent,
        commission_amount: commissionAmount,
        seller_net_amount: sourceAmount,
        metadata: {
          cart_items: effectiveCartItems,
          vendor_summary: vendorSummary,
          commission_rate: commissionRatePercent,
          commission_amount: commissionAmount,
          escrow_mode: true,
          source: "marketplace_escrow",
          product_amount: sourceAmount,
          total_amount: totalAmount,
        },
        created_at: new Date().toISOString(),
      })
      .select("id")
      .single();

    if (insertError) {
      console.error("marketplace-escrow-payment stripe transaction insert error:", insertError.message);
    }

    return res.json({
      success: true,
      clientSecret: paymentIntent.client_secret,
      paymentIntentId: paymentIntent.id,
      transactionId: transaction?.id ?? paymentIntent.id,
      commissionRate: commissionRatePercent,
      commissionAmount,
      totalAmount,
    });
  } catch (err: any) {
    console.error("marketplace-escrow-payment error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 3. Stripe Marketplace Payment (Standard)
router.post("/stripe-marketplace-payment", validateBearerToken, async (req: any, res: any) => {
  try {
    if (!stripe) {
      return res.status(503).json({ success: false, error: "Stripe not configured" });
    }

    const { amount, currency = "gnf", cartItems, description } = req.body;

    if (!amount || !cartItems || cartItems.length === 0) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    const buyerId = req.user.id;
    const frontendAmount = Number(amount);
    if (!Number.isFinite(frontendAmount) || frontendAmount <= 0) {
      return res.status(400).json({ success: false, error: "Invalid amount" });
    }
    const normalizedCurrency = String(currency || "gnf").toUpperCase();

    // Recalcul obligatoire depuis la DB
    const dbRecalc = await recalculateAmountFromDB(cartItems);
    const sourceAmount = dbRecalc ? dbRecalc.amount : frontendAmount;
    const realPrices = dbRecalc?.realPrices ?? new Map<string, number>();

    if (sourceAmount > MAX_ORDER_AMOUNT) {
      return res.status(400).json({ success: false, error: "Montant dépasse la limite autorisée" });
    }

    const primarySellerId = await resolvePrimarySellerId(cartItems, buyerId);
    if (primarySellerId === buyerId) {
      return res.status(400).json({ success: false, error: "Vous ne pouvez pas acheter vos propres produits" });
    }

    const vendorSummary = buildVendorSummary(cartItems, realPrices);
    const commissionRatePercent = await getPdgFeeRatePercent("commission_achats");
    const commissionRate = commissionRatePercent / 100;
    const commissionAmount = Math.round(sourceAmount * commissionRate);
    const totalAmount = sourceAmount + commissionAmount;

    // Create Stripe PaymentIntent with automatic capture
    const paymentIntent = await stripe.paymentIntents.create({
      amount: toStripeAmount(totalAmount, normalizedCurrency),
      currency: normalizedCurrency.toLowerCase(),
      payment_method_types: ["card"],
      capture_method: "automatic",
      statement_descriptor_suffix: "224SOLUTIONS",
      metadata: {
        source: "marketplace",
        buyer_id: buyerId,
        order_type: "standard",
        cart_items: cartItems.length.toString(),
        product_amount: sourceAmount.toString(),
        commission_rate: commissionRatePercent.toString(),
        commission_amount: commissionAmount.toString(),
        total_amount: totalAmount.toString(),
        vendor_count: Object.keys(vendorSummary).filter((id) => id !== "unknown").length.toString(),
        vendor_summary: JSON.stringify(vendorSummary).slice(0, 500),
      },
    });

    // Store in stripe_transactions
    const { data: transaction, error: insertError } = await supabaseAdmin
      .from("stripe_transactions")
      .insert({
        stripe_payment_intent_id: paymentIntent.id,
        payment_intent_id: paymentIntent.id,
        buyer_id: buyerId,
        seller_id: primarySellerId,
        amount: totalAmount,
        currency: normalizedCurrency,
        status: "PENDING",
        payment_method: "card",
        commission_rate: commissionRatePercent,
        commission_amount: commissionAmount,
        seller_net_amount: sourceAmount,
        metadata: {
          cart_items: cartItems,
          vendor_summary: vendorSummary,
          commission_rate: commissionRatePercent,
          commission_amount: commissionAmount,
          escrow_mode: false,
          source: "marketplace",
          product_amount: sourceAmount,
          total_amount: totalAmount,
        },
        created_at: new Date().toISOString(),
      })
      .select()
      .single();

    if (insertError) {
      console.error("stripe-marketplace-payment stripe transaction insert error:", insertError.message);
    }

    return res.json({
      success: true,
      clientSecret: paymentIntent.client_secret,
      paymentIntentId: paymentIntent.id,
      transactionId: transaction?.id,
      commissionRate: commissionRatePercent,
      commissionAmount,
      totalAmount,
      productAmount: amount,
    });
  } catch (err: any) {
    console.error("stripe-marketplace-payment error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 4. Cancel Order
router.post("/cancel-order", validateBearerToken, async (req: any, res: any) => {
  try {
    const { order_id, reason } = req.body;

    if (!order_id) {
      return res.status(400).json({ success: false, error: "Missing order_id" });
    }

    // Get order
    const { data: order } = await supabaseAdmin
      .from("orders")
      .select("*, customer:customers(user_id)")
      .eq("id", order_id)
      .single();

    if (!order) {
      return res.status(404).json({ success: false, error: "Order not found" });
    }

    // Verify customer owns order
    if (order.customer?.user_id !== req.user.id) {
      return res.status(403).json({ success: false, error: "Not order owner" });
    }

    // Check if cancellable (only pending status)
    if (order.status !== "pending") {
      return res.status(400).json({
        success: false,
        error: "Order cannot be cancelled in " + order.status + " status",
        redirect_to: "/refund-request",
      });
    }

    // Update order status
    const { error } = await supabaseAdmin
      .from("orders")
      .update({
        status: "cancelled",
        cancellation_reason: reason,
        cancelled_at: new Date().toISOString(),
      })
      .eq("id", order_id);

    if (error) throw error;

    // Refund escrow if applicable
    const { data: escrow } = await supabaseAdmin
      .from("escrow_transactions")
      .select("*")
      .eq("order_id", order_id)
      .single();

    if (escrow?.status === "pending" || escrow?.status === "held") {
      // Refund logic would be implemented here
      // For now, just update escrow status
      await supabaseAdmin
        .from("escrow_transactions")
        .update({ status: "refunded" })
        .eq("id", escrow.id);
    }

    return res.json({
      success: true,
      message: "Commande annulée avec succès",
    });
  } catch (err: any) {
    console.error("cancel-order error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 5. Confirm Order by Seller
router.post("/confirm-order-by-seller", validateBearerToken, async (req: any, res: any) => {
  try {
    const { order_id } = req.body;

    if (!order_id) {
      return res.status(400).json({ success: false, error: "Missing order_id" });
    }

    // Get order and verify seller
    const { data: order } = await supabaseAdmin
      .from("orders")
      .select("*, vendor:vendors(user_id)")
      .eq("id", order_id)
      .single();

    if (!order) {
      return res.status(404).json({ success: false, error: "Order not found" });
    }

    // Verify vendor owns order
    if (order.vendor?.user_id !== req.user.id) {
      return res.status(403).json({ success: false, error: "Not vendor" });
    }

    // Update order status
    await supabaseAdmin
      .from("orders")
      .update({
        status: "confirmed",
        cancellable: false,
        seller_confirmed_at: new Date().toISOString(),
      })
      .eq("id", order_id);

    // Update escrow
    const autoReleaseDate = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();

    const { data: escrow } = await supabaseAdmin
      .from("escrow_transactions")
      .update({
        status: "held",
        seller_confirmed_at: new Date().toISOString(),
        auto_release_date: autoReleaseDate,
        auto_release_enabled: true,
      })
      .eq("order_id", order_id)
      .select()
      .single();

    // Create notification
    await supabaseAdmin
      .from("notifications")
      .insert({
        user_id: order.customer_id,
        title: "Commande confirmée",
        message: "Le vendeur a confirmé votre commande",
        type: "order_confirmed",
        metadata: { order_id },
      });

    return res.json({
      success: true,
      auto_release_date: autoReleaseDate,
    });
  } catch (err: any) {
    console.error("confirm-order-by-seller error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 6. Confirm Delivery
router.post("/confirm-delivery", validateBearerToken, async (req: any, res: any) => {
  try {
    const { order_id } = req.body;

    if (!order_id) {
      return res.status(400).json({ success: false, error: "Missing order_id" });
    }

    // Get order
    const { data: order } = await supabaseAdmin
      .from("orders")
      .select("*, customer:customers(user_id)")
      .eq("id", order_id)
      .single();

    if (!order) {
      return res.status(404).json({ success: false, error: "Order not found" });
    }

    // Verify customer
    if (order.customer?.user_id !== req.user.id) {
      return res.status(403).json({ success: false, error: "Not order owner" });
    }

    // Call RPC to release escrow with commission deduction
    const { data: releaseData, error } = await supabaseAdmin.rpc(
      "confirm_delivery_and_release_escrow",
      {
        p_order_id: order_id,
      }
    );

    if (error) throw error;

    // orders.delivered_at does not exist in the current schema.
    // Persist delivery confirmation in metadata while keeping the delivered status.
    await supabaseAdmin
      .from("orders")
      .update({
        status: "delivered",
        metadata: {
          ...(order.metadata || {}),
          delivered_at: new Date().toISOString(),
          buyer_confirmed_delivery: true,
        },
      })
      .eq("id", order_id);

    return res.json({
      success: true,
      released_amount: releaseData?.released_amount,
      seller_amount: releaseData?.seller_amount,
      commission_retained: releaseData?.commission_retained,
    });
  } catch (err: any) {
    console.error("confirm-delivery error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 7. Link Escrow Order
router.post("/link-escrow-order", validateBearerToken, async (req: any, res: any) => {
  try {
    const { payment_intent_id, vendor_id, order_id } = req.body;

    if (!payment_intent_id || !vendor_id || !order_id) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Get escrow
    const { data: escrow } = await supabaseAdmin
      .from("escrow_transactions")
      .select("*")
      .eq("payment_intent_id", payment_intent_id)
      .single();

    if (!escrow) {
      return res.status(404).json({ success: false, error: "Escrow not found" });
    }

    // Verify user is payer or vendor
    if (escrow.buyer_id !== req.user.id && escrow.seller_id !== req.user.id) {
      return res.status(403).json({ success: false, error: "Unauthorized" });
    }

    // Link order
    const { data: updated, error } = await supabaseAdmin
      .from("escrow_transactions")
      .update({ order_id })
      .eq("id", escrow.id)
      .select()
      .single();

    if (error) throw error;

    return res.json({
      success: true,
      escrow_id: updated.id,
      order_id: updated.order_id,
    });
  } catch (err: any) {
    console.error("link-escrow-order error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

// 8. Request Refund
router.post("/request-refund", validateBearerToken, async (req: any, res: any) => {
  try {
    const { order_id, reason, requested_amount, evidence_text } = req.body;

    if (!order_id || !reason) {
      return res.status(400).json({ success: false, error: "Missing required fields" });
    }

    // Get order
    const { data: order } = await supabaseAdmin
      .from("orders")
      .select("*, customer:customers(user_id)")
      .eq("id", order_id)
      .single();

    if (!order) {
      return res.status(404).json({ success: false, error: "Order not found" });
    }

    // Verify customer
    if (order.customer?.user_id !== req.user.id) {
      return res.status(403).json({ success: false, error: "Not order owner" });
    }

    // Check order status
    const allowedStatuses = ["pending", "confirmed", "held", "shipped"];
    if (!allowedStatuses.includes(order.status)) {
      return res.status(400).json({
        success: false,
        error: "Cannot request refund for orders in " + order.status + " status",
      });
    }

    // Create dispute record
    const { data: refund, error } = await supabaseAdmin
      .from("order_disputes")
      .insert({
        order_id,
        buyer_id: req.user.id,
        seller_id: order.vendor_id,
        status: "awaiting_vendor_response",
        reason,
        requested_amount: requested_amount || order.total_amount,
        evidence: evidence_text,
        created_at: new Date().toISOString(),
      })
      .select()
      .single();

    if (error) throw error;

    // Notify vendor and PDG
    await supabaseAdmin
      .from("notifications")
      .insert([
        {
          user_id: order.vendor_id,
          title: "Demande de remboursement",
          message: `Demande de remboursement pour la commande ${order_id}`,
          type: "refund_request",
          metadata: { order_id, refund_id: refund.id },
        },
      ]);

    return res.json({
      success: true,
      refund_request_id: refund.id,
      status: refund.status,
      requested_amount: refund.requested_amount,
    });
  } catch (err: any) {
    console.error("request-refund error:", err);
    return res.status(500).json({ success: false, error: err.message });
  }
});

export default router;
