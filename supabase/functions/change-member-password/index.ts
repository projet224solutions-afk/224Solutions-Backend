/**
 * CHANGE MEMBER PASSWORD - 224SOLUTIONS
 * Permet à un membre de modifier son mot de passe
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as bcrypt from "https://deno.land/x/bcrypt@v0.4.1/mod.ts";

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

    const { member_id, current_password, new_password } = await req.json();

    console.log(`[CHANGE-MEMBER-PASSWORD] Changement mot de passe pour membre: ${member_id}`);

    // Validation
    if (!member_id || !current_password || !new_password) {
      return new Response(
        JSON.stringify({ success: false, message: "Tous les champs sont requis" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (new_password.length < 8) {
      return new Response(
        JSON.stringify({ success: false, message: "Le nouveau mot de passe doit contenir au moins 8 caractères" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Récupérer le membre
    const { data: member, error: memberError } = await supabaseAdmin
      .from("syndicate_workers")
      .select("*")
      .eq("id", member_id)
      .single();

    if (memberError || !member) {
      return new Response(
        JSON.stringify({ success: false, message: "Membre non trouvé" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!member.is_active) {
      return new Response(
        JSON.stringify({ success: false, message: "Ce compte est désactivé" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier le mot de passe actuel
    if (!member.password_hash) {
      return new Response(
        JSON.stringify({ success: false, message: "Ce compte n'a pas de mot de passe configuré" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const passwordMatch = await bcrypt.compare(current_password, member.password_hash);

    if (!passwordMatch) {
      // Logger la tentative échouée
      await supabaseAdmin
        .from("auth_login_logs")
        .insert({
          user_id: member_id,
          user_type: 'member',
          action: 'password_change_failed',
          ip_address: req.headers.get('x-forwarded-for') || 'unknown',
          user_agent: req.headers.get('user-agent') || 'unknown',
          success: false,
          failure_reason: 'Mot de passe actuel incorrect'
        });

      return new Response(
        JSON.stringify({ success: false, message: "Mot de passe actuel incorrect" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Hasher le nouveau mot de passe
    const salt = await bcrypt.genSalt(10);
    const newPasswordHash = await bcrypt.hash(new_password, salt);

    // Mettre à jour le mot de passe
    const { error: updateError } = await supabaseAdmin
      .from("syndicate_workers")
      .update({ password_hash: newPasswordHash })
      .eq("id", member_id);

    if (updateError) {
      console.error("[CHANGE-MEMBER-PASSWORD] Erreur mise à jour:", updateError);
      return new Response(
        JSON.stringify({ success: false, message: "Erreur lors de la mise à jour du mot de passe" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Logger le succès
    await supabaseAdmin
      .from("auth_login_logs")
      .insert({
        user_id: member_id,
        user_type: 'member',
        action: 'password_change',
        ip_address: req.headers.get('x-forwarded-for') || 'unknown',
        user_agent: req.headers.get('user-agent') || 'unknown',
        success: true
      });

    console.log(`[CHANGE-MEMBER-PASSWORD] ✅ Mot de passe modifié pour membre: ${member_id}`);

    return new Response(
      JSON.stringify({ success: true, message: "Mot de passe modifié avec succès" }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("[CHANGE-MEMBER-PASSWORD] Erreur:", error);
    return new Response(
      JSON.stringify({ success: false, message: "Erreur serveur interne" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
