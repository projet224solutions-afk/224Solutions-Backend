/**
 * 💳 PROCESS PAYMENT LINK - Traitement d'un paiement via lien
 * Gère: wallet 224SOLUTIONS, carte bancaire (Stripe), Orange Money (ChapChapPay)
 * Crédite automatiquement le wallet du vendeur/prestataire après paiement confirmé
 * 224SOLUTIONS
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  console.log(`[PROCESS-PAYMENT-LINK] ${step}${details ? ` - ${JSON.stringify(details)}` : ''}`);
};

import { getPdgFeeRate, FEE_KEYS } from "../_shared/pdg-fees.ts";

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Optionally authenticate (connected user)
    let userId: string | null = null;
    const authHeader = req.headers.get('Authorization');
    if (authHeader?.startsWith('Bearer ')) {
      const supabaseClient = createClient(
        Deno.env.get('SUPABASE_URL') ?? '',
        Deno.env.get('SUPABASE_ANON_KEY') ?? '',
        { global: { headers: { Authorization: authHeader } } }
      );
      const { data: { user } } = await supabaseClient.auth.getUser();
      if (user) userId = user.id;
    }

    const {
      token,
      paymentMethod, // 'wallet' | 'card' | 'orange_money' | 'mtn_momo'
      customerName,
      customerEmail,
      customerPhone,
      paymentIntentId,
      // For wallet payment
      walletPin,
    } = await req.json();

    if (!token || !paymentMethod) {
      return new Response(
        JSON.stringify({ success: false, error: 'Token et méthode de paiement requis' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 1. Fetch and validate link
    const { data: link, error: linkError } = await supabaseAdmin
      .from('payment_links')
      .select('*')
      .eq('token', token)
      .maybeSingle();

    if (linkError || !link) {
      return new Response(
        JSON.stringify({ success: false, error: 'Lien de paiement introuvable' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Validate status
    if (link.status !== 'pending') {
      return new Response(
        JSON.stringify({ success: false, error: `Ce lien est déjà ${link.status === 'paid' || link.status === 'success' ? 'payé' : link.status}` }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check expiry
    if (link.expires_at && new Date(link.expires_at) < new Date()) {
      await supabaseAdmin.from('payment_links').update({ status: 'expired' }).eq('id', link.id);
      return new Response(
        JSON.stringify({ success: false, error: 'Ce lien de paiement a expiré' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check single use
    if (link.is_single_use && link.use_count > 0) {
      return new Response(
        JSON.stringify({ success: false, error: 'Ce lien a déjà été utilisé' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const payAmount = link.total || link.montant;
    const ownerUserId = link.owner_user_id;
    logStep("Link validated", { linkId: link.id, amount: payAmount, ownerUserId });

    // Get commission rate
    const feeKey = link.link_type === 'service' ? FEE_KEYS.SERVICE_COMMISSION : FEE_KEYS.PURCHASE_COMMISSION;
    const commissionRate = await getPdgFeeRate(supabaseAdmin, feeKey);
    const platformFee = Math.round(payAmount * (commissionRate / 100));
    const netAmount = payAmount - platformFee;

    // ──────── WALLET PAYMENT ────────
    if (paymentMethod === 'wallet') {
      if (!userId) {
        return new Response(
          JSON.stringify({ success: false, error: 'Connexion requise pour payer avec le wallet' }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Get buyer wallet
      const { data: buyerWallet } = await supabaseAdmin
        .from('wallets')
        .select('id, balance, currency')
        .eq('user_id', userId)
        .maybeSingle();

      if (!buyerWallet) {
        return new Response(
          JSON.stringify({ success: false, error: 'Wallet introuvable' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      if (buyerWallet.balance < payAmount) {
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: 'Solde insuffisant',
            currentBalance: buyerWallet.balance,
            required: payAmount 
          }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Debit buyer
      const { error: debitError } = await supabaseAdmin
        .from('wallets')
        .update({ balance: buyerWallet.balance - payAmount })
        .eq('id', buyerWallet.id);

      if (debitError) throw new Error('Erreur débit wallet: ' + debitError.message);

      // Credit seller wallet
      let walletTxId: string | null = null;
      if (ownerUserId) {
        const { data: sellerWallet } = await supabaseAdmin
          .from('wallets')
          .select('id, balance')
          .eq('user_id', ownerUserId)
          .maybeSingle();

        if (sellerWallet) {
          await supabaseAdmin
            .from('wallets')
            .update({ balance: sellerWallet.balance + netAmount })
            .eq('id', sellerWallet.id);

          const txId = `PLK-${Date.now()}-${Math.random().toString(36).substr(2, 6).toUpperCase()}`;
          walletTxId = txId;

          await supabaseAdmin.from('wallet_transactions').insert({
            transaction_id: txId,
            sender_wallet_id: buyerWallet.id,
            receiver_wallet_id: sellerWallet.id,
            sender_user_id: userId,
            receiver_user_id: ownerUserId,
            amount: payAmount,
            fee: platformFee,
            net_amount: netAmount,
            currency: link.devise || 'GNF',
            transaction_type: 'payment' as any,
            status: 'completed' as any,
            description: `Paiement lien: ${link.title || link.produit}`,
            reference_id: link.payment_id,
            metadata: {
              payment_link_id: link.id,
              link_type: link.link_type,
              commission_rate: commissionRate,
            },
          });

          logStep("Wallet payment completed", { txId, netAmount, platformFee });
        }
      }

      // Update link status
      await supabaseAdmin.from('payment_links').update({
        status: 'success',
        paid_at: new Date().toISOString(),
        payment_method: 'wallet',
        transaction_id: walletTxId,
        customer_name: customerName || null,
        customer_email: customerEmail || null,
        customer_phone: customerPhone || null,
        use_count: (link.use_count || 0) + 1,
        platform_fee: platformFee,
        net_amount: netAmount,
        gross_amount: payAmount,
        wallet_credit_status: 'credited',
        wallet_transaction_id: walletTxId,
      }).eq('id', link.id);

      return new Response(
        JSON.stringify({
          success: true,
          paymentMethod: 'wallet',
          transactionId: walletTxId,
          amount: payAmount,
          platformFee,
          netAmount,
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ──────── CARD PAYMENT (Stripe) ────────
    if (paymentMethod === 'card') {
      const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
      if (!stripeKey) {
        return new Response(
          JSON.stringify({ success: false, error: 'Paiement par carte non disponible' }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      const { default: Stripe } = await import("https://esm.sh/stripe@14.10.0?target=deno");
      const stripe = new Stripe(stripeKey, { apiVersion: '2023-10-16', httpClient: Stripe.createFetchHttpClient() });

      // Step 2: finalize a confirmed PaymentIntent from client-side Stripe Elements
      if (paymentIntentId) {
        if (link.transaction_id && link.transaction_id !== paymentIntentId) {
          return new Response(
            JSON.stringify({ success: false, error: 'PaymentIntent invalide pour ce lien' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
        const metadataLinkId = paymentIntent.metadata?.payment_link_id;
        const metadataToken = paymentIntent.metadata?.payment_link_token;

        if (metadataLinkId !== link.id || metadataToken !== token) {
          return new Response(
            JSON.stringify({ success: false, error: 'Ce paiement ne correspond pas au lien fourni' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        if (paymentIntent.status !== 'succeeded') {
          return new Response(
            JSON.stringify({
              success: false,
              error: paymentIntent.status === 'processing'
                ? 'Paiement en cours de traitement'
                : `Paiement non confirmé (${paymentIntent.status})`,
              paymentIntentStatus: paymentIntent.status,
            }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        await supabaseAdmin.from('payment_links').update({
          status: 'success',
          paid_at: new Date().toISOString(),
          payment_method: 'card',
          transaction_id: paymentIntent.id,
          customer_name: customerName || null,
          customer_email: customerEmail || null,
          customer_phone: customerPhone || null,
          use_count: (link.use_count || 0) + 1,
          platform_fee: platformFee,
          net_amount: netAmount,
          gross_amount: payAmount,
          wallet_credit_status: 'pending_settlement',
        }).eq('id', link.id);

        logStep('Card payment confirmed', { paymentIntentId: paymentIntent.id, linkId: link.id });

        return new Response(
          JSON.stringify({
            success: true,
            paymentMethod: 'card',
            confirmed: true,
            paymentIntentId: paymentIntent.id,
            amount: payAmount,
          }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Step 1: create PaymentIntent and return clientSecret for Stripe Elements
      const paymentIntent = await stripe.paymentIntents.create({
        amount: Math.round(payAmount),
        currency: (link.devise || 'gnf').toLowerCase(),
        automatic_payment_methods: { enabled: true },
        metadata: {
          payment_link_id: link.id,
          payment_link_token: token,
          link_type: link.link_type,
          owner_user_id: ownerUserId || '',
          platform_fee: platformFee.toString(),
          net_amount: netAmount.toString(),
          customer_name: customerName || '',
          customer_email: customerEmail || '',
        },
      });

      // Update link with pending card payment
      await supabaseAdmin.from('payment_links').update({
        payment_method: 'card',
        transaction_id: paymentIntent.id,
        customer_name: customerName || null,
        customer_email: customerEmail || null,
        customer_phone: customerPhone || null,
        platform_fee: platformFee,
        net_amount: netAmount,
        gross_amount: payAmount,
        wallet_credit_status: 'pending_settlement',
      }).eq('id', link.id);

      return new Response(
        JSON.stringify({
          success: true,
          paymentMethod: 'card',
          clientSecret: paymentIntent.client_secret,
          paymentIntentId: paymentIntent.id,
          amount: payAmount,
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ──────── MOBILE MONEY (Orange Money / MTN) ────────
    if (paymentMethod === 'orange_money' || paymentMethod === 'mtn_momo') {
      if (!customerPhone) {
        return new Response(
          JSON.stringify({ success: false, error: 'Numéro de téléphone requis pour Mobile Money' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Update link status to processing
      await supabaseAdmin.from('payment_links').update({
        payment_method: paymentMethod,
        customer_name: customerName || null,
        customer_email: customerEmail || null,
        customer_phone: customerPhone,
        platform_fee: platformFee,
        net_amount: netAmount,
        gross_amount: payAmount,
        wallet_credit_status: 'pending_settlement',
      }).eq('id', link.id);

      // Delegate to ChapChapPay via existing flow
      return new Response(
        JSON.stringify({
          success: true,
          paymentMethod,
          requiresExternalPayment: true,
          amount: payAmount,
          currency: link.devise || 'GNF',
          linkId: link.id,
          linkToken: token,
          message: 'Initiez le paiement Mobile Money via ChapChapPay',
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify({ success: false, error: 'Méthode de paiement non supportée' }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (err) {
    const msg = err instanceof Error ? err.message : 'Erreur inconnue';
    logStep("ERROR", { message: msg });
    return new Response(
      JSON.stringify({ success: false, error: msg }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
