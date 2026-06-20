/**
 * 🧪 EDGE FUNCTION: TEST GEMINI API
 * 
 * Vérifie si l'API Gemini est correctement configurée et fonctionnelle
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
    const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY");
    
    if (!GEMINI_API_KEY) {
      return new Response(
        JSON.stringify({ 
          status: "error",
          message: "GEMINI_API_KEY n'est pas configurée dans les secrets",
          connected: false
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    console.log('🔄 Test de connexion Gemini API...');

    // Test avec l'API Gemini directe (Google AI Studio) - utilise gemini-2.0-flash
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${GEMINI_API_KEY}`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          contents: [{
            parts: [{
              text: "Dis simplement 'Connexion Gemini OK' en français."
            }]
          }],
          generationConfig: {
            temperature: 0.1,
            maxOutputTokens: 50
          }
        }),
      }
    );

    if (!response.ok) {
      const errorText = await response.text();
      console.error('Gemini API error:', response.status, errorText);
      
      let errorMessage = "Erreur de connexion Gemini API";
      if (response.status === 400) {
        errorMessage = "Clé API Gemini invalide ou mal formatée";
      } else if (response.status === 403) {
        errorMessage = "Clé API Gemini non autorisée - vérifiez les permissions";
      } else if (response.status === 429) {
        errorMessage = "Quota Gemini épuisé - limite de requêtes atteinte";
      }
      
      return new Response(
        JSON.stringify({ 
          status: "error",
          message: errorMessage,
          connected: false,
          details: errorText
        }),
        { status: response.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const data = await response.json();
    const generatedText = data.candidates?.[0]?.content?.parts?.[0]?.text || '';

    console.log('✅ Gemini API connectée et fonctionnelle');

    return new Response(
      JSON.stringify({ 
        status: "success",
        message: "Gemini API est correctement connectée et fonctionnelle",
        connected: true,
        response: generatedText.trim(),
        model: "gemini-1.5-flash"
      }),
      { 
        status: 200, 
        headers: { ...corsHeaders, "Content-Type": "application/json" } 
      }
    );

  } catch (error: unknown) {
    console.error("❌ Erreur test Gemini:", error);
    const errorMessage = error instanceof Error ? error.message : "Erreur inconnue";
    
    return new Response(
      JSON.stringify({ 
        status: "error",
        message: errorMessage,
        connected: false
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, "Content-Type": "application/json" } 
      }
    );
  }
});
