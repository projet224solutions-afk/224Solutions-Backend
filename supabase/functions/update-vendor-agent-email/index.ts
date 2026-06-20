/**
 * UPDATE VENDOR AGENT EMAIL - 224SOLUTIONS
 * Permet de modifier l'email d'un agent vendeur (Supabase Auth + vendor_agents)
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

    const { agent_id, new_email, vendor_id } = await req.json();

    console.log(`[UPDATE-VENDOR-AGENT-EMAIL] Mise à jour email pour agent: ${agent_id}`);

    if (!agent_id || !new_email) {
      return new Response(
        JSON.stringify({ success: false, error: "agent_id et new_email sont requis" }),
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

    // Récupérer l'agent
    const { data: agent, error: agentError } = await supabaseAdmin
      .from("vendor_agents")
      .select("id, user_id, email, vendor_id, name")
      .eq("id", agent_id)
      .single();

    if (agentError || !agent) {
      return new Response(
        JSON.stringify({ success: false, error: "Agent non trouvé" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier autorisation vendeur
    if (vendor_id && agent.vendor_id !== vendor_id) {
      return new Response(
        JSON.stringify({ success: false, error: "Vous n'êtes pas autorisé à modifier cet agent" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier unicité email
    const { data: existingAgent } = await supabaseAdmin
      .from("vendor_agents")
      .select("id")
      .eq("email", new_email.toLowerCase())
      .neq("id", agent_id)
      .maybeSingle();

    if (existingAgent) {
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un autre agent" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier dans auth.users
    const { data: authUsers } = await supabaseAdmin.auth.admin.listUsers();
    const emailAlreadyUsed = authUsers?.users?.some(
      (u) => u.email === new_email.toLowerCase() && u.id !== agent.user_id
    );

    if (emailAlreadyUsed) {
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un autre compte" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const oldEmail = agent.email;

    // Mettre à jour auth.users si user_id existe
    if (agent.user_id) {
      console.log(`[UPDATE-VENDOR-AGENT-EMAIL] Mise à jour auth.users: ${agent.user_id}`);
      
      const { error: authUpdateError } = await supabaseAdmin.auth.admin.updateUserById(
        agent.user_id,
        { email: new_email.toLowerCase(), email_confirm: true }
      );

      if (authUpdateError) {
        console.error(`[UPDATE-VENDOR-AGENT-EMAIL] Erreur auth:`, authUpdateError);
        return new Response(
          JSON.stringify({ success: false, error: `Erreur auth: ${authUpdateError.message}` }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Mettre à jour profil
      await supabaseAdmin
        .from("profiles")
        .update({ email: new_email.toLowerCase(), updated_at: new Date().toISOString() })
        .eq("id", agent.user_id);
    }

    // Mettre à jour vendor_agents
    const { error: dbError } = await supabaseAdmin
      .from("vendor_agents")
      .update({ email: new_email.toLowerCase(), updated_at: new Date().toISOString() })
      .eq("id", agent_id);

    if (dbError) {
      console.error(`[UPDATE-VENDOR-AGENT-EMAIL] Erreur DB:`, dbError);
      // Rollback auth
      if (agent.user_id) {
        await supabaseAdmin.auth.admin.updateUserById(agent.user_id, { email: oldEmail });
      }
      return new Response(
        JSON.stringify({ success: false, error: `Erreur DB: ${dbError.message}` }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[UPDATE-VENDOR-AGENT-EMAIL] ✅ Email modifié: ${oldEmail} -> ${new_email}`);

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: `Email de ${agent.name} modifié avec succès`,
        old_email: oldEmail,
        new_email: new_email.toLowerCase()
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("[UPDATE-VENDOR-AGENT-EMAIL] Erreur:", error);
    return new Response(
      JSON.stringify({ success: false, error: "Erreur serveur interne" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});