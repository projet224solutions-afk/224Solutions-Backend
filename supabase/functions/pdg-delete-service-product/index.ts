import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ success: false, error: "Non authentifié" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 },
      );
    }

    const token = authHeader.replace("Bearer ", "");

    const supabaseUser = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      {
        global: {
          headers: { Authorization: authHeader },
        },
      },
    );

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false, autoRefreshToken: false } },
    );

    const { data: userData, error: authError } = await supabaseUser.auth.getUser(token);
    if (authError || !userData.user) {
      return new Response(
        JSON.stringify({ success: false, error: "Token invalide" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 },
      );
    }

    const userId = userData.user.id;

    const { productId } = await req.json();
    if (!productId) {
      return new Response(
        JSON.stringify({ success: false, error: "productId requis" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 400 },
      );
    }

    // Autorisation: PDG (pdg_management) OU admin/ceo (profiles.role)
    const [pdgCheck, profileCheck] = await Promise.all([
      supabaseAdmin.from("pdg_management").select("id").eq("user_id", userId).maybeSingle(),
      supabaseAdmin.from("profiles").select("role").eq("id", userId).maybeSingle(),
    ]);

    const isPDG = !!pdgCheck.data;
    const role = (profileCheck.data as any)?.role as string | undefined;
    const isAdmin = !!role && ["admin", "ceo"].includes(role);

    if (!isPDG && !isAdmin) {
      return new Response(
        JSON.stringify({ success: false, error: "Accès non autorisé" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 403 },
      );
    }

    const { data: existing } = await supabaseAdmin
      .from("service_products")
      .select("id, name, professional_service_id")
      .eq("id", productId)
      .maybeSingle();

    if (!existing) {
      return new Response(
        JSON.stringify({ success: true, message: "Déjà supprimé" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 },
      );
    }

    const { error: deleteError } = await supabaseAdmin
      .from("service_products")
      .delete()
      .eq("id", productId);

    if (deleteError) {
      throw deleteError;
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: "Produit numérique supprimé",
        deleted: existing,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 },
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("[pdg-delete-service-product] error:", message);
    return new Response(
      JSON.stringify({ success: false, error: message }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 500 },
    );
  }
});
