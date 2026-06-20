import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

function isNumberLike(v: unknown): v is number {
  return typeof v === 'number' && !isNaN(v);
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { address, lat, lng, type } = await req.json();
    
    const MAPBOX_TOKEN = Deno.env.get('MAPBOX_ACCESS_TOKEN');

    if (!MAPBOX_TOKEN) {
      return new Response(
        JSON.stringify({
          status: 'CONFIG_ERROR',
          error: 'Mapbox API key not configured',
          message: 'MAPBOX_ACCESS_TOKEN n\'est pas configuré.',
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
      );
    }

    // Validation des paramètres
    if (type === 'geocode') {
      if (!address || address.trim() === '') {
        return new Response(
          JSON.stringify({ error: 'Address is required for geocoding' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
        );
      }
    } else if (type === 'reverse') {
      if (!isNumberLike(lat) || !isNumberLike(lng)) {
        return new Response(
          JSON.stringify({ error: 'Valid latitude and longitude are required for reverse geocoding' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
        );
      }
    } else {
      return new Response(
        JSON.stringify({ error: 'Invalid request type. Use "geocode" or "reverse"' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    console.log(`[geocode-address] Request: type=${type}, address="${address}", lat=${lat}, lng=${lng}`);

    let url = '';
    if (type === 'geocode' && address) {
      // Forward geocoding avec Mapbox
      url = `https://api.mapbox.com/geocoding/v5/mapbox.places/${encodeURIComponent(address)}.json?access_token=${MAPBOX_TOKEN}&language=fr&limit=5`;
    } else if (type === 'reverse') {
      // Reverse geocoding avec Mapbox
      url = `https://api.mapbox.com/geocoding/v5/mapbox.places/${lng},${lat}.json?access_token=${MAPBOX_TOKEN}&language=fr&limit=1`;
    }

    console.log(`[geocode-address] Calling Mapbox API`);
    const response = await fetch(url);
    const data = await response.json();

    if (!response.ok) {
      console.error('[geocode-address] Mapbox API error:', data);
      return new Response(
        JSON.stringify({
          status: 'API_ERROR',
          error: data.message || 'Mapbox API error',
          message: `Erreur Mapbox: ${data.message || response.statusText}`,
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    if (!data.features || data.features.length === 0) {
      return new Response(
        JSON.stringify({
          status: 'ZERO_RESULTS',
          results: [],
          message:
            type === 'geocode'
              ? `Aucune adresse trouvée pour: "${address}". Veuillez vérifier l'orthographe ou essayez une adresse plus précise.`
              : `Aucune adresse trouvée pour les coordonnées: ${lat}, ${lng}`,
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 200 }
      );
    }

    // Transformer la réponse Mapbox en format compatible avec l'ancien format Google
    const feature = data.features[0];
    const [longitude, latitude] = feature.center;

    // Construire les address_components à partir du context Mapbox
    const addressComponents: Array<{ long_name: string; short_name: string; types: string[] }> = [];
    
    if (feature.context) {
      for (const ctx of feature.context) {
        const id = ctx.id.split('.')[0];
        let types: string[] = [];
        
        if (id === 'neighborhood') types = ['neighborhood', 'political'];
        else if (id === 'locality') types = ['locality', 'political'];
        else if (id === 'place') types = ['locality', 'political'];
        else if (id === 'district') types = ['administrative_area_level_2', 'political'];
        else if (id === 'region') types = ['administrative_area_level_1', 'political'];
        else if (id === 'country') types = ['country', 'political'];
        else if (id === 'postcode') types = ['postal_code'];
        
        if (types.length > 0) {
          addressComponents.push({
            long_name: ctx.text,
            short_name: ctx.short_code || ctx.text,
            types
          });
        }
      }
    }

    // Convertir tous les résultats Mapbox en format Google-compatible
    const results = data.features.map((f: any) => ({
      formatted_address: f.place_name,
      geometry: {
        location: {
          lat: f.center[1],
          lng: f.center[0]
        }
      },
      place_id: f.id,
      address_components: []
    }));

    const formattedResponse = {
      status: 'OK',
      lat: latitude,
      lng: longitude,
      formatted_address: feature.place_name,
      place_id: feature.id,
      address_components: addressComponents,
      results: results,
    };

    console.log(`[geocode-address] Success: lat=${formattedResponse.lat}, lng=${formattedResponse.lng}`);

    return new Response(JSON.stringify(formattedResponse), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (error: any) {
    console.error('Geocode error:', error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
