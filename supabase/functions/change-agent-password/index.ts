/**
 * CHANGE AGENT PASSWORD - 224SOLUTIONS
 * Permet à un agent de changer son mot de passe
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3';
import * as bcrypt from 'https://deno.land/x/bcrypt@v0.4.1/mod.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface ChangePasswordRequest {
  agent_id: string;
  current_password: string;
  new_password: string;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const { agent_id, current_password, new_password } = await req.json() as ChangePasswordRequest;

    // Validation
    if (!agent_id || !current_password || !new_password) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Tous les champs sont requis' 
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (new_password.length < 8) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Le nouveau mot de passe doit contenir au moins 8 caractères' 
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log(`[CHANGE-AGENT-PASSWORD] Tentative changement mot de passe agent: ${agent_id}`);

    // Récupérer l'agent depuis agents_management
    const { data: agent, error: agentError } = await supabase
      .from('agents_management')
      .select('id, email, password_hash, is_active')
      .eq('id', agent_id)
      .maybeSingle();

    if (agentError || !agent) {
      console.error('[CHANGE-AGENT-PASSWORD] Agent non trouvé:', agentError);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Agent non trouvé' 
        }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!agent.is_active) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Compte désactivé' 
        }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier mot de passe actuel
    const passwordMatch = await bcrypt.compare(current_password, agent.password_hash);
    
    if (!passwordMatch) {
      console.log(`[CHANGE-AGENT-PASSWORD] Mot de passe actuel incorrect: ${agent.email}`);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Mot de passe actuel incorrect' 
        }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Hasher nouveau mot de passe
    const salt = await bcrypt.genSalt(10);
    const newPasswordHash = await bcrypt.hash(new_password, salt);

    // Mettre à jour dans la base de données
    const { error: updateError } = await supabase
      .from('agents_management')
      .update({
        password_hash: newPasswordHash,
        updated_at: new Date().toISOString()
      })
      .eq('id', agent_id);

    if (updateError) {
      console.error('[CHANGE-AGENT-PASSWORD] Erreur mise à jour:', updateError);
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Erreur lors de la mise à jour du mot de passe' 
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Logger l'action
    await supabase
      .from('auth_login_logs')
      .insert({
        user_id: agent_id,
        user_type: 'agent',
        success: true,
        action: 'password_change',
        created_at: new Date().toISOString()
      });

    console.log(`[CHANGE-AGENT-PASSWORD] ✅ Mot de passe changé avec succès: ${agent.email}`);

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Mot de passe modifié avec succès'
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );
  } catch (error) {
    console.error('[CHANGE-AGENT-PASSWORD] Erreur:', error);
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: error instanceof Error ? error.message : 'Erreur inconnue' 
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      }
    );
  }
});
