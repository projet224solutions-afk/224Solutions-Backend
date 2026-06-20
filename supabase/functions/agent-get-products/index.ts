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
      .from('agents_management')
      .select('id, pdg_id, is_active, permissions')
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

    // Vérifier que l'agent a la permission de gérer les produits
    if (!agent.permissions.includes('manage_products')) {
      return new Response(
        JSON.stringify({ error: 'Permission refusée' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Récupérer tous les produits
    const { data: products, error: productsError } = await supabaseAdmin
      .from('products')
      .select('*')
      .order('created_at', { ascending: false });

    if (productsError) throw productsError;

    // Récupérer l'inventaire pour calculer le stock
    const { data: inventory } = await supabaseAdmin
      .from('inventory')
      .select('product_id, quantity');

    // Créer un map pour le stock par produit
    const stockMap = new Map<string, number>();
    (inventory || []).forEach((inv: any) => {
      const current = stockMap.get(inv.product_id) || 0;
      stockMap.set(inv.product_id, current + (inv.quantity || 0));
    });

    // Ajouter le stock à chaque produit
    const productsWithStock = (products || []).map((product: any) => ({
      ...product,
      total_stock: stockMap.get(product.id) || 0
    }));

    // Récupérer les vendeurs
    const { data: vendors } = await supabaseAdmin
      .from('vendors')
      .select('id, user_id');

    // Calculer les statistiques
    const activeProducts = productsWithStock.filter((p: any) => p.is_active);
    const totalValue = productsWithStock.reduce((sum: number, p: any) => 
      sum + ((p.price || 0) * (p.total_stock || 0)), 0);
    const totalStock = productsWithStock.reduce((sum: number, p: any) => 
      sum + (p.total_stock || 0), 0);

    const stats = {
      total: productsWithStock.length,
      active: activeProducts.length,
      inactive: productsWithStock.length - activeProducts.length,
      lowStock: productsWithStock.filter((p: any) => (p.total_stock || 0) <= 10).length,
      totalValue,
      totalStock
    };

    return new Response(
      JSON.stringify({ 
        products: productsWithStock,
        vendors: vendors || [],
        stats
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
