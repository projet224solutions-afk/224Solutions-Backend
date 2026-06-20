/**
 * 🔐 STRIPE PAYMENT INTENT - Création sécurisée
 * Edge Function pour créer un Payment Intent Stripe
 * 224Solutions - Paiement par carte bancaire
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[STRIPE] ${step}${detailsStr}`);
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Function started");

    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
    if (!stripeSecretKey) {
      throw new Error("Stripe secret key not configured");
    }

    // Vérifier l'authentification
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
      throw new Error("Non autorisé");
    }

    logStep("User authenticated", { userId: user.id });

    const { amount, currency = 'gnf', orderId, description } = await req.json();

    if (!amount || amount <= 0) {
      throw new Error("Montant invalide");
    }

    logStep("Creating Payment Intent", { amount, currency, orderId });

    // Créer le Payment Intent via l'API Stripe
    const response = await fetch('https://api.stripe.com/v1/payment_intents', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${stripeSecretKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({
        amount: Math.round(amount).toString(), // GNF n'a pas de centimes
        currency: currency.toLowerCase(),
        'metadata[order_id]': orderId || '',
        'metadata[user_id]': user.id,
        'metadata[description]': description || 'Paiement 224Solutions',
      }),
    });

    const paymentIntent = await response.json();

    if (!response.ok) {
      logStep("Stripe error", { error: paymentIntent.error });
      throw new Error(paymentIntent.error?.message || 'Erreur Stripe');
    }

    logStep("Payment Intent created", { 
      id: paymentIntent.id, 
      status: paymentIntent.status 
    });

    // Enregistrer dans la base de données pour le suivi
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    try {
      await supabaseAdmin.from('stripe_payments').insert({
        user_id: user.id,
        payment_intent_id: paymentIntent.id,
        amount: amount,
        currency: currency,
        status: paymentIntent.status,
        order_id: orderId,
        metadata: { description }
      });
    } catch (logError) {
      // Ne pas bloquer si l'insert échoue
      console.warn('Failed to log stripe payment:', logError);
    }

    return new Response(
      JSON.stringify({
        success: true,
        clientSecret: paymentIntent.client_secret,
        paymentIntentId: paymentIntent.id,
        status: paymentIntent.status,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Erreur inconnue';
    logStep("ERROR", { message: errorMessage });

    // IMPORTANT: renvoyer 200 pour que le frontend lise le JSON d'erreur
    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
