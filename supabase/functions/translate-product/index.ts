import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

/**
 * TRANSLATE PRODUCT - Edge Function pour traduire les noms et descriptions de produits
 * Utilise Lovable AI Gateway pour la traduction avec cache côté client
 */

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    if (!LOVABLE_API_KEY) {
      throw new Error("LOVABLE_API_KEY non configurée");
    }

    const { products, targetLanguage, sourceLanguage = 'auto' } = await req.json();

    if (!products || !Array.isArray(products) || products.length === 0) {
      return new Response(
        JSON.stringify({ error: "Liste de produits requise", translations: [] }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!targetLanguage) {
      return new Response(
        JSON.stringify({ error: "Langue cible requise", translations: [] }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Limiter à 10 produits par requête pour éviter les timeouts
    const productsToTranslate = products.slice(0, 10);

    // Construire le prompt pour traduire plusieurs produits
    const productsText = productsToTranslate.map((p: any, i: number) => 
      `[${i}] NOM: ${p.name}${p.description ? `\nDESC: ${p.description}` : ''}`
    ).join('\n\n');

    const translationPrompt = `Tu es un traducteur professionnel pour une marketplace e-commerce.

RÈGLES:
1. Traduis les noms et descriptions de produits
2. Garde les noms de marques, modèles et termes techniques
3. Conserve les unités de mesure (kg, ml, cm, etc.)
4. Ne modifie pas les prix ou chiffres
5. Adapte les expressions au marché cible
6. Format de sortie JSON strict

LANGUE CIBLE: ${targetLanguage}

PRODUITS À TRADUIRE:
${productsText}

Réponds UNIQUEMENT avec un JSON valide, format:
[{"id": 0, "name": "nom traduit", "description": "description traduite ou null"}]`;

    const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-2.5-flash",
        messages: [
          { 
            role: "system", 
            content: "Tu es un traducteur. Réponds UNIQUEMENT avec du JSON valide." 
          },
          { role: "user", content: translationPrompt }
        ],
        temperature: 0.2,
        max_tokens: 4000
      }),
    });

    if (!response.ok) {
      if (response.status === 429) {
        return new Response(
          JSON.stringify({ error: "Limite de requêtes atteinte", translations: [] }),
          { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      throw new Error(`Erreur API: ${response.status}`);
    }

    const data = await response.json();
    let translatedText = data.choices?.[0]?.message?.content?.trim() || '';

    // Nettoyer le JSON (enlever les backticks si présents)
    translatedText = translatedText.replace(/```json\s*/g, '').replace(/```\s*/g, '').trim();

    let translations: any[] = [];
    try {
      translations = JSON.parse(translatedText);
    } catch (parseError) {
      console.error("JSON parse error:", parseError, translatedText);
      // Retourner les produits originaux si le parsing échoue
      translations = productsToTranslate.map((p: any, i: number) => ({
        id: i,
        name: p.name,
        description: p.description || null
      }));
    }

    // Mapper les traductions aux IDs originaux des produits
    const result = productsToTranslate.map((p: any, index: number) => {
      const translation = translations.find((t: any) => t.id === index) || translations[index];
      return {
        productId: p.id,
        originalName: p.name,
        originalDescription: p.description,
        translatedName: translation?.name || p.name,
        translatedDescription: translation?.description || p.description,
        targetLanguage
      };
    });

    return new Response(
      JSON.stringify({ 
        translations: result,
        targetLanguage,
        count: result.length
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error: any) {
    console.error("Translation error:", error);
    return new Response(
      JSON.stringify({ 
        error: error.message || "Erreur de traduction",
        translations: []
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
