import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { action, data } = await req.json();
    const MAPBOX_TOKEN = Deno.env.get('MAPBOX_ACCESS_TOKEN');

    if (!MAPBOX_TOKEN) {
      throw new Error('Mapbox access token not configured');
    }

    let mapboxUrl = '';

    // Route calculation (Directions API)
    if (action === 'route') {
      const { start, end } = data;
      mapboxUrl = `https://api.mapbox.com/directions/v5/mapbox/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?geometries=geojson&access_token=${MAPBOX_TOKEN}`;
      
      console.log(`[Mapbox Proxy] Calculating route from [${start.latitude},${start.longitude}] to [${end.latitude},${end.longitude}]`);
    }
    
    // Reverse geocoding (coordinates -> address)
    else if (action === 'reverse-geocode') {
      const { latitude, longitude } = data;
      mapboxUrl = `https://api.mapbox.com/geocoding/v5/mapbox.places/${longitude},${latitude}.json?access_token=${MAPBOX_TOKEN}&language=fr`;
      
      console.log(`[Mapbox Proxy] Reverse geocoding [${latitude},${longitude}]`);
    }
    
    // Address search (autocomplete)
    else if (action === 'search-address') {
      const { query, proximity } = data;
      mapboxUrl = `https://api.mapbox.com/geocoding/v5/mapbox.places/${encodeURIComponent(query)}.json?access_token=${MAPBOX_TOKEN}&language=fr&country=GN&limit=5`;
      
      if (proximity) {
        mapboxUrl += `&proximity=${proximity.longitude},${proximity.latitude}`;
      }
      
      console.log(`[Mapbox Proxy] Searching address: "${query}"`);
    }
    
    // Geocoding (address -> coordinates)
    else if (action === 'geocode') {
      const { address } = data;
      mapboxUrl = `https://api.mapbox.com/geocoding/v5/mapbox.places/${encodeURIComponent(address)}.json?access_token=${MAPBOX_TOKEN}&language=fr&country=GN&limit=5`;
      
      console.log(`[Mapbox Proxy] Geocoding address: "${address}"`);
    }
    
    else {
      throw new Error('Invalid action specified');
    }

    // Call Mapbox API
    const response = await fetch(mapboxUrl);
    const mapboxData = await response.json();

    if (!response.ok) {
      console.error('[Mapbox Proxy] Error from Mapbox API:', mapboxData);
      throw new Error(`Mapbox API error: ${mapboxData.message || response.statusText}`);
    }

    console.log(`[Mapbox Proxy] Request successful for action: ${action}`);

    return new Response(
      JSON.stringify(mapboxData),
      { 
        headers: { 
          ...corsHeaders, 
          'Content-Type': 'application/json' 
        } 
      }
    );

  } catch (error: any) {
    console.error('[Mapbox Proxy] Error:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
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
