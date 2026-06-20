/**
 * CREATE VENDOR AGENT - 224SOLUTIONS
 * Permet au vendeur de créer un agent avec email/mot de passe (Supabase Auth)
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

    const { 
      vendor_id,
      name, 
      email, 
      phone, 
      password,
      agent_type,
      permissions,
      can_create_sub_agent
    } = await req.json();

    console.log(`[CREATE-VENDOR-AGENT] Création agent pour vendor: ${vendor_id}`);

    // Validation
    if (!vendor_id || !name || !email || !password || !phone) {
      return new Response(
        JSON.stringify({ success: false, error: "Champs requis manquants" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (password.length < 8) {
      return new Response(
        JSON.stringify({ success: false, error: "Le mot de passe doit contenir au moins 8 caractères" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return new Response(
        JSON.stringify({ success: false, error: "Format d'email invalide" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier que l'email n'existe pas déjà dans vendor_agents
    const { data: existingAgent } = await supabaseAdmin
      .from("vendor_agents")
      .select("id")
      .eq("email", email.toLowerCase())
      .maybeSingle();

    if (existingAgent) {
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un autre agent" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier dans auth.users
    const { data: authUsers } = await supabaseAdmin.auth.admin.listUsers();
    const emailExists = authUsers?.users?.some(u => u.email === email.toLowerCase());
    
    if (emailExists) {
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un autre compte" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Créer l'utilisateur dans Supabase Auth
    console.log(`[CREATE-VENDOR-AGENT] Création utilisateur auth pour: ${email}`);
    
    const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
      email: email.toLowerCase(),
      password: password,
      email_confirm: true,
      user_metadata: {
        full_name: name,
        phone: phone,
        role: 'vendor_agent'
      }
    });

    if (authError || !authData.user) {
      console.error(`[CREATE-VENDOR-AGENT] Erreur auth:`, authError);
      return new Response(
        JSON.stringify({ success: false, error: authError?.message || "Erreur création compte" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[CREATE-VENDOR-AGENT] ✅ Utilisateur auth créé: ${authData.user.id}`);

    // Générer codes uniques
    const timestamp = Date.now().toString(36).toUpperCase();
    const randomPart = Math.random().toString(36).substring(2, 6).toUpperCase();
    const agentCode = `VAG${timestamp}${randomPart}`;
    const accessToken = crypto.randomUUID();

    // Créer l'agent dans vendor_agents
    const { data: agentData, error: agentError } = await supabaseAdmin
      .from("vendor_agents")
      .insert({
        vendor_id: vendor_id,
        user_id: authData.user.id,
        agent_code: agentCode,
        access_token: accessToken,
        name: name,
        email: email.toLowerCase(),
        phone: phone,
        agent_type: agent_type || 'commercial',
        permissions: permissions || { view_dashboard: true, access_communication: true },
        can_create_sub_agent: can_create_sub_agent || false,
        is_active: true,
      })
      .select()
      .single();

    if (agentError) {
      console.error(`[CREATE-VENDOR-AGENT] Erreur insertion agent:`, agentError);
      // Rollback: supprimer l'utilisateur auth créé
      await supabaseAdmin.auth.admin.deleteUser(authData.user.id);
      return new Response(
        JSON.stringify({ success: false, error: agentError.message }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Créer le profil
    await supabaseAdmin.from("profiles").upsert({
      id: authData.user.id,
      email: email.toLowerCase(),
      first_name: name.split(' ')[0] || name,
      last_name: name.split(' ').slice(1).join(' ') || '',
      phone: phone,
      role: 'vendor_agent',
    });

    console.log(`[CREATE-VENDOR-AGENT] ✅ Agent créé: ${agentData.id}`);

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: `Agent ${name} créé avec succès`,
        agent: {
          id: agentData.id,
          agent_code: agentCode,
          access_token: accessToken,
          email: email.toLowerCase()
        }
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("[CREATE-VENDOR-AGENT] Erreur:", error);
    return new Response(
      JSON.stringify({ success: false, error: "Erreur serveur interne" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});