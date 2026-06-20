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
    const { imageUrl } = await req.json();
    
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

    console.log('Enhancing product image...');

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
                text: 'Enhance this product image to make it more professional and appealing for e-commerce. Improve the lighting, clarity, and overall quality. Make the background clean and professional. Ensure the product is well-centered and clearly visible. The result should look like a high-quality studio product photo suitable for an online marketplace.'
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
    console.log('Image enhancement response received:', JSON.stringify(data, null, 2));
    
    // Extraire l'image améliorée - vérifier différents chemins possibles
    let enhancedImageUrl = data.choices?.[0]?.message?.images?.[0]?.image_url?.url;
    
    // Fallback: parfois l'image est directement dans le message
    if (!enhancedImageUrl && data.choices?.[0]?.message?.content) {
      const content = data.choices[0].message.content;
      if (typeof content === 'string' && content.startsWith('data:image')) {
        enhancedImageUrl = content;
      }
    }

    // Fallback: vérifier si l'image est dans un tableau d'objets content
    if (!enhancedImageUrl && Array.isArray(data.choices?.[0]?.message?.content)) {
      for (const item of data.choices[0].message.content) {
        if (item.type === 'image_url' && item.image_url?.url) {
          enhancedImageUrl = item.image_url.url;
          break;
        }
      }
    }
    
    if (!enhancedImageUrl) {
      console.error('No enhanced image found in response. Full response:', JSON.stringify(data, null, 2));
      throw new Error('No enhanced image was generated. Check logs for details.');
    }

    console.log('Successfully extracted enhanced image URL (first 100 chars):', enhancedImageUrl.substring(0, 100));

    return new Response(
      JSON.stringify({ enhancedImageUrl }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error in enhance-product-image:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
