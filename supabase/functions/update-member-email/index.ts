/**
 * UPDATE MEMBER EMAIL - 224SOLUTIONS
 * Permet à un membre de modifier son email
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
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
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    const { member_id, new_email } = await req.json();

    console.log(`[UPDATE-MEMBER-EMAIL] Mise à jour email pour membre: ${member_id}`);

    // Validation
    if (!member_id || !new_email) {
      return new Response(
        JSON.stringify({ success: false, error: "member_id et new_email sont requis" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(new_email)) {
      return new Response(
        JSON.stringify({ success: false, error: "Format d'email invalide" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Récupérer le membre
    const { data: member, error: memberError } = await supabaseAdmin
      .from("syndicate_workers")
      .select("id, email, nom")
      .eq("id", member_id)
      .single();

    if (memberError || !member) {
      return new Response(
        JSON.stringify({ success: false, error: "Membre non trouvé" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier unicité email
    const { data: existingMember } = await supabaseAdmin
      .from("syndicate_workers")
      .select("id")
      .eq("email", new_email.toLowerCase())
      .neq("id", member_id)
      .maybeSingle();

    if (existingMember) {
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un autre membre" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const oldEmail = member.email;

    // Mettre à jour l'email
    const { error: updateError } = await supabaseAdmin
      .from("syndicate_workers")
      .update({ email: new_email.toLowerCase() })
      .eq("id", member_id);

    if (updateError) {
      console.error("[UPDATE-MEMBER-EMAIL] Erreur mise à jour:", updateError);
      return new Response(
        JSON.stringify({ success: false, error: `Erreur mise à jour: ${updateError.message}` }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Logger le changement
    await supabaseAdmin
      .from("auth_login_logs")
      .insert({
        user_id: member_id,
        user_type: 'member',
        action: 'email_change',
        ip_address: req.headers.get('x-forwarded-for') || 'unknown',
        user_agent: req.headers.get('user-agent') || 'unknown',
        success: true
      });

    console.log(`[UPDATE-MEMBER-EMAIL] ✅ Email modifié: ${oldEmail} -> ${new_email}`);

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: `Email modifié avec succès`,
        old_email: oldEmail,
        new_email: new_email.toLowerCase()
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("[UPDATE-MEMBER-EMAIL] Erreur:", error);
    return new Response(
      JSON.stringify({ success: false, error: "Erreur serveur interne" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
