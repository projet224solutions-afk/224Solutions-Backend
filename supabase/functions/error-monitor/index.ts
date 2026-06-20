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

    const { error, autoFix = true } = await req.json();

    if (!error) {
      return new Response(
        JSON.stringify({ error: 'Error data is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    // Enregistrer l'erreur
    const { data: errorRecord, error: insertError } = await supabaseClient
      .from('system_errors')
      .insert({
        module: error.module || 'unknown',
        error_type: error.error_type,
        error_message: error.error_message,
        stack_trace: error.stack_trace,
        severity: error.severity || 'mineure',
        user_id: error.user_id,
        metadata: error.metadata || {},
      })
      .select()
      .single();

    if (insertError) {
      throw insertError;
    }

    let fixApplied = false;
    let fixDescription = null;

    // Tenter une correction automatique si demandé
    if (autoFix) {
      const { data: fixes } = await supabaseClient
        .from('auto_fixes')
        .select('*')
        .eq('is_active', true);

      if (fixes && fixes.length > 0) {
        const matchingFix = fixes.find((fix: any) =>
          error.error_message.includes(fix.error_pattern)
        );

        if (matchingFix) {
          fixApplied = true;
          fixDescription = matchingFix.fix_description;

          // Mettre à jour l'erreur
          await supabaseClient
            .from('system_errors')
            .update({
              fix_applied: true,
              fix_description: fixDescription,
              status: 'fixed',
              fixed_at: new Date().toISOString(),
            })
            .eq('id', errorRecord.id);

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
    }

    // Enregistrer les stats de santé système
    await supabaseClient
      .from('system_health')
      .insert({
        timestamp: new Date().toISOString(),
        error_rate: error.severity === 'critique' ? 10 : error.severity === 'modérée' ? 5 : 1,
        status: error.severity === 'critique' ? 'critical' : error.severity === 'modérée' ? 'warning' : 'healthy',
        metadata: {
          error_id: errorRecord.id,
        },
      });

    return new Response(
      JSON.stringify({
        success: true,
        error_id: errorRecord.id,
        fix_applied: fixApplied,
        fix_description: fixDescription,
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200,
      }
    );
  } catch (error) {
    console.error('Error in error-monitor function:', error);
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
