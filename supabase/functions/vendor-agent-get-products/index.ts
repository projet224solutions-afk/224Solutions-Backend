import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
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
    const { agentToken } = await req.json();

    if (!agentToken) {
      return new Response(
        JSON.stringify({ error: 'Token agent requis' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Créer un client Supabase avec service_role
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

    // Vérifier que le token agent est valide
    const { data: agent, error: agentError } = await supabaseAdmin
      .from('vendor_agents')
      .select('id, vendor_id, is_active, permissions')
      .eq('access_token', agentToken)
      .single();

    if (agentError || !agent) {
      return new Response(
        JSON.stringify({ error: 'Token agent invalide' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!agent.is_active) {
      return new Response(
        JSON.stringify({ error: 'Agent inactif' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Récupérer les produits du vendeur
    const { data: products, error: productsError } = await supabaseAdmin
      .from('products')
      .select('*')
      .eq('vendor_id', agent.vendor_id)
      .order('created_at', { ascending: false });

    if (productsError) throw productsError;

    // Récupérer les catégories actives
    const { data: categories } = await supabaseAdmin
      .from('categories')
      .select('id, name, is_active')
      .eq('is_active', true)
      .order('name');

    return new Response(
      JSON.stringify({ 
        products: products || [],
        categories: categories || [],
        vendorId: agent.vendor_id
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Erreur:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Erreur inconnue' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
