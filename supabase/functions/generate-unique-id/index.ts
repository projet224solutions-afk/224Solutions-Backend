/**
 * 🔧 EDGE FUNCTION: GÉNÉRATION D'ID SÉQUENTIEL STANDARDISÉ
 * Format universel: AAA0001 (3 lettres préfixe + 4+ chiffres)
 * Système 224SOLUTIONS - IDs séquentiels par type
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

/**
 * Mapping des scopes vers les préfixes
 */
const SCOPE_PREFIX_MAP: Record<string, string> = {
  'users': 'CLT',
  'user': 'CLT',
  'vendors': 'VND',
  'vendor': 'VND',
  'pdg': 'PDG',
  'agents': 'AGT',
  'agent': 'AGT',
  'sub_agents': 'SAG',
  'sub_agent': 'SAG',
  'syndicats': 'BST',
  'syndicat': 'BST',
  'bureau': 'BST',
  'bureaus': 'BST',
  'drivers': 'DRV',
  'driver': 'DRV',
  'clients': 'CLT',
  'client': 'CLT',
  'customers': 'CLT',
  'customer': 'CLT',
  'products': 'PRD',
  'product': 'PRD',
  'orders': 'ORD',
  'order': 'ORD',
  'transactions': 'TXN',
  'transaction': 'TXN',
  'wallets': 'WLT',
  'wallet': 'WLT',
  'messages': 'MSG',
  'message': 'MSG',
  'conversations': 'CNV',
  'conversation': 'CNV',
  'deliveries': 'DLV',
  'delivery': 'DLV',
  'general': 'GEN',
};

/**
 * Génère un ID séquentiel standardisé avec vérification d'unicité
 */
async function generateStandardId(
  supabase: any,
  prefix: string
): Promise<string> {
  console.log(`🔄 Génération ID standardisé avec préfixe: ${prefix}`);

  const maxRetries = 5;
  
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      const { data, error } = await supabase
        .rpc('generate_sequential_id', { p_prefix: prefix });

      if (error) {
        console.error('❌ Erreur génération ID:', error);
        throw new Error(`Erreur génération ID: ${error.message}`);
      }

      if (!data) {
        throw new Error('Aucun ID généré');
      }

      // Vérifier que l'ID n'existe pas déjà dans products
      if (prefix === 'PRD') {
        const { data: existing } = await supabase
          .from('products')
          .select('id')
          .eq('public_id', data)
          .maybeSingle();

        if (existing) {
          console.warn(`⚠️ ID ${data} existe déjà, tentative ${attempt + 1}/${maxRetries}`);
          continue;
        }
      }

      console.log(`✅ ID unique généré: ${data}`);
      return data;
    } catch (error: any) {
      console.error(`❌ Exception génération ID (tentative ${attempt + 1}):`, error);
      if (attempt === maxRetries - 1) throw error;
    }
  }
  
  // Fallback: générer un ID avec timestamp
  const fallbackId = `${prefix}${Date.now().toString().slice(-8)}`;
  console.log(`⚠️ Fallback ID généré: ${fallbackId}`);
  return fallbackId;
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Créer le client Supabase
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
      {
        auth: {
          persistSession: false,
        },
      }
    );

    // Récupérer l'utilisateur authentifié
    const authHeader = req.headers.get('Authorization');
    let userId = null;

    if (authHeader) {
      const token = authHeader.replace('Bearer ', '');
      const { data: { user }, error: authError } = await supabaseClient.auth.getUser(token);
      
      if (!authError && user) {
        userId = user.id;
      }
    }

    const { scope = 'general', batch = 1, prefix = null } = await req.json();

    // Déterminer le préfixe
    let finalPrefix = prefix;
    if (!finalPrefix) {
      finalPrefix = SCOPE_PREFIX_MAP[scope.toLowerCase()] || 'GEN';
    }

    // Validation du préfixe
    if (!/^[A-Z]{3}$/.test(finalPrefix)) {
      return new Response(
        JSON.stringify({ 
          error: 'Préfixe invalide: doit être 3 lettres majuscules',
          received: finalPrefix
        }),
        { 
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    if (batch > 10) {
      return new Response(
        JSON.stringify({ error: 'Maximum 10 IDs par requête' }),
        { 
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // Générer les IDs séquentiels
    const ids: string[] = [];
    for (let i = 0; i < batch; i++) {
      const id = await generateStandardId(supabaseClient, finalPrefix);
      ids.push(id);
    }

    console.log(`✅ ${ids.length} ID(s) standardisé(s) généré(s) avec préfixe ${finalPrefix}`);

    return new Response(
      JSON.stringify({
        success: true,
        ids: ids,
        prefix: finalPrefix,
        scope: scope,
        count: ids.length,
        format: 'AAA####',
        system: '224SOLUTIONS'
      }),
      { 
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );

  } catch (error: any) {
    console.error('❌ Erreur Edge Function:', error);
    return new Response(
      JSON.stringify({ 
        error: error?.message || 'Erreur lors de la génération d\'ID',
        success: false
      }),
      { 
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});
