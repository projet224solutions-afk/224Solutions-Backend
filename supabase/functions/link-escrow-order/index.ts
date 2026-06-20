import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ success: false, error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    const supabaseAuth = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey);

    const { data: authData, error: authError } = await supabaseAuth.auth.getUser();
    if (authError || !authData?.user) {
      return new Response(JSON.stringify({ success: false, error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { payment_intent_id, vendor_id, order_id } = await req.json();

    if (!payment_intent_id || !vendor_id || !order_id) {
      return new Response(
        JSON.stringify({ success: false, error: "payment_intent_id, vendor_id et order_id sont requis" }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const { data: vendor, error: vendorError } = await supabaseAdmin
      .from("vendors")
      .select("user_id")
      .eq("id", vendor_id)
      .single();

    if (vendorError || !vendor?.user_id) {
      return new Response(JSON.stringify({ success: false, error: "Vendor not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: escrow, error: escrowError } = await supabaseAdmin
      .from("escrow_transactions")
      .select("id, order_id")
      .eq("stripe_payment_intent_id", payment_intent_id)
      .eq("payer_id", authData.user.id)
      .or(`receiver_id.eq.${vendor.user_id},seller_id.eq.${vendor.user_id}`)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (escrowError || !escrow) {
      return new Response(JSON.stringify({ success: false, error: "Escrow transaction not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (escrow.order_id && escrow.order_id !== order_id) {
      return new Response(
        JSON.stringify({ success: false, error: "Escrow already linked to another order" }),
        {
          status: 409,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const { error: updateError } = await supabaseAdmin
      .from("escrow_transactions")
      .update({ order_id })
      .eq("id", escrow.id);

    if (updateError) {
      return new Response(JSON.stringify({ success: false, error: "Failed to link escrow" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(
      JSON.stringify({ success: true, escrow_id: escrow.id, order_id }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error: unknown) {
    return new Response(
      JSON.stringify({ success: false, error: error instanceof Error ? error.message : "Unknown error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});