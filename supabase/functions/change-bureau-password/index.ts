import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as bcrypt from "https://deno.land/x/bcrypt@v0.4.1/mod.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  // Gérer les requêtes OPTIONS pour CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Créer un client Supabase
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Récupérer les données de la requête
    const { bureau_id, current_password, new_password } = await req.json();

    // Validation des entrées
    if (!bureau_id || !current_password || !new_password) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          message: "Tous les champs sont requis" 
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Validation de la longueur du nouveau mot de passe
    if (new_password.length < 8) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          message: "Le nouveau mot de passe doit contenir au moins 8 caractères" 
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Récupérer le bureau depuis la base de données (table bureaus)
    const { data: bureau, error: bureauError } = await supabaseClient
      .from('bureaus')
      .select('*')
      .eq('id', bureau_id)
      .single();

    if (bureauError || !bureau) {
      console.error("Erreur lors de la récupération du bureau:", bureauError);
      return new Response(
        JSON.stringify({ 
          success: false, 
          message: "Bureau introuvable" 
        }),
        { 
          status: 404, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Vérifier si le bureau est actif
    if (bureau.status !== 'active' && bureau.status !== 'validated') {
      return new Response(
        JSON.stringify({ 
          success: false, 
          message: "Ce bureau est désactivé" 
        }),
        { 
          status: 403, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Vérifier le mot de passe actuel
    const passwordMatch = await bcrypt.compare(current_password, bureau.password_hash);

    if (!passwordMatch) {
      // Logger la tentative échouée
      await supabaseClient
        .from('auth_login_logs')
        .insert({
          user_id: bureau_id,
          user_type: 'syndicat',
          action: 'password_change_failed',
          ip_address: req.headers.get('x-forwarded-for') || 'unknown',
          user_agent: req.headers.get('user-agent') || 'unknown',
          success: false,
          failure_reason: 'Mot de passe actuel incorrect'
        });

      return new Response(
        JSON.stringify({ 
          success: false, 
          message: "Mot de passe actuel incorrect" 
        }),
        { 
          status: 401, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Hasher le nouveau mot de passe
    const salt = await bcrypt.genSalt(10);
    const newPasswordHash = await bcrypt.hash(new_password, salt);

    // Mettre à jour le mot de passe dans la base de données (table bureaus)
    const { error: updateError } = await supabaseClient
      .from('bureaus')
      .update({ password_hash: newPasswordHash })
      .eq('id', bureau_id);

    if (updateError) {
      console.error("Erreur lors de la mise à jour du mot de passe:", updateError);
      return new Response(
        JSON.stringify({ 
          success: false, 
          message: "Erreur lors de la mise à jour du mot de passe" 
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // Logger le changement de mot de passe réussi
    await supabaseClient
      .from('auth_login_logs')
      .insert({
        user_id: bureau_id,
        user_type: 'syndicat',
        action: 'password_change',
        ip_address: req.headers.get('x-forwarded-for') || 'unknown',
        user_agent: req.headers.get('user-agent') || 'unknown',
        success: true
      });

    return new Response(
      JSON.stringify({ 
        success: true, 
        message: "Mot de passe modifié avec succès" 
      }),
      { 
        status: 200, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );

  } catch (error) {
    console.error("Erreur dans change-bureau-password:", error);
    return new Response(
      JSON.stringify({ 
        success: false, 
        message: "Une erreur s'est produite lors du changement de mot de passe" 
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );
  }
});
