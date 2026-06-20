/**
 * UPDATE BUREAU EMAIL - 224SOLUTIONS
 * Permet de modifier l'email d'un bureau syndicat (Supabase Auth + bureaus)
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

    const { bureau_id, new_email } = await req.json();

    console.log(`[UPDATE-BUREAU-EMAIL] Mise à jour email pour bureau: ${bureau_id}`);

    if (!bureau_id || !new_email) {
      return new Response(
        JSON.stringify({ success: false, error: "bureau_id et new_email sont requis" }),
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

    // Récupérer le bureau
    const { data: bureau, error: bureauError } = await supabaseAdmin
      .from("bureaus")
      .select("id, user_id, president_email, bureau_code, president_name")
      .eq("id", bureau_id)
      .single();

    if (bureauError || !bureau) {
      return new Response(
        JSON.stringify({ success: false, error: "Bureau non trouvé" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier unicité email
    const { data: existingBureau } = await supabaseAdmin
      .from("bureaus")
      .select("id")
      .eq("president_email", new_email.toLowerCase())
      .neq("id", bureau_id)
      .maybeSingle();

    if (existingBureau) {
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un autre bureau" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier dans auth.users
    const { data: authUsers } = await supabaseAdmin.auth.admin.listUsers();
    const emailAlreadyUsed = authUsers?.users?.some(
      (u) => u.email === new_email.toLowerCase() && u.id !== bureau.user_id
    );

    if (emailAlreadyUsed) {
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un autre compte" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const oldEmail = bureau.president_email;

    // Mettre à jour auth.users si user_id existe
    if (bureau.user_id) {
      console.log(`[UPDATE-BUREAU-EMAIL] Mise à jour auth.users: ${bureau.user_id}`);
      
      const { error: authUpdateError } = await supabaseAdmin.auth.admin.updateUserById(
        bureau.user_id,
        { email: new_email.toLowerCase(), email_confirm: true }
      );

      if (authUpdateError) {
        console.error(`[UPDATE-BUREAU-EMAIL] Erreur auth:`, authUpdateError);
        return new Response(
          JSON.stringify({ success: false, error: `Erreur auth: ${authUpdateError.message}` }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Mettre à jour profil
      await supabaseAdmin
        .from("profiles")
        .update({ email: new_email.toLowerCase(), updated_at: new Date().toISOString() })
        .eq("id", bureau.user_id);
    }

    // Mettre à jour bureaus
    const { error: dbError } = await supabaseAdmin
      .from("bureaus")
      .update({ president_email: new_email.toLowerCase() })
      .eq("id", bureau_id);

    if (dbError) {
      console.error(`[UPDATE-BUREAU-EMAIL] Erreur DB:`, dbError);
      // Rollback auth
      if (bureau.user_id) {
        await supabaseAdmin.auth.admin.updateUserById(bureau.user_id, { email: oldEmail });
      }
      return new Response(
        JSON.stringify({ success: false, error: `Erreur DB: ${dbError.message}` }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[UPDATE-BUREAU-EMAIL] ✅ Email modifié: ${oldEmail} -> ${new_email}`);

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: `Email du bureau ${bureau.bureau_code} modifié avec succès`,
        old_email: oldEmail,
        new_email: new_email.toLowerCase()
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("[UPDATE-BUREAU-EMAIL] Erreur:", error);
    return new Response(
      JSON.stringify({ success: false, error: "Erreur serveur interne" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});