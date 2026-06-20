import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
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
    console.log("🔐 [Escrow Create] Starting transaction");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // Get request body
    const { buyer_id, seller_id, order_id, amount, currency = "GNF" } =
      await req.json();

    // Validate input
    if (!buyer_id || !seller_id || !amount) {
      console.error("❌ Missing required fields");
      return new Response(
        JSON.stringify({
          success: false,
          error: "buyer_id, seller_id, and amount are required",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    if (amount <= 0) {
      console.error("❌ Invalid amount");
      return new Response(
        JSON.stringify({
          success: false,
          error: "Amount must be greater than 0",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    console.log(
      `📝 Creating escrow: ${buyer_id} -> ${seller_id}, ${amount} ${currency}`
    );

    // Call the database function to create escrow and block funds
    const { data: escrow_id, error } = await supabase.rpc(
      "create_escrow_transaction",
      {
        p_buyer_id: buyer_id,
        p_seller_id: seller_id,
        p_order_id: order_id || null,
        p_amount: amount,
        p_currency: currency,
        p_metadata: {
          created_via: "edge_function",
          timestamp: new Date().toISOString(),
        },
      }
    );

    if (error) {
      console.error("❌ Error creating escrow:", error);
      throw error;
    }

    console.log(`✅ Escrow created: ${escrow_id}`);

    // Send notification to buyer
    await supabase.from("communication_notifications").insert({
      user_id: buyer_id,
      type: "escrow_created",
      title: "Paiement sécurisé",
      body: `Vos fonds (${amount} ${currency}) sont bloqués jusqu'à validation du vendeur.`,
      metadata: {
        escrow_id,
        amount,
        currency,
      },
    });

    // Send notification to seller
    await supabase.from("communication_notifications").insert({
      user_id: seller_id,
      type: "escrow_created",
      title: "Nouveau paiement escrow",
      body: `Un client a effectué un paiement de ${amount} ${currency} en attente de validation.`,
      metadata: {
        escrow_id,
        amount,
        currency,
      },
    });

    console.log("📧 Notifications sent");

    return new Response(
      JSON.stringify({
        success: true,
        status: "held",
        escrow_id,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (error) {
    console.error("❌ Escrow creation error:", error);
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
