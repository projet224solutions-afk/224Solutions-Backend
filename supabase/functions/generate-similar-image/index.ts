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
    const { imageUrl, productName, description } = await req.json();

    if (!imageUrl) {
      return new Response(
        JSON.stringify({ error: 'Image URL is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    const LOVABLE_API_KEY = Deno.env.get('LOVABLE_API_KEY');
    if (!LOVABLE_API_KEY) {
      throw new Error('LOVABLE_API_KEY is not configured');
    }

    console.log('Generating similar image based on uploaded image...');

    // Créer un prompt pour générer une image similaire
    let prompt = 'Generate a new professional product photo similar to this image. Keep the same style, lighting, angle, and overall composition, but create a fresh variation. ';
    
    if (productName) {
      prompt += `This is for the product: "${productName}". `;
    }

    if (description && String(description).trim()) {
      prompt += `Product details to respect: ${String(description).trim().slice(0, 600)}. `;
    }

    prompt += 'Maintain the professional e-commerce quality with clean background, good lighting, and product centered. Create a variation that looks like it belongs to the same product photo set.';

    const response = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${LOVABLE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'google/gemini-2.5-flash-image',
        messages: [
          {
            role: 'user',
            content: [
              {
                type: 'text',
                text: prompt
              },
              {
                type: 'image_url',
                image_url: {
                  url: imageUrl
                }
              }
            ]
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
          JSON.stringify({ error: 'Rate limit exceeded. Please try again in a few moments.' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 429 }
        );
      }
      
      if (response.status === 402) {
        return new Response(
          JSON.stringify({ error: 'Insufficient AI credits. Please add credits to your workspace.' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 402 }
        );
      }
      
      throw new Error(`AI gateway error: ${response.status} ${errorText}`);
    }

    const data = await response.json();
    console.log('Similar image generation response received:', JSON.stringify(data, null, 2));
    
    // Extraire l'image générée - vérifier différents chemins possibles
    let similarImageUrl = data.choices?.[0]?.message?.images?.[0]?.image_url?.url;
    
    // Fallback: parfois l'image est directement dans le message
    if (!similarImageUrl && data.choices?.[0]?.message?.content) {
      const content = data.choices[0].message.content;
      if (typeof content === 'string' && content.startsWith('data:image')) {
        similarImageUrl = content;
      }
    }

    // Fallback: vérifier si l'image est dans un tableau d'objets content
    if (!similarImageUrl && Array.isArray(data.choices?.[0]?.message?.content)) {
      for (const item of data.choices[0].message.content) {
        if (item.type === 'image_url' && item.image_url?.url) {
          similarImageUrl = item.image_url.url;
          break;
        }
      }
    }
    
    if (!similarImageUrl) {
      console.error('No similar image found in response. Full response:', JSON.stringify(data, null, 2));
      throw new Error('No similar image was generated. Check logs for details.');
    }

    console.log('Successfully extracted similar image URL (first 100 chars):', similarImageUrl.substring(0, 100));

    return new Response(
      JSON.stringify({ similarImageUrl }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error in generate-similar-image:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
