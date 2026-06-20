/**
 * 🤖 EDGE FUNCTION: GÉNÉRATION IMAGE PRODUIT IA
 * 
 * Utilise Lovable AI Gateway (Gemini Image) pour créer des images produit
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { productName, category, description } = await req.json();
    
    if (!productName) {
      return new Response(
        JSON.stringify({ error: 'Le nom du produit est requis' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    const LOVABLE_API_KEY = Deno.env.get('LOVABLE_API_KEY');
    if (!LOVABLE_API_KEY) {
      throw new Error('LOVABLE_API_KEY n\'est pas configurée');
    }

    // Créer un prompt détaillé pour générer une image de produit professionnelle
    let prompt = `Create a professional product photography for e-commerce of: "${productName}"`;
    
    if (category) {
      prompt += `. Category: ${category}`;
    }
    
    if (description) {
      prompt += `. Details: ${description.substring(0, 200)}`;
    }
    
    prompt += `. Requirements: Clean white background, professional studio lighting, product centered, high resolution, suitable for online marketplace, commercial product photo.`;

    console.log('🔄 Generating image for:', productName);

    const response = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${LOVABLE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'google/gemini-2.5-flash-image-preview',
        messages: [
          {
            role: 'user',
            content: prompt
          }
        ],
        modalities: ['image', 'text']
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error('Lovable AI error:', response.status, errorText);
      
      if (response.status === 429) {
        return new Response(
          JSON.stringify({ error: 'Limite de requêtes atteinte. Réessayez dans quelques instants.' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 429 }
        );
      }
      
      if (response.status === 402) {
        return new Response(
          JSON.stringify({ error: 'Crédits IA insuffisants. Veuillez recharger votre compte.' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 402 }
        );
      }
      
      throw new Error(`AI gateway error: ${response.status} ${errorText}`);
    }

    const data = await response.json();
    console.log('📦 Image generation response received');
    
    // Extraire l'image générée - vérifier différents chemins possibles
    let imageUrl = data.choices?.[0]?.message?.images?.[0]?.image_url?.url;
    
    // Fallback: parfois l'image est directement dans le message
    if (!imageUrl && data.choices?.[0]?.message?.content) {
      const content = data.choices[0].message.content;
      if (typeof content === 'string' && content.startsWith('data:image')) {
        imageUrl = content;
      }
    }

    // Fallback: vérifier si l'image est dans un tableau d'objets content
    if (!imageUrl && Array.isArray(data.choices?.[0]?.message?.content)) {
      for (const item of data.choices[0].message.content) {
        if (item.type === 'image_url' && item.image_url?.url) {
          imageUrl = item.image_url.url;
          break;
        }
      }
    }
    
    if (!imageUrl) {
      console.error('❌ No image found in response. Full response:', JSON.stringify(data, null, 2));
      throw new Error('Aucune image générée. La fonctionnalité IA peut être temporairement indisponible.');
    }

    console.log('✅ Image générée avec succès');

    return new Response(
      JSON.stringify({ imageUrl }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('❌ Error in generate-product-image:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Erreur inconnue' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
