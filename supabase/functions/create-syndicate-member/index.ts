/**
 * CREATE SYNDICATE MEMBER - 224SOLUTIONS
 * Permet de créer un membre adhérent avec authentification (email + mot de passe)
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

    const { 
      bureau_id, 
      full_name, 
      email, 
      phone, 
      password,
      membership_type = 'individual',
      address
    } = await req.json();

    console.log(`[CREATE-SYNDICATE-MEMBER] Création membre pour bureau: ${bureau_id}`);

    // Validation
    if (!bureau_id || !full_name || !email || !password) {
      return new Response(
        JSON.stringify({ success: false, error: "bureau_id, full_name, email et password sont requis" }),
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

    // Vérifier que le bureau existe
    const { data: bureau, error: bureauError } = await supabaseAdmin
      .from("bureaus")
      .select("id, bureau_code, commune, prefecture")
      .eq("id", bureau_id)
      .single();

    if (bureauError || !bureau) {
      return new Response(
        JSON.stringify({ success: false, error: "Bureau non trouvé" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier unicité email dans syndicate_workers
    const { data: existingMember } = await supabaseAdmin
      .from("syndicate_workers")
      .select("id")
      .eq("email", email.toLowerCase())
      .maybeSingle();

    if (existingMember) {
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un membre existant" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Hasher le mot de passe
    const salt = await bcrypt.genSalt(10);
    const passwordHash = await bcrypt.hash(password, salt);

    // Générer un token d'accès unique
    const accessToken = crypto.randomUUID();
    const interfaceUrl = `/member/${accessToken}`;

    // Créer le membre dans syndicate_workers
    const { data: newMember, error: createError } = await supabaseAdmin
      .from("syndicate_workers")
      .insert({
        bureau_id: bureau_id,
        nom: full_name.trim(),
        email: email.toLowerCase().trim(),
        telephone: phone?.trim() || null,
        password_hash: passwordHash,
        access_level: 'standard',
        access_token: accessToken,
        interface_url: interfaceUrl,
        is_active: true,
        permissions: {
          view_members: false,
          add_members: false,
          edit_members: false,
          view_vehicles: true,
          add_vehicles: false,
          view_reports: false
        },
        role: 'member',
        membership_type: membership_type
      })
      .select()
      .single();

    if (createError) {
      console.error("[CREATE-SYNDICATE-MEMBER] Erreur création:", createError);
      return new Response(
        JSON.stringify({ success: false, error: `Erreur création: ${createError.message}` }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[CREATE-SYNDICATE-MEMBER] ✅ Membre créé: ${newMember.id}`);

    // Logger la création
    await supabaseAdmin
      .from("auth_login_logs")
      .insert({
        user_id: newMember.id,
        user_type: 'member',
        action: 'member_created',
        ip_address: req.headers.get('x-forwarded-for') || 'unknown',
        user_agent: req.headers.get('user-agent') || 'unknown',
        success: true
      });

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: `Membre ${full_name} créé avec succès`,
        member: {
          id: newMember.id,
          nom: newMember.nom,
          email: newMember.email,
          telephone: newMember.telephone,
          access_token: accessToken,
          interface_url: interfaceUrl
        }
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("[CREATE-SYNDICATE-MEMBER] Erreur:", error);
    return new Response(
      JSON.stringify({ success: false, error: "Erreur serveur interne" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
