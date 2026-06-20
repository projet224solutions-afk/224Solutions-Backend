import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const logStep = (step: string, details?: Record<string, unknown>) => {
  const timestamp = new Date().toISOString();
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[${timestamp}] [ADMIN-RELEASE-FUNDS] ${step}${detailsStr}`);
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    logStep("Release funds request received");

    // Get auth header
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      throw new Error("Non authentifié");
    }

    // Initialize Supabase clients
    const supabaseAnon = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? ""
    );
    
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { persistSession: false } }
    );

    // Verify user authentication
    const token = authHeader.replace("Bearer ", "");
    const { data: userData, error: userError } = await supabaseAnon.auth.getUser(token);
    
    if (userError || !userData.user) {
      throw new Error("Token invalide");
    }

    const adminId = userData.user.id;
    logStep("User authenticated", { adminId });

    // Verify admin role
    const { data: profile, error: profileError } = await supabaseAdmin
      .from("profiles")
      .select("role, full_name")
      .eq("id", adminId)
      .single();

    if (profileError || !profile) {
      throw new Error("Profil non trouvé");
    }

    if (!["admin", "ceo"].includes(profile.role as string)) {
      logStep("SECURITY: Unauthorized access attempt", { 
        userId: adminId, 
        role: profile.role 
      });
      throw new Error("Accès non autorisé - Rôle admin requis");
    }

    logStep("Admin verified", { role: profile.role, name: profile.full_name });

    // Parse request
    const body = await req.json();
    const { blockedFundId, reason } = body;

    if (!blockedFundId) {
      throw new Error("ID des fonds bloqués requis");
    }

    // Call the release function
    const { data: result, error: releaseError } = await supabaseAdmin.rpc(
      "release_vendor_funds",
      {
        p_blocked_fund_id: blockedFundId,
        p_admin_id: adminId,
        p_reason: reason || `Libéré par ${profile.full_name || 'Admin'}`,
      }
    );

    if (releaseError) {
      logStep("Release error", { error: releaseError.message });
      throw new Error(releaseError.message);
    }

    logStep("Funds released", { result });

    if (!result?.success) {
      throw new Error(result?.error || "Erreur lors de la libération des fonds");
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: "Fonds libérés avec succès",
        releasedAmount: result.released_amount,
        vendorId: result.vendor_id,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("ERROR", { message: errorMessage });

    return new Response(
      JSON.stringify({ success: false, error: errorMessage }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  }
});
