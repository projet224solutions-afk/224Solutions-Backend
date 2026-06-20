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

    const { errorId } = await req.json();

    if (!errorId) {
      return new Response(
        JSON.stringify({ error: 'errorId is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    // Récupérer l'erreur
    const { data: error, error: fetchError } = await supabaseClient
      .from('system_errors')
      .select('*')
      .eq('id', errorId)
      .single();

    if (fetchError || !error) {
      return new Response(
        JSON.stringify({ error: 'Error not found' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 404 }
      );
    }

    // Trouver un correctif approprié
    const { data: fixes } = await supabaseClient
      .from('auto_fixes')
      .select('*')
      .eq('is_active', true);

    let fixApplied = false;
    let fixDescription = 'Correction manuelle appliquée par le PDG';

    if (fixes && fixes.length > 0) {
      const matchingFix = fixes.find((fix: any) =>
        error.error_message.includes(fix.error_pattern)
      );

      if (matchingFix) {
        fixDescription = matchingFix.fix_description;
        fixApplied = true;

        // Mettre à jour les stats du correctif
        await supabaseClient
          .from('auto_fixes')
          .update({
            times_applied: matchingFix.times_applied + 1,
            success_rate:
              ((matchingFix.success_rate * matchingFix.times_applied + 100) /
                (matchingFix.times_applied + 1)),
          })
          .eq('id', matchingFix.id);
      }
    }

    // Supprimer l'erreur au lieu de la marquer comme corrigée
    const { error: deleteError } = await supabaseClient
      .from('system_errors')
      .delete()
      .eq('id', errorId);

    if (deleteError) {
      console.error('Error deleting error:', deleteError);
      throw deleteError;
    }

    console.log(`Error ${errorId} successfully deleted`);


    return new Response(
      JSON.stringify({
        success: true,
        message: 'Erreur supprimée avec succès',
        fix_description: fixDescription,
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );
  } catch (error) {
    console.error('Error in fix-error function:', error);
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
