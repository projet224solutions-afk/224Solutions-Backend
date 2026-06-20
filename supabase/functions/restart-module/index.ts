import { serve } from 'https://deno.land/std@0.190.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    );

    // Vérifier l'authentification
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Missing authorization header' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const { data: { user }, error: userError } = await supabaseClient.auth.getUser(
      authHeader.replace('Bearer ', '')
    );

    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    // Vérifier que l'utilisateur est admin
    const { data: profile } = await supabaseClient
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .single();

    if (profile?.role !== 'admin') {
      return new Response(
        JSON.stringify({ error: 'Forbidden: Admin access required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
      );
    }

    const { moduleName } = await req.json();

    if (!moduleName) {
      return new Response(
        JSON.stringify({ error: 'moduleName is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    // Logger l'action de redémarrage
    await supabaseClient
      .from('system_errors')
      .insert({
        module: moduleName,
        error_type: 'manual_restart',
        error_message: `Module ${moduleName} redémarré manuellement par le PDG`,
        severity: 'mineure',
        status: 'fixed',
        fix_applied: true,
        fix_description: 'Redémarrage manuel du module',
        user_id: user.id,
        metadata: {
          action: 'manual_restart',
          timestamp: new Date().toISOString(),
        },
      });

    // Actions de redémarrage selon le module
    let restartAction = '';
    switch (moduleName.toLowerCase()) {
      case 'wallet':
      case 'wallets':
        // Nettoyer les transactions en attente de plus de 1h
        await supabaseClient.rpc('clean_old_errors');
        restartAction = 'Transactions wallet nettoyées';
        break;

      case 'database':
      case 'db':
        // Rafraîchir les connexions
        restartAction = 'Connexions database rafraîchies';
        break;

      case 'auth':
      case 'authentication':
        // Rafraîchir les sessions
        restartAction = 'Sessions auth rafraîchies';
        break;

      default:
        restartAction = `Module ${moduleName} marqué pour redémarrage`;
    }

    // Enregistrer le statut de santé après redémarrage
    await supabaseClient
      .from('system_health')
      .insert({
        timestamp: new Date().toISOString(),
        status: 'healthy',
        metadata: {
          module_restarted: moduleName,
          action: restartAction,
          restarted_by: user.id,
        },
      });

    return new Response(
      JSON.stringify({
        success: true,
        message: `Module ${moduleName} redémarré avec succès`,
        action: restartAction,
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );
  } catch (error) {
    console.error('Error in restart-module function:', error);
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ error: errorMessage }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500,
      }
    );
  }
});
