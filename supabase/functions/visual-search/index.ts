/**
 * Edge Function - Recherche Visuelle par Image
 * Utilise l'IA pour analyser une image et trouver des produits similaires
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const LOVABLE_API_KEY = Deno.env.get('LOVABLE_API_KEY');
    if (!LOVABLE_API_KEY) {
      throw new Error('LOVABLE_API_KEY is not configured');
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    const { imageBase64 } = await req.json();

    if (!imageBase64) {
      return new Response(
        JSON.stringify({ error: 'Image base64 requise' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('🔍 Analyse de l\'image avec l\'IA...');

    // Analyser l'image avec l'IA pour détecter les objets/produits
    const aiResponse = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${LOVABLE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'google/gemini-2.5-flash',
        messages: [
          {
            role: 'user',
            content: [
              {
                type: 'text',
                text: `Analyse cette image et identifie les produits ou objets visibles. 
                
Retourne UNIQUEMENT un JSON valide avec cette structure exacte:
{
  "products": ["mot-clé 1", "mot-clé 2", "mot-clé 3"],
  "category": "catégorie principale",
  "colors": ["couleur 1", "couleur 2"],
  "description": "description courte de l'image"
}

Exemples de catégories: électronique, vêtements, chaussures, accessoires, maison, beauté, sport, alimentation, jouets, bijoux.
Donne au maximum 5 mots-clés pertinents pour rechercher ce produit.
Réponds UNIQUEMENT avec le JSON, sans texte avant ou après.`
              },
              {
                type: 'image_url',
                image_url: {
                  url: imageBase64
                }
              }
            ]
          }
        ]
      })
    });

    if (!aiResponse.ok) {
      const errorText = await aiResponse.text();
      console.error('Erreur IA:', errorText);
      throw new Error(`Erreur analyse IA: ${aiResponse.status}`);
    }

    const aiData = await aiResponse.json();
    const aiContent = aiData.choices?.[0]?.message?.content || '';

    console.log('📝 Réponse IA brute:', aiContent);

    // Parser le JSON de l'IA
    let analysisResult;
    try {
      // Nettoyer la réponse (enlever les backticks markdown si présents)
      const cleanedContent = aiContent
        .replace(/```json\n?/g, '')
        .replace(/```\n?/g, '')
        .trim();
      analysisResult = JSON.parse(cleanedContent);
    } catch (parseError) {
      console.error('Erreur parsing JSON IA:', parseError);
      // Fallback: extraire les mots-clés du texte
      const keywords = aiContent.match(/["']([^"']+)["']/g)?.map((k: string) => k.replace(/["']/g, '')) || [];
      analysisResult = {
        products: keywords.slice(0, 5),
        category: 'général',
        colors: [],
        description: aiContent.substring(0, 200)
      };
    }

    console.log('🎯 Analyse:', analysisResult);

    // Rechercher les produits correspondants dans la base de données
    const searchKeywords = [
      ...(analysisResult.products || []),
      analysisResult.category,
      ...(analysisResult.colors || [])
    ].filter(Boolean);

    // Construire la requête de recherche
    let allProducts: any[] = [];

    for (const keyword of searchKeywords.slice(0, 5)) {
      const { data: products } = await supabase
        .from('products')
        .select('id, name, price, images, rating, reviews_count, vendor_id')
        .eq('is_active', true)
        .ilike('name', `%${keyword}%`)
        .limit(10);

      if (products) {
        allProducts.push(...products);
      }
    }

    // Chercher aussi par description si on a trouvé peu de résultats
    if (allProducts.length < 5 && analysisResult.description) {
      const descWords = analysisResult.description.split(' ').slice(0, 3);
      for (const word of descWords) {
        if (word.length > 3) {
          const { data: products } = await supabase
            .from('products')
            .select('id, name, price, images, rating, reviews_count, vendor_id')
            .eq('is_active', true)
            .ilike('name', `%${word}%`)
            .limit(5);

          if (products) {
            allProducts.push(...products);
          }
        }
      }
    }

    // Dédupliquer par ID
    const uniqueProducts = Array.from(
      new Map(allProducts.map(p => [p.id, p])).values()
    );

    // Calculer un score de similarité basé sur les correspondances
    const scoredProducts = uniqueProducts.map(product => {
      let score = 0;
      const productNameLower = product.name.toLowerCase();
      
      for (const keyword of searchKeywords) {
        if (keyword && productNameLower.includes(keyword.toLowerCase())) {
          score += 20;
        }
      }
      
      // Bonus pour les produits bien notés
      score += (product.rating || 0) * 5;
      
      return {
        ...product,
        similarity: Math.min(0.95, 0.5 + (score / 100))
      };
    });

    // Trier par score et limiter
    const results = scoredProducts
      .sort((a, b) => b.similarity - a.similarity)
      .slice(0, 12);

    console.log(`✅ ${results.length} produits trouvés`);

    return new Response(
      JSON.stringify({
        success: true,
        analysis: analysisResult,
        results,
        keywords: searchKeywords
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('Erreur visual-search:', error);
    return new Response(
      JSON.stringify({ 
        error: 'Erreur lors de la recherche visuelle', 
        details: error.message 
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
