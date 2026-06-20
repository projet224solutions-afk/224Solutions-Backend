/**
 * 🔍 DIAGNOSTIC PAIEMENT MOBILE MONEY - 224SOLUTIONS
 * Vérifie la configuration des APIs de paiement
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
    // Vérifier les secrets disponibles
    const secrets = {
      // ChapChapPay
      CCP_API_KEY: Deno.env.get("CCP_API_KEY") ? `${Deno.env.get("CCP_API_KEY")?.substring(0, 10)}...` : "❌ Non configuré",
      CCP_ENCRYPTION_KEY: Deno.env.get("CCP_ENCRYPTION_KEY") ? `${Deno.env.get("CCP_ENCRYPTION_KEY")?.substring(0, 10)}...` : "❌ Non configuré",
      CCP_MERCHANT_ID: Deno.env.get("CCP_MERCHANT_ID") ? `${Deno.env.get("CCP_MERCHANT_ID")?.substring(0, 10)}...` : "❌ Non configuré",
      CCP_SECRET_KEY: Deno.env.get("CCP_SECRET_KEY") ? `${Deno.env.get("CCP_SECRET_KEY")?.substring(0, 10)}...` : "❌ Non configuré",
      
      // Djomy (legacy)
      DJOMY_CLIENT_ID: Deno.env.get("DJOMY_CLIENT_ID") ? `${Deno.env.get("DJOMY_CLIENT_ID")?.substring(0, 15)}...` : "❌ Non configuré",
      DJOMY_CLIENT_SECRET: Deno.env.get("DJOMY_CLIENT_SECRET") ? "✅ Configuré" : "❌ Non configuré",
    };

    // Tester ChapChapPay avec un appel de test
    let chapchappayTest = "Non testé";
    const ccpApiKey = Deno.env.get("CCP_API_KEY");
    const ccpMerchantId = Deno.env.get("CCP_MERCHANT_ID");
    
    if (ccpApiKey && ccpMerchantId) {
      try {
        // Vérifier si ce sont des vraies valeurs ou des hash
        const isHash = ccpApiKey.length === 64 && /^[a-f0-9]+$/.test(ccpApiKey);
        
        if (isHash) {
          chapchappayTest = "⚠️ La clé API semble être un hash, pas une vraie clé ChapChapPay";
        } else {
          chapchappayTest = "✅ Credentials ChapChapPay configurés";
        }
      } catch (e: any) {
        chapchappayTest = `❌ Erreur: ${e.message}`;
      }
    } else {
      chapchappayTest = "❌ CCP_API_KEY et/ou CCP_MERCHANT_ID non configurés";
    }

    // Construire le rapport
    const report = {
      timestamp: new Date().toISOString(),
      status: "Diagnostic terminé",
      provider: "ChapChapPay",
      secrets,
      tests: {
        chapchappay: chapchappayTest,
      },
      recommendations: [] as string[],
    };

    // Ajouter des recommandations
    if (!ccpApiKey) {
      report.recommendations.push(
        "Configurer CCP_API_KEY avec la clé API ChapChapPay"
      );
    }
    if (!ccpMerchantId) {
      report.recommendations.push(
        "Configurer CCP_MERCHANT_ID avec l'ID marchand ChapChapPay"
      );
    }

    return new Response(
      JSON.stringify(report, null, 2),
      { 
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200 
      }
    );
  } catch (error: any) {
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: error.message 
      }),
      { 
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 500 
      }
    );
  }
});
