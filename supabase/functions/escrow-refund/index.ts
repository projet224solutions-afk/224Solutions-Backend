import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    console.log("💰 [Escrow Refund] Starting refund");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // Get JWT token
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ success: false, error: "Unauthorized" }),
        {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // Verify user
    const { data: { user }, error: authError } = await supabase.auth.getUser(
      authHeader.replace("Bearer ", "")
    );

    if (authError || !user) {
      return new Response(
        JSON.stringify({ success: false, error: "Unauthorized" }),
        {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // Check if user is admin (CEO or admin role)
    const { data: profile } = await supabase
      .from("profiles")
      .select("role")
      .eq("id", user.id)
      .single();

    if (!profile || (profile.role !== 'admin' && profile.role !== 'ceo')) {
      console.log("❌ User not authorized - admin/CEO only");
      return new Response(
        JSON.stringify({ success: false, error: "Admin or CEO authorization required" }),
        {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    console.log(`✅ Admin verified: ${user.id} (${profile.role})`);

    // Get request body
    const { escrow_id, reason, refund_amount } = await req.json();

    if (!escrow_id || !reason) {
      console.error("❌ Missing required fields");
      return new Response(
        JSON.stringify({
          success: false,
          error: "escrow_id and reason are required",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    console.log(`📝 Refunding escrow: ${escrow_id} by admin: ${user.id}`);
    console.log(`Reason: ${reason}`);
    if (refund_amount) {
      console.log(`Partial refund amount: ${refund_amount}`);
    }

    // Get escrow details before refund
    const { data: escrow, error: fetchError } = await supabase
      .from("escrow_transactions")
      .select("*")
      .eq("id", escrow_id)
      .single();

    if (fetchError || !escrow) {
      console.error("❌ Escrow not found");
      return new Response(
        JSON.stringify({
          success: false,
          error: "Escrow transaction not found",
        }),
        {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // If Stripe PaymentIntent exists, create refund
    if (escrow.stripe_payment_intent_id) {
      console.log(`💳 Processing Stripe refund for PaymentIntent: ${escrow.stripe_payment_intent_id}`);
      
      const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
      if (stripeKey) {
        try {
          const Stripe = (await import("https://esm.sh/stripe@18.5.0")).default;
          const stripe = new Stripe(stripeKey, { apiVersion: "2025-08-27.basil" });
          
          // Retrieve PaymentIntent to check status
          const pi = await stripe.paymentIntents.retrieve(escrow.stripe_payment_intent_id);
          
          if (pi.status === 'requires_capture') {
            // Payment not captured yet: cancel the PaymentIntent
            console.log(`🚫 Canceling uncaptured PaymentIntent`);
            await stripe.paymentIntents.cancel(escrow.stripe_payment_intent_id);
            
            await supabase.from("escrow_action_logs").insert({
              escrow_id: escrow_id,
              action_type: 'stripe_canceled',
              performed_by: user.id,
              notes: `Stripe PaymentIntent canceled (hold released)`,
              metadata: { stripe_payment_intent_id: pi.id, reason },
            });
          } else if (pi.charges?.data && pi.charges.data.length > 0) {
            // Payment captured: create refund
            const charge = pi.charges.data[0];
            console.log(`💸 Creating refund for charge: ${charge.id}`);
            
            const zeroDecimalCurrencies = ['BIF','CLP','DJF','GNF','JPY','KMF','KRW','MGA','PYG','RWF','VUV','XAF','XOF','XPF'];
            let refundParams: any = { charge: charge.id };
            
            if (refund_amount) {
              const stripeAmount = Math.round(parseFloat(refund_amount.toString()) * 
                (zeroDecimalCurrencies.includes(escrow.currency.toUpperCase()) ? 1 : 100));
              refundParams.amount = stripeAmount;
              console.log(`Partial refund: ${stripeAmount} ${escrow.currency}`);
            }
            
            const refund = await stripe.refunds.create(refundParams);
            console.log(`✅ Stripe refund created: ${refund.id}`);
            
            await supabase.from("escrow_action_logs").insert({
              escrow_id: escrow_id,
              action_type: 'stripe_refunded',
              performed_by: user.id,
              notes: `Stripe refund created: ${refund.id}${refund_amount ? ` (partial: ${refund_amount})` : ''}`,
              metadata: {
                stripe_refund_id: refund.id,
                refund_amount: refund_amount || escrow.amount,
                reason,
              },
            });
          }
        } catch (stripeError) {
          console.error("❌ Stripe refund error:", stripeError);
          const errorMessage = stripeError instanceof Error ? stripeError.message : 'Unknown Stripe error';
          return new Response(
            JSON.stringify({
              success: false,
              error: `Stripe refund failed: ${errorMessage}`,
            }),
            {
              status: 500,
              headers: { ...corsHeaders, "Content-Type": "application/json" },
            }
          );
        }
      }
    }

    // Call the database function to refund
    const { data, error } = await supabase.rpc("refund_escrow_funds", {
      p_escrow_id: escrow_id,
      p_admin_id: user.id,
      p_reason: reason,
    });

    if (error) {
      console.error("❌ Error refunding escrow:", error);
      throw error;
    }

    console.log(`✅ Escrow refunded: ${escrow_id}`);

    // Send notification to payer (buyer)
    await supabase.from("communication_notifications").insert({
      user_id: escrow.payer_id,
      type: "escrow_refunded",
      title: "Remboursement effectué",
      body: `Remboursement effectué par 224SOLUTIONS : ${escrow.amount} ${escrow.currency}. Raison: ${reason}`,
      metadata: {
        escrow_id,
        amount: escrow.amount,
        currency: escrow.currency,
        reason,
      },
    });

    // Send notification to receiver (seller)
    await supabase.from("communication_notifications").insert({
      user_id: escrow.receiver_id,
      type: "escrow_refunded",
      title: "Transaction remboursée",
      body: `La transaction de ${escrow.amount} ${escrow.currency} a été remboursée au client. Raison: ${reason}`,
      metadata: {
        escrow_id,
        amount: escrow.amount,
        currency: escrow.currency,
        reason,
      },
    });

    console.log("📧 Notifications sent");

    return new Response(
      JSON.stringify({
        success: true,
        status: "refunded",
        message: "Remboursement effectué",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (error) {
    console.error("❌ Escrow refund error:", error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : "Unknown error",
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
