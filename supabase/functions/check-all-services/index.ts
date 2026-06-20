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
    const services = [];

    // 1. Google Cloud API
    const googleCloudKey = Deno.env.get('GOOGLE_CLOUD_API_KEY');
    services.push({
      name: 'Google Cloud APIs',
      configured: !!googleCloudKey,
      required: true,
      secretName: 'GOOGLE_CLOUD_API_KEY',
      description: 'Géolocalisation, Geocoding, Directions'
    });

    // 2. Firebase Firestore
    const firebaseApiKey = Deno.env.get('FIREBASE_WEB_API_KEY');
    const firebaseProjectId = Deno.env.get('FIREBASE_PROJECT_ID');
    services.push({
      name: 'Firebase Firestore',
      configured: !!firebaseApiKey && !!firebaseProjectId,
      required: true,
      secretName: 'FIREBASE_WEB_API_KEY, FIREBASE_PROJECT_ID',
      description: 'Base de données pour synchronisation offline'
    });

    // 3. Lovable AI (Gemini)
    const lovableApiKey = Deno.env.get('LOVABLE_API_KEY');
    let lovableWorking = false;
    if (lovableApiKey) {
      try {
        // Test Lovable AI avec un appel simple
        const testResponse = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${lovableApiKey}`,
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            model: 'google/gemini-2.5-flash',
            messages: [{ role: 'user', content: 'test' }],
            max_tokens: 5
          })
        });
        lovableWorking = testResponse.ok;
      } catch (e) {
        console.error('Lovable AI test failed:', e);
      }
    }
    services.push({
      name: 'Lovable AI (Gemini)',
      configured: !!lovableApiKey && lovableWorking,
      required: true,
      secretName: 'LOVABLE_API_KEY',
      description: 'IA Gemini pour assistant intelligent'
    });

    // 4. OpenAI
    const openaiKey = Deno.env.get('OPENAI_API_KEY');
    services.push({
      name: 'OpenAI API',
      configured: !!openaiKey,
      required: false,
      secretName: 'OPENAI_API_KEY',
      description: 'Génération IA de descriptions produits'
    });

    // 5. Stripe
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    services.push({
      name: 'Stripe',
      configured: !!stripeKey,
      required: true,
      secretName: 'STRIPE_SECRET_KEY',
      description: 'Paiements par carte bancaire'
    });

    // 6. Agora
    const agoraAppId = Deno.env.get('AGORA_APP_ID');
    const agoraCert = Deno.env.get('AGORA_APP_CERTIFICATE');
    services.push({
      name: 'Agora',
      configured: !!agoraAppId && !!agoraCert,
      required: false,
      secretName: 'AGORA_APP_ID, AGORA_APP_CERTIFICATE',
      description: 'Appels vidéo et audio'
    });

    // 7. Orange Money
    const orangeKey = Deno.env.get('ORANGE_MONEY_API_KEY');
    services.push({
      name: 'Orange Money',
      configured: !!orangeKey,
      required: false,
      secretName: 'ORANGE_MONEY_API_KEY',
      description: 'Paiements mobile money'
    });

    const configuredCount = services.filter(s => s.configured).length;
    const requiredConfigured = services.filter(s => s.required && s.configured).length;
    const requiredTotal = services.filter(s => s.required).length;

    return new Response(
      JSON.stringify({
        status: 'success',
        summary: {
          total: services.length,
          configured: configuredCount,
          requiredConfigured,
          requiredTotal,
          allRequiredConfigured: requiredConfigured === requiredTotal
        },
        services,
        timestamp: new Date().toISOString()
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('Check services error:', error);
    return new Response(
      JSON.stringify({ 
        status: 'error',
        message: error.message 
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
