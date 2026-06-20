import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import * as bcrypt from 'https://deno.land/x/bcrypt@v0.4.1/mod.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ success: false, error: 'Missing authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const token = authHeader.replace('Bearer ', '');
    
    const supabaseUser = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: authHeader }
        }
      }
    );

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      {
        auth: {
          autoRefreshToken: false,
          persistSession: false
        }
      }
    );
    
    const { data: { user }, error: authError } = await supabaseUser.auth.getUser(token);

    if (authError || !user) {
      console.error('❌ Auth error:', authError);
      return new Response(
        JSON.stringify({ success: false, error: 'Non autorisé' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('✅ User authenticated:', user.id);

    // Vérifier que l'utilisateur est un PDG
    const { data: pdgProfile, error: pdgError } = await supabaseAdmin
      .from('pdg_management')
      .select('id')
      .eq('user_id', user.id)
      .single();

    if (pdgError || !pdgProfile) {
      console.error('❌ PDG check failed:', pdgError);
      return new Response(
        JSON.stringify({ success: false, error: 'Vous devez être PDG pour réinitialiser le mot de passe' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('✅ PDG verified:', pdgProfile.id);

    const { agent_id, new_password } = await req.json();

    if (!agent_id || !new_password) {
      return new Response(
        JSON.stringify({ success: false, error: 'Agent ID et nouveau mot de passe requis' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (new_password.length < 8) {
      return new Response(
        JSON.stringify({ success: false, error: 'Le mot de passe doit contenir au moins 8 caractères' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Validate password complexity for Supabase Auth
    const hasLower = /[a-z]/.test(new_password);
    const hasUpper = /[A-Z]/.test(new_password);
    const hasNumber = /[0-9]/.test(new_password);
    const hasSpecial = /[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\/?`~]/.test(new_password);

    if (!hasLower || !hasUpper || !hasNumber || !hasSpecial) {
      return new Response(
        JSON.stringify({ 
          success: false, 
          error: 'Le mot de passe doit contenir: minuscules, majuscules, chiffres et caractères spéciaux (!@#$%...)' 
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Récupérer l'agent pour vérifier qu'il appartient au PDG
    const { data: agent, error: agentError } = await supabaseAdmin
      .from('agents_management')
      .select('id, user_id, name, pdg_id')
      .eq('id', agent_id)
      .single();

    if (agentError || !agent) {
      console.error('❌ Agent not found:', agentError);
      return new Response(
        JSON.stringify({ success: false, error: 'Agent non trouvé' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Vérifier que l'agent appartient au PDG
    if (agent.pdg_id !== pdgProfile.id) {
      return new Response(
        JSON.stringify({ success: false, error: 'Vous ne pouvez pas modifier cet agent' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('✅ Agent verified:', agent.name);

    // Mettre à jour le mot de passe dans Supabase Auth si l'agent a un user_id
    if (agent.user_id) {
      const { error: updateAuthError } = await supabaseAdmin.auth.admin.updateUserById(
        agent.user_id,
        { password: new_password }
      );

      if (updateAuthError) {
        console.error('❌ Error updating auth password:', updateAuthError);
        return new Response(
          JSON.stringify({ success: false, error: `Erreur mise à jour mot de passe: ${updateAuthError.message}` }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      console.log('✅ Auth password updated for user:', agent.user_id);
    }

    // Mettre à jour le hash dans la table agents_management
    try {
      const salt = await bcrypt.genSalt(10);
      const passwordHash = await bcrypt.hash(new_password, salt);
      
      const { error: updateDbError } = await supabaseAdmin
        .from('agents_management')
        .update({ 
          password_hash: passwordHash,
          updated_at: new Date().toISOString()
        })
        .eq('id', agent_id);

      if (updateDbError) {
        console.error('❌ Error updating password_hash:', updateDbError);
      } else {
        console.log('✅ Password hash updated in agents_management table');
      }
    } catch (bcryptError) {
      console.warn('⚠️ Could not update password hash:', bcryptError);
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: `Mot de passe de ${agent.name} réinitialisé avec succès`
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );

  } catch (error: any) {
    console.error('❌ Erreur:', error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      }
    );
  }
});
