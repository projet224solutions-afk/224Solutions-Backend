/**
 * CREATE BUREAU WITH AUTH - 224SOLUTIONS
 * Permet au PDG de créer un bureau syndicat avec email/mot de passe (Supabase Auth)
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
      bureau_code,
      prefecture, 
      commune, 
      full_location,
      president_name,
      president_email,
      president_phone,
      password
    } = await req.json();

    console.log(`[CREATE-BUREAU-AUTH] Création bureau: ${bureau_code}`);

    // Validation
    if (!bureau_code || !prefecture || !commune || !president_email || !password) {
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
    if (!emailRegex.test(president_email)) {
      return new Response(
        JSON.stringify({ success: false, error: "Format d'email invalide" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier que le code bureau n'existe pas
    const { data: existingBureau } = await supabaseAdmin
      .from("bureaus")
      .select("id")
      .eq("bureau_code", bureau_code.toUpperCase())
      .maybeSingle();

    if (existingBureau) {
      return new Response(
        JSON.stringify({ success: false, error: "Ce code bureau existe déjà" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier que l'email n'existe pas déjà
    const { data: existingEmail } = await supabaseAdmin
      .from("bureaus")
      .select("id")
      .eq("president_email", president_email.toLowerCase())
      .maybeSingle();

    if (existingEmail) {
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un autre bureau" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Vérifier dans auth.users
    const { data: authUsers } = await supabaseAdmin.auth.admin.listUsers();
    const emailExists = authUsers?.users?.some(u => u.email === president_email.toLowerCase());
    
    if (emailExists) {
      return new Response(
        JSON.stringify({ success: false, error: "Cet email est déjà utilisé par un autre compte" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Créer l'utilisateur dans Supabase Auth
    console.log(`[CREATE-BUREAU-AUTH] Création utilisateur auth pour: ${president_email}`);
    
    const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
      email: president_email.toLowerCase(),
      password: password,
      email_confirm: true,
      user_metadata: {
        full_name: president_name,
        phone: president_phone,
        role: 'bureau_president'
      }
    });

    if (authError || !authData.user) {
      console.error(`[CREATE-BUREAU-AUTH] Erreur auth:`, authError);
      return new Response(
        JSON.stringify({ success: false, error: authError?.message || "Erreur création compte" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log(`[CREATE-BUREAU-AUTH] ✅ Utilisateur auth créé: ${authData.user.id}`);

    // Générer access token
    const accessToken = crypto.randomUUID();

    // Créer le bureau
    const { data: bureauData, error: bureauError } = await supabaseAdmin
      .from("bureaus")
      .insert({
        user_id: authData.user.id,
        bureau_code: bureau_code.toUpperCase(),
        prefecture: prefecture,
        commune: commune,
        full_location: full_location || `${commune}, ${prefecture}`,
        president_name: president_name,
        president_email: president_email.toLowerCase(),
        president_phone: president_phone,
        access_token: accessToken,
        status: 'pending',
      })
      .select()
      .single();

    if (bureauError) {
      console.error(`[CREATE-BUREAU-AUTH] Erreur insertion bureau:`, bureauError);
      // Rollback: supprimer l'utilisateur auth créé
      await supabaseAdmin.auth.admin.deleteUser(authData.user.id);
      return new Response(
        JSON.stringify({ success: false, error: bureauError.message }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Créer le profil
    await supabaseAdmin.from("profiles").upsert({
      id: authData.user.id,
      email: president_email.toLowerCase(),
      first_name: president_name?.split(' ')[0] || president_name,
      last_name: president_name?.split(' ').slice(1).join(' ') || '',
      phone: president_phone,
      role: 'bureau_president',
    });

    // Créer le wallet du bureau
    await supabaseAdmin.from("bureau_wallets").insert({
      bureau_id: bureauData.id,
      balance: 0,
      currency: 'GNF',
      wallet_status: 'active'
    });

    console.log(`[CREATE-BUREAU-AUTH] ✅ Bureau créé: ${bureauData.id}`);

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: `Bureau ${bureau_code} créé avec succès`,
        bureau: {
          id: bureauData.id,
          bureau_code: bureau_code.toUpperCase(),
          access_token: accessToken,
          president_email: president_email.toLowerCase()
        }
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("[CREATE-BUREAU-AUTH] Erreur:", error);
    return new Response(
      JSON.stringify({ success: false, error: "Erreur serveur interne" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});