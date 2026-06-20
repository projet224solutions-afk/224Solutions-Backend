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
    const { origin, destination } = await req.json();

    if (!origin || !destination) {
      throw new Error('Origin and destination are required');
    }

    const MAPBOX_TOKEN = Deno.env.get('MAPBOX_ACCESS_TOKEN');
    
    if (!MAPBOX_TOKEN) {
      throw new Error('Mapbox API key not configured');
    }

    // Appel à l'API Mapbox Directions
    const directionsUrl = `https://api.mapbox.com/directions/v5/mapbox/driving/${origin.lng},${origin.lat};${destination.lng},${destination.lat}?geometries=geojson&overview=full&access_token=${MAPBOX_TOKEN}`;

    console.log(`[calculate-route] Calling Mapbox Directions API`);
    const response = await fetch(directionsUrl);
    const data = await response.json();

    if (!response.ok || data.code !== 'Ok') {
      console.error('[calculate-route] Mapbox error:', data);
      throw new Error(`Mapbox Directions API error: ${data.message || data.code || 'Unknown error'}`);
    }

    if (!data.routes || data.routes.length === 0) {
      throw new Error('No route found');
    }

    const route = data.routes[0];

    // Extraire les coordonnées de la géométrie GeoJSON
    const routeCoordinates: [number, number][] = route.geometry.coordinates;

    // Calculer la distance en km et la durée en minutes
    const distanceKm = route.distance / 1000;
    const durationMin = Math.ceil(route.duration / 60);

    // Formater les textes de distance et durée
    const distanceText = distanceKm < 1 
      ? `${Math.round(route.distance)} m` 
      : `${distanceKm.toFixed(1)} km`;
    
    const durationText = durationMin < 60 
      ? `${durationMin} min` 
      : `${Math.floor(durationMin / 60)} h ${durationMin % 60} min`;

    console.log(`[calculate-route] Success: distance=${distanceKm.toFixed(2)}km, duration=${durationMin}min`);

    return new Response(
      JSON.stringify({
        success: true,
        route: routeCoordinates,
        distance: distanceKm,
        duration: durationMin,
        distanceText: distanceText,
        durationText: durationText,
        startAddress: `${origin.lat}, ${origin.lng}`,
        endAddress: `${destination.lat}, ${destination.lng}`
      }),
      { 
        headers: { 
          ...corsHeaders, 
          'Content-Type': 'application/json' 
        } 
      }
    );

  } catch (error: any) {
    console.error('Calculate route error:', error);
    return new Response(
      JSON.stringify({ 
        success: false,
        error: error.message 
      }),
      { 
        headers: { 
          ...corsHeaders, 
          'Content-Type': 'application/json' 
        }, 
        status: 500 
      }
    );
  }
});
