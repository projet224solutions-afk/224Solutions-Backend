/**
 * 🎨 EDGE FUNCTION: GÉNÉRATION IMAGE PRODUIT IA (DALL-E 3)
 * 
 * Utilise DALL-E 3 pour créer des images réalistes de produits
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface RequestBody {
  name: string;
  description: string;
  category: string;
  style?: 'realistic' | 'studio' | '3d';
  background?: 'white' | 'transparent' | 'scene';
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { name, description, category, style = 'realistic', background = 'white' }: RequestBody = await req.json();
    
    if (!name) {
      return new Response(
        JSON.stringify({ error: 'Le nom du produit est requis' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');
    if (!OPENAI_API_KEY) {
      throw new Error('OPENAI_API_KEY n\'est pas configurée');
    }

    // Construire le prompt image professionnel
    let prompt = `Professional product photography of ${name}. ${description}. `;
    
    // Style
    if (style === 'studio') {
      prompt += 'Studio lighting, clean professional product shot. ';
    } else if (style === '3d') {
      prompt += '3D render, high quality, detailed. ';
    } else {
      prompt += 'Realistic photo, high resolution, detailed. ';
    }
    
    // Background
    if (background === 'white') {
      prompt += 'Pure white background, e-commerce style. ';
    } else if (background === 'transparent') {
      prompt += 'No background, product isolated. ';
    } else {
      prompt += 'Natural scene, lifestyle context. ';
    }
    
    // Catégorie spécifique
    if (category === 'electronique') {
      prompt += 'Modern tech product, sleek design. ';
    } else if (category === 'electromenager') {
      prompt += 'Kitchen appliance, stainless steel finish. ';
    } else if (category === 'mode') {
      prompt += 'Fashion product, stylish presentation. ';
    }
    
    prompt += 'High quality, professional, centered composition, 4K resolution.';

    console.log('🎨 Génération image avec prompt:', prompt);

    // Appel DALL-E 3
    const response = await fetch('https://api.openai.com/v1/images/generations', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'dall-e-3',
        prompt: prompt,
        n: 1,
        size: '1024x1024',
        quality: 'standard',
        style: 'natural'
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error('OpenAI error:', response.status, errorText);
      
      if (response.status === 429) {
        return new Response(
          JSON.stringify({ error: 'Limite de requêtes atteinte. Veuillez réessayer dans quelques instants.' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 429 }
        );
      }
      
      throw new Error(`OpenAI API error: ${response.statusText} - ${errorText}`);
    }

    const data = await response.json();
    const imageUrl = data.data[0].url;

    console.log('✅ Image générée:', imageUrl);

    return new Response(
      JSON.stringify({ imageUrl }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error) {
    console.error('❌ Erreur génération image:', error);
    
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Erreur inconnue' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
