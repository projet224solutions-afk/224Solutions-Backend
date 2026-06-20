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
    const GOOGLE_CLOUD_API_KEY = Deno.env.get('GOOGLE_CLOUD_API_KEY');

    // Vérifier si le secret existe
    if (!GOOGLE_CLOUD_API_KEY) {
      return new Response(
        JSON.stringify({ 
          status: 'error',
          message: 'Le secret GOOGLE_CLOUD_API_KEY n\'est pas configuré',
          instructions: [
            '1. Allez dans Supabase Dashboard > Project Settings > Edge Functions',
            '2. Ajoutez le secret GOOGLE_CLOUD_API_KEY avec votre clé API Google Cloud',
            '3. Assurez-vous que les APIs suivantes sont activées dans Google Cloud Console:',
            '   - Geocoding API',
            '   - Directions API',
            '   - Maps JavaScript API'
          ]
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    // Tester l'API avec une simple requête
    const testUrl = `https://maps.googleapis.com/maps/api/geocode/json?address=Paris&key=${GOOGLE_CLOUD_API_KEY}`;
    
    console.log('Testing Google Cloud API...');
    const response = await fetch(testUrl);
    const data = await response.json();

    console.log('API Response status:', data.status);
    console.log('API Response:', JSON.stringify(data, null, 2));

    if (data.status === 'REQUEST_DENIED') {
      return new Response(
        JSON.stringify({ 
          status: 'error',
          message: 'La clé API est refusée par Google Cloud',
          details: data.error_message || 'Vérifiez que les APIs sont activées et que la clé n\'a pas de restrictions',
          instructions: [
            '1. Vérifiez que votre clé API est valide',
            '2. Activez ces APIs dans Google Cloud Console (https://console.cloud.google.com/apis/dashboard):',
            '   - Geocoding API',
            '   - Directions API', 
            '   - Maps JavaScript API',
            '3. Vérifiez les restrictions de la clé API:',
            '   - Allez dans Google Cloud Console > APIs & Services > Credentials',
            '   - Cliquez sur votre clé API',
            '   - Dans "API restrictions", choisissez "Don\'t restrict key" ou ajoutez les APIs nécessaires',
            '   - Dans "Application restrictions", choisissez "None" pour les tests'
          ],
          googleResponse: data
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    if (data.status === 'OK') {
      return new Response(
        JSON.stringify({ 
          status: 'success',
          message: 'L\'API Google Cloud fonctionne correctement !',
          keyLength: GOOGLE_CLOUD_API_KEY.length,
          keyPrefix: GOOGLE_CLOUD_API_KEY.substring(0, 8) + '...',
          testResult: {
            status: data.status,
            resultsCount: data.results?.length || 0,
            firstResult: data.results?.[0]?.formatted_address
          }
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify({ 
        status: 'warning',
        message: 'Réponse inattendue de Google Cloud',
        googleResponse: data
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('Test error:', error);
    return new Response(
      JSON.stringify({ 
        status: 'error',
        message: error.message,
        error: error.toString()
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
