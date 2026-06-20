import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

/**
 * Affiliate Commission Trigger - UNIFIÉ
 * Appelle UNIQUEMENT credit_agent_commission (SQL)
 * Source de vérité: agent_commissions_log + agent_wallets
 * Anti-doublon intégré dans la fonction SQL
 */
serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const { 
      user_id, 
      transaction_type,
      amount, 
      transaction_id,
      currency = 'GNF',
    } = body;

    if (!user_id || !transaction_type || amount === undefined) {
      return new Response(
        JSON.stringify({ error: 'user_id, transaction_type et amount requis' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      { auth: { autoRefreshToken: false, persistSession: false } }
    );

    // SEULE logique: appeler credit_agent_commission (SQL)
    // Cette fonction gère:
    // - Recherche agent (direct + affiliation)
    // - Anti-doublon par transaction_id
    // - Calcul commission agent principal / sous-agent
    // - Crédit wallet
    // - Log dans agent_commissions_log
    const { data: sqlResult, error: sqlError } = await supabaseAdmin.rpc('credit_agent_commission', {
      p_user_id: user_id,
      p_amount: amount,
      p_source_type: transaction_type,
      p_transaction_id: transaction_id || null,
      p_metadata: { currency, source: 'affiliate-commission-trigger' }
    });

    if (sqlError) {
      console.error('❌ Erreur credit_agent_commission:', sqlError);
      throw sqlError;
    }

    console.log('✅ Commission traitée:', JSON.stringify(sqlResult));

    return new Response(
      JSON.stringify({
        success: true,
        commission_created: sqlResult?.has_agent || false,
        already_processed: sqlResult?.already_processed || false,
        method: 'sql_unified',
        details: sqlResult
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Erreur commission:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Erreur inconnue' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
