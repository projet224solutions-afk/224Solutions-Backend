/**
 * MARKETPLACE ESCROW PAYMENT
 * Crée un PaymentIntent Stripe en capture manuelle + escrow_transactions
 * Les fonds sont bloqués jusqu'à confirmation de livraison par l'acheteur
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@14.10.0?target=deno";
import { getPdgFeeRate, FEE_KEYS } from "../_shared/pdg-fees.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  console.log(`[MARKETPLACE-ESCROW] ${step}${details ? ` - ${JSON.stringify(details)}` : ""}`);
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!stripeSecretKey) throw new Error("STRIPE_SECRET_KEY not configured");

    // Auth user
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    );

    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) throw new Error("Non autorisé");
    logStep("User authenticated", { userId: user.id });

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    const {
      amount,
      currency = 'gnf',
      cartItems = [],
      description,
    } = await req.json();

    if (!amount || amount <= 0) throw new Error("Montant invalide");

    // Zero-decimal currencies (Stripe requires amount as-is, not ×100)
    const ZERO_DECIMAL = new Set(['gnf','xof','xaf','bif','clp','djf','jpy','kmf','krw','mga','pyg','rwf','ugx','vnd','vuv','xpf']);
    const isZeroDecimal = ZERO_DECIMAL.has(currency.toLowerCase());

    // Commission dynamique
    const commissionRate = await getPdgFeeRate(supabaseAdmin, FEE_KEYS.PURCHASE_COMMISSION);
    const commissionAmount = Math.round(amount * (commissionRate / 100));
    const totalAmount = amount + commissionAmount;

    // Convert to Stripe amount (multiply by 100 for non-zero-decimal currencies)
    const stripeAmount = isZeroDecimal ? Math.round(totalAmount) : Math.round(totalAmount * 100);

    logStep("Payment details", { productAmount: amount, commissionRate, commissionAmount, totalAmount, stripeAmount, isZeroDecimal });

    // Résumé vendeurs
    const vendorSummary: Record<string, number> = {};
    if (cartItems.length > 0) {
      for (const item of cartItems) {
        const vid = item.vendorId || 'unknown';
        vendorSummary[vid] = (vendorSummary[vid] || 0) + (item.price * (item.quantity || 1));
      }
    }

    const stripe = new Stripe(stripeSecretKey, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient(),
    });

    // *** CAPTURE MANUELLE = ESCROW ***
    const paymentIntent = await stripe.paymentIntents.create({
      amount: stripeAmount,
      currency: currency.toLowerCase(),
      capture_method: 'manual',
      automatic_payment_methods: { enabled: true },
      metadata: {
        source: 'marketplace_escrow',
        buyer_id: user.id,
        product_amount: amount.toString(),
        commission_rate: commissionRate.toString(),
        commission_amount: commissionAmount.toString(),
        total_amount: totalAmount.toString(),
        vendor_count: Object.keys(vendorSummary).length.toString(),
        vendor_summary: JSON.stringify(vendorSummary).substring(0, 500),
        items_count: cartItems.length.toString(),
        description: description || 'Achat Marketplace Escrow 224Solutions',
      },
    });

    logStep("PaymentIntent created (manual capture)", { id: paymentIntent.id });

    // Enregistrer la transaction stripe
    const { data: transaction, error: insertError } = await supabaseAdmin
      .from('stripe_transactions')
      .insert({
        stripe_payment_intent_id: paymentIntent.id,
        buyer_id: user.id,
        seller_id: Object.keys(vendorSummary)[0] || null,
        amount: totalAmount,
        currency: currency.toUpperCase(),
        commission_rate: commissionRate,
        commission_amount: commissionAmount,
        seller_net_amount: amount,
        status: 'PENDING',
        payment_method: 'card',
        metadata: {
          source: 'marketplace_escrow',
          vendor_summary: vendorSummary,
          cart_items: cartItems.map((i: any) => ({
            id: i.id, name: i.name, price: i.price,
            quantity: i.quantity || 1, vendorId: i.vendorId,
          })),
          product_amount: amount,
          total_amount: totalAmount,
        },
      })
      .select('id')
      .single();

    if (insertError) {
      logStep("Error inserting transaction", { error: insertError.message });
    }

    // Créer un escrow_transactions par vendeur
    const escrowIds: string[] = [];
    const vendorEntries = Object.entries(vendorSummary).filter(([k]) => k !== 'unknown');

    for (const [vendorId, vendorAmount] of vendorEntries) {
      // Récupérer le user_id du vendeur
      const { data: vendorData } = await supabaseAdmin
        .from('vendors')
        .select('user_id')
        .eq('id', vendorId)
        .single();

      const sellerUserId = vendorData?.user_id || vendorId;
      const vendorCommission = Math.round((vendorAmount as number) * (commissionRate / 100));

      const { data: escrow, error: escrowError } = await supabaseAdmin
        .from('escrow_transactions')
        .insert({
          payer_id: user.id,
          receiver_id: sellerUserId,
          buyer_id: user.id,
          seller_id: sellerUserId,
          amount: (vendorAmount as number) + vendorCommission,
          currency: currency.toUpperCase(),
          status: 'pending',
          stripe_payment_intent_id: paymentIntent.id,
          commission_amount: vendorCommission,
          commission_percent: commissionRate,
          metadata: {
            source: 'marketplace_escrow',
            vendor_id: vendorId,
            product_amount: vendorAmount,
            commission_amount: vendorCommission,
            commission_rate: commissionRate,
            stripe_transaction_id: transaction?.id,
          },
        })
        .select('id')
        .single();

      if (escrowError) {
        logStep("Error creating escrow for vendor", { vendorId, error: escrowError.message });
      } else if (escrow) {
        escrowIds.push(escrow.id);
        logStep("Escrow created", { escrowId: escrow.id, vendorId, amount: vendorAmount });
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        clientSecret: paymentIntent.client_secret,
        paymentIntentId: paymentIntent.id,
        transactionId: transaction?.id,
        escrowIds,
        commissionRate,
        commissionAmount,
        totalAmount,
        productAmount: amount,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Erreur inconnue';
    logStep("ERROR", { message: errorMessage });
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
