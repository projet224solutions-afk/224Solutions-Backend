import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // Auth check
    const authHeader = req.headers.get("Authorization");
    const supabaseClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader || "" } },
    });
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Non authentifié" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { order_id } = await req.json();
    if (!order_id) {
      return new Response(JSON.stringify({ error: "order_id requis" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey);

    // Verify vendor owns the order
    const { data: order, error: orderError } = await supabaseAdmin
      .from("orders")
      .select("id, vendor_id, customer_id, status, cancellable")
      .eq("id", order_id)
      .single();

    if (orderError || !order) {
      return new Response(JSON.stringify({ error: "Commande introuvable" }), {
        status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (order.vendor_id !== user.id) {
      return new Response(JSON.stringify({ error: "Non autorisé" }), {
        status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const now = new Date().toISOString();
    const autoReleaseDate = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();

    // Update order: lock cancellation, set confirmed status
    await supabaseAdmin.from("orders").update({
      cancellable: false,
      status: "confirmed",
      updated_at: now,
    }).eq("id", order_id);

    // Update escrow: set seller_confirmed_at and auto_release_date
    await supabaseAdmin.from("escrow_transactions").update({
      seller_confirmed_at: now,
      auto_release_date: autoReleaseDate,
      auto_release_enabled: true,
    }).eq("order_id", order_id).in("status", ["pending", "held"]);

    // Notify buyer
    await supabaseAdmin.from("notifications").insert({
      user_id: order.customer_id,
      title: "Commande confirmée par le vendeur",
      message: "Votre commande a été confirmée. Vous avez 7 jours pour confirmer la réception ou ouvrir un litige.",
      type: "order",
      metadata: { order_id, action: "seller_confirmed", auto_release_date: autoReleaseDate },
    });

    console.log(`✅ Order ${order_id} confirmed by seller ${user.id}`);

    return new Response(JSON.stringify({
      success: true,
      auto_release_date: autoReleaseDate,
    }), { headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (error) {
    console.error("❌ confirm-order-by-seller error:", error);
    return new Response(JSON.stringify({ error: "Erreur interne" }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
