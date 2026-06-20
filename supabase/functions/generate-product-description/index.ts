/**
 * 🤖 EDGE FUNCTION: GÉNÉRATION DESCRIPTION PROFESSIONNELLE IA
 * Utilise Lovable AI Gateway (Gemini 2.5 Flash) — même infra que vendor-ai-assistant
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const name = (body.name || body.productName || "").trim();
    const category = (body.category || "").trim();
    const productType = (body.productType || "").trim();
    const price = body.price || "";

    if (!name) {
      return new Response(
        JSON.stringify({ error: "Le nom du produit est requis" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    if (!LOVABLE_API_KEY) {
      throw new Error("LOVABLE_API_KEY non configurée");
    }

    const prompt = `Tu es un expert en rédaction e-commerce. Génère une description professionnelle et vendeuse pour ce produit numérique.

NOM DU PRODUIT: ${name}
${category ? `CATÉGORIE: ${category}` : ""}
${productType ? `TYPE: ${productType}` : ""}
${price ? `PRIX: ${price} GNF` : ""}

Réponds UNIQUEMENT avec ce JSON (sans markdown, sans backticks, sans texte avant ou après):
{
  "shortDescription": "Une phrase accrocheuse de 10-15 mots maximum qui résume le produit",
  "description": "Description commerciale complète de 2-3 paragraphes (150-200 mots) qui détaille les avantages, bénéfices et valeur ajoutée du produit"
}

RÈGLES:
- La description courte: percutante, donne envie d'acheter
- La description complète: avantages concrets, bénéfices utilisateur, appel à l'action
- Ton professionnel et accessible en français
- Adapté au marché africain / guinéen si pertinent`;

    console.log("🔄 Génération description Gemini pour:", name);

    const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-2.5-flash",
        messages: [
          {
            role: "system",
            content: "Tu es un expert en rédaction de descriptions produits e-commerce professionnelles en français. Tu réponds UNIQUEMENT en JSON valide, sans markdown ni backticks.",
          },
          {
            role: "user",
            content: prompt,
          },
        ],
        temperature: 0.7,
        max_tokens: 600,
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error("Lovable AI Gateway error:", response.status, errorText);

      if (response.status === 429) {
        return new Response(
          JSON.stringify({ error: "Limite de requêtes atteinte. Réessayez dans quelques instants." }),
          { status: 429, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      if (response.status === 402) {
        return new Response(
          JSON.stringify({ error: "Crédits IA insuffisants." }),
          { status: 402, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      throw new Error(`AI Gateway error: ${response.status}`);
    }

    const data = await response.json();
    const generatedText = (data.choices?.[0]?.message?.content || "").trim();

    if (!generatedText) {
      throw new Error("Aucune description générée par l'IA");
    }

    console.log("✅ Description générée:", generatedText.slice(0, 100));

    // Parser le JSON retourné
    let parsedContent: Record<string, unknown> = {};
    try {
      const cleaned = generatedText
        .replace(/```json\s*/gi, "")
        .replace(/```\s*/g, "")
        .trim();
      // Extraire le premier objet JSON
      const jsonMatch = cleaned.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        parsedContent = JSON.parse(jsonMatch[0]);
      }
    } catch {
      console.warn("Parse JSON échoué — utilisation du texte brut");
    }

    const description = String(
      parsedContent.description ?? parsedContent.longDescription ?? parsedContent.fullDescription ?? ""
    ).trim() || generatedText;

    let shortDescription = String(
      parsedContent.shortDescription ?? parsedContent.short_description ?? parsedContent.short ?? parsedContent.summary ?? ""
    ).trim();

    if (!shortDescription && description) {
      const first = (description.split(/(?<=[.!?])\s+/)[0] || description).trim();
      const words = first.split(" ").filter(Boolean).slice(0, 15).join(" ");
      shortDescription = words ? (/[.!?]$/.test(words) ? words : `${words}.`) : "";
    }

    return new Response(
      JSON.stringify({
        shortDescription,
        description,
        provider: "lovable-gateway",
        model: "gemini-2.5-flash",
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error: unknown) {
    console.error("❌ Erreur génération description:", error);
    const msg = error instanceof Error ? error.message : "Erreur lors de la génération";
    return new Response(
      JSON.stringify({ error: msg }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
