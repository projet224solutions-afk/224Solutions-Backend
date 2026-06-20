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
    const { competitors, criteria } = await req.json();
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    
    if (!LOVABLE_API_KEY) {
      throw new Error("LOVABLE_API_KEY is not configured");
    }

    console.log('Starting competitive analysis for:', competitors);

    const systemPrompt = `Tu es un expert en analyse comparative de plateformes e-commerce et fintech. 
Analyse 224Solutions (une plateforme guinéenne innovante combinant e-commerce, fintech, marketplace, livraison, et services de proximité) 
par rapport aux concurrents suivants: ${competitors.join(', ')}.

Fournis une analyse détaillée selon ces critères:
${criteria.map((c: string) => `- ${c}`).join('\n')}

Pour chaque critère, note les plateformes de 0 à 10 et fournis une analyse détaillée des forces et faiblesses.
Mets en évidence les innovations uniques de 224Solutions comme:
- Système d'agents distribués
- Bureaux syndicats pour la gestion locale
- Intégration wallet multi-devises (GNF, USD, EUR)
- Escrow automatisé
- Services de proximité intégrés
- Système de taxi-moto intégré
- Transitaires pour import/export

Format de réponse: JSON structuré avec scores et analyses détaillées.`;

    const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-2.5-flash",
        messages: [
          { role: "system", content: systemPrompt },
          { 
            role: "user", 
            content: `Analyse comparative complète de 224Solutions vs ${competitors.join(', ')} selon: ${criteria.join(', ')}` 
          }
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "competitive_analysis",
              description: "Retourner l'analyse comparative structurée",
              parameters: {
                type: "object",
                properties: {
                  platforms: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                        name: { type: "string" },
                        scores: {
                          type: "object",
                          additionalProperties: { type: "number" }
                        },
                        strengths: {
                          type: "array",
                          items: { type: "string" }
                        },
                        weaknesses: {
                          type: "array",
                          items: { type: "string" }
                        },
                        innovations: {
                          type: "array",
                          items: { type: "string" }
                        }
                      },
                      required: ["name", "scores", "strengths", "weaknesses"]
                    }
                  },
                  summary: { type: "string" },
                  recommendations: {
                    type: "array",
                    items: { type: "string" }
                  }
                },
                required: ["platforms", "summary", "recommendations"]
              }
            }
          }
        ],
        tool_choice: { type: "function", function: { name: "competitive_analysis" } }
      }),
    });

    if (!response.ok) {
      if (response.status === 429) {
        return new Response(
          JSON.stringify({ error: "Rate limit exceeded. Please try again later." }),
          { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      if (response.status === 402) {
        return new Response(
          JSON.stringify({ error: "Payment required. Please add credits to your workspace." }),
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      const errorText = await response.text();
      console.error("AI gateway error:", response.status, errorText);
      throw new Error(`AI gateway error: ${response.status}`);
    }

    const data = await response.json();
    console.log('AI response received:', data);

    // Extract the tool call result
    const toolCall = data.choices?.[0]?.message?.tool_calls?.[0];
    if (!toolCall) {
      throw new Error("No tool call in response");
    }

    const analysis = JSON.parse(toolCall.function.arguments);

    return new Response(
      JSON.stringify({ success: true, analysis }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("Error in competitive-analysis:", error);
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: error instanceof Error ? error.message : "Unknown error" 
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, "Content-Type": "application/json" } 
      }
    );
  }
});
