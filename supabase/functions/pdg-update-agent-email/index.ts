/**
 * PDG UPDATE AGENT EMAIL - 224SOLUTIONS
 * Permet au PDG de modifier l'email d'un agent (mise à jour dans auth.users ET agents_management)
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    const { agent_id, new_email, pdg_id } = await req.json();

    console.log(`[PDG-UPDATE-AGENT-EMAIL] Requête reçue:`, { agent_id, new_email, pdg_id });

    // Validation des données
    if (!agent_id || !new_email) {
      console.log(`[PDG-UPDATE-AGENT-EMAIL] Données manquantes`);
      return new Response(
        JSON.stringify({ success: false, error: "agent_id et new_email sont requis" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Valider le format email
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(new_email)) {
      console.log(`[PDG-UPDATE-AGENT-EMAIL] Format email invalide:`, new_email);
      return new Response(
        JSON.stringify({ success: false, error: "Format d'email invalide" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Récupérer les données de l'agent
    const { data: agent, error: agentError } = await supabaseAdmin
      .from("agents_management")
      .select("id, user_id, email, pdg_id, name")
      .eq("id", agent_id)
      .single();

    if (agentError || !agent) {
      console.log(`[PDG-UPDATE-AGENT-EMAIL] Agent non trouvé:`, agentError);
      return new Response(
        JSON.stringify({ success: false, error: "Agent non trouvé" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier que le PDG a le droit de modifier cet agent (optionnel mais recommandé)
    if (pdg_id && agent.pdg_id !== pdg_id) {
      console.log(`[PDG-UPDATE-AGENT-EMAIL] PDG non autorisé: ${pdg_id} != ${agent.pdg_id}`);
      return new Response(
        JSON.stringify({ success: false, error: "Vous n'êtes pas autorisé à modifier cet agent" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier que l'email n'est pas déjà utilisé par un autre agent
    const { data: existingAgent } = await supabaseAdmin
      .from("agents_management")
      .select("id")
      .eq("email", new_email)
      .neq("id", agent_id)
      .maybeSingle();

    if (existingAgent) {
      console.log(`[PDG-UPDATE-AGENT-EMAIL] Email déjà utilisé par un autre agent`);
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un autre agent" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier aussi dans auth.users
    const { data: existingAuthUser } = await supabaseAdmin.auth.admin.listUsers();
    const emailAlreadyUsed = existingAuthUser?.users?.some(
      (u) => u.email === new_email && u.id !== agent.user_id
    );

    if (emailAlreadyUsed) {
      console.log(`[PDG-UPDATE-AGENT-EMAIL] Email déjà utilisé dans auth.users`);
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un autre compte" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const oldEmail = agent.email;

    // ÉTAPE 1: Mettre à jour l'email dans Supabase Auth (si user_id existe)
    if (agent.user_id) {
      console.log(`[PDG-UPDATE-AGENT-EMAIL] Mise à jour auth.users pour user_id: ${agent.user_id}`);
      
      const { error: authUpdateError } = await supabaseAdmin.auth.admin.updateUserById(
        agent.user_id,
        { 
          email: new_email,
          email_confirm: true // Confirmer automatiquement le nouvel email
        }
      );

      if (authUpdateError) {
        console.error(`[PDG-UPDATE-AGENT-EMAIL] Erreur mise à jour auth:`, authUpdateError);
        return new Response(
          JSON.stringify({ 
            success: false, 
            error: `Erreur mise à jour authentification: ${authUpdateError.message}` 
          }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      console.log(`[PDG-UPDATE-AGENT-EMAIL] ✅ auth.users mis à jour`);

      // Mettre aussi à jour le profil si existant
      const { error: profileError } = await supabaseAdmin
        .from("profiles")
        .update({ email: new_email, updated_at: new Date().toISOString() })
        .eq("id", agent.user_id);

      if (profileError) {
        console.warn(`[PDG-UPDATE-AGENT-EMAIL] Avertissement profil:`, profileError);
        // Ne pas bloquer si le profil n'existe pas
      }
    }

    // ÉTAPE 2: Mettre à jour l'email dans agents_management
    console.log(`[PDG-UPDATE-AGENT-EMAIL] Mise à jour agents_management`);
    
    const { error: dbUpdateError } = await supabaseAdmin
      .from("agents_management")
      .update({ 
        email: new_email, 
        updated_at: new Date().toISOString() 
      })
      .eq("id", agent_id);

    if (dbUpdateError) {
      console.error(`[PDG-UPDATE-AGENT-EMAIL] Erreur mise à jour DB:`, dbUpdateError);
      
      // Rollback de auth.users si la mise à jour DB échoue
      if (agent.user_id) {
        await supabaseAdmin.auth.admin.updateUserById(agent.user_id, { email: oldEmail });
      }
      
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: `Erreur mise à jour base de données: ${dbUpdateError.message}` 
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[PDG-UPDATE-AGENT-EMAIL] ✅ Email modifié avec succès: ${oldEmail} -> ${new_email}`);

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: `Email de l'agent ${agent.name} modifié avec succès`,
        old_email: oldEmail,
        new_email: new_email
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("[PDG-UPDATE-AGENT-EMAIL] Erreur:", error);
    return new Response(
      JSON.stringify({ success: false, error: "Erreur serveur interne" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
