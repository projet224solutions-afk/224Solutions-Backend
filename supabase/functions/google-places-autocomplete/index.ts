import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

/**
 * Google Places Autocomplete Edge Function
 * Provides address autocomplete with precise GPS coordinates
 * 224Solutions - GPS Ultra-Precise System
 */
serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const { action, query, placeId, latitude, longitude, sessionToken, origin, destination } = body;
    const GOOGLE_API_KEY = Deno.env.get('GOOGLE_CLOUD_API_KEY');

    if (!GOOGLE_API_KEY) {
      throw new Error('Google Cloud API key not configured');
    }

    console.log(`[google-places-autocomplete] Action: ${action}, Query: "${query}", PlaceId: ${placeId}`);

    // Action 1: Autocomplete - Get address suggestions
    if (action === 'autocomplete') {
      if (!query || query.trim().length < 2) {
        return new Response(
          JSON.stringify({ predictions: [], status: 'INVALID_REQUEST' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Build autocomplete URL with Guinea focus
      let url = `https://maps.googleapis.com/maps/api/place/autocomplete/json?input=${encodeURIComponent(query)}&key=${GOOGLE_API_KEY}`;
      
      // Add location bias for Guinea (Conakry center)
      url += `&location=9.509167,-13.712222&radius=100000`; // 100km radius around Conakry
      url += `&components=country:gn`; // Restrict to Guinea
      url += `&language=fr`;
      url += `&types=establishment|geocode`; // Include places and addresses
      
      if (sessionToken) {
        url += `&sessiontoken=${sessionToken}`;
      }

      // Add proximity bias if user location provided
      if (latitude && longitude) {
        url = url.replace(/location=[^&]+/, `location=${latitude},${longitude}`);
        url += `&strictbounds=false`; // Allow results outside radius but prioritize nearby
      }

      const response = await fetch(url);
      const data = await response.json();

      console.log(`[google-places-autocomplete] Autocomplete status: ${data.status}, results: ${data.predictions?.length || 0}`);

      if (data.status === 'OK' || data.status === 'ZERO_RESULTS') {
        // Format predictions for frontend
        const predictions = (data.predictions || []).map((p: any) => ({
          placeId: p.place_id,
          description: p.description,
          mainText: p.structured_formatting?.main_text || p.description.split(',')[0],
          secondaryText: p.structured_formatting?.secondary_text || '',
          types: p.types || []
        }));

        return new Response(
          JSON.stringify({ predictions, status: data.status }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      throw new Error(`Places API error: ${data.status}`);
    }

    // Action 2: Place Details - Get precise coordinates from place_id
    if (action === 'details') {
      if (!placeId) {
        return new Response(
          JSON.stringify({ error: 'placeId is required for details' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
        );
      }

      let url = `https://maps.googleapis.com/maps/api/place/details/json?place_id=${placeId}&key=${GOOGLE_API_KEY}`;
      url += `&fields=name,formatted_address,geometry,place_id,address_components,types`;
      url += `&language=fr`;
      
      if (sessionToken) {
        url += `&sessiontoken=${sessionToken}`;
      }

      const response = await fetch(url);
      const data = await response.json();

      console.log(`[google-places-autocomplete] Details status: ${data.status}`);

      if (data.status === 'OK' && data.result) {
        const result = data.result;
        
        // Extract address components
        const addressComponents: Record<string, string> = {};
        (result.address_components || []).forEach((comp: any) => {
          comp.types.forEach((type: string) => {
            addressComponents[type] = comp.long_name;
          });
        });

        const placeDetails = {
          placeId: result.place_id,
          formattedAddress: result.formatted_address,
          name: result.name,
          latitude: result.geometry?.location?.lat,
          longitude: result.geometry?.location?.lng,
          viewport: result.geometry?.viewport,
          types: result.types || [],
          addressComponents: {
            streetNumber: addressComponents.street_number || '',
            street: addressComponents.route || '',
            neighborhood: addressComponents.neighborhood || addressComponents.sublocality_level_1 || '',
            city: addressComponents.locality || addressComponents.administrative_area_level_2 || '',
            region: addressComponents.administrative_area_level_1 || '',
            country: addressComponents.country || 'Guinée',
            postalCode: addressComponents.postal_code || ''
          }
        };

        return new Response(
          JSON.stringify({ place: placeDetails, status: 'OK' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      throw new Error(`Place Details error: ${data.status}`);
    }

    // Action 3: Reverse Geocode - Get address from coordinates
    if (action === 'reverse') {
      if (!latitude || !longitude) {
        return new Response(
          JSON.stringify({ error: 'latitude and longitude are required for reverse geocoding' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
        );
      }

      const url = `https://maps.googleapis.com/maps/api/geocode/json?latlng=${latitude},${longitude}&key=${GOOGLE_API_KEY}&language=fr`;
      
      const response = await fetch(url);
      const data = await response.json();

      console.log(`[google-places-autocomplete] Reverse geocode status: ${data.status}`);

      if (data.status === 'OK' && data.results?.length > 0) {
        const result = data.results[0];
        
        // Extract address components
        const addressComponents: Record<string, string> = {};
        (result.address_components || []).forEach((comp: any) => {
          comp.types.forEach((type: string) => {
            addressComponents[type] = comp.long_name;
          });
        });

        const placeDetails = {
          placeId: result.place_id,
          formattedAddress: result.formatted_address,
          latitude: result.geometry?.location?.lat || latitude,
          longitude: result.geometry?.location?.lng || longitude,
          types: result.types || [],
          addressComponents: {
            streetNumber: addressComponents.street_number || '',
            street: addressComponents.route || '',
            neighborhood: addressComponents.neighborhood || addressComponents.sublocality_level_1 || '',
            city: addressComponents.locality || addressComponents.administrative_area_level_2 || 'Conakry',
            region: addressComponents.administrative_area_level_1 || '',
            country: addressComponents.country || 'Guinée',
            postalCode: addressComponents.postal_code || ''
          }
        };

        return new Response(
          JSON.stringify({ place: placeDetails, status: 'OK' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Fallback if no results
      return new Response(
        JSON.stringify({ 
          place: {
            latitude,
            longitude,
            formattedAddress: `${latitude.toFixed(6)}, ${longitude.toFixed(6)}`,
            addressComponents: { city: 'Conakry', country: 'Guinée' }
          },
          status: 'FALLBACK'
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Action 4: Calculate distance and duration using Directions API
    if (action === 'directions') {
      
      if (!origin?.latitude || !origin?.longitude || !destination?.latitude || !destination?.longitude) {
        return new Response(
          JSON.stringify({ error: 'Origin and destination coordinates are required' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
        );
      }

      const url = `https://maps.googleapis.com/maps/api/directions/json?origin=${origin.latitude},${origin.longitude}&destination=${destination.latitude},${destination.longitude}&mode=driving&key=${GOOGLE_API_KEY}&language=fr`;
      
      const response = await fetch(url);
      const data = await response.json();

      console.log(`[google-places-autocomplete] Directions status: ${data.status}`);

      if (data.status === 'OK' && data.routes?.length > 0) {
        const route = data.routes[0];
        const leg = route.legs[0];

        return new Response(
          JSON.stringify({
            status: 'OK',
            distance: {
              value: leg.distance.value, // meters
              text: leg.distance.text
            },
            duration: {
              value: leg.duration.value, // seconds
              text: leg.duration.text
            },
            startAddress: leg.start_address,
            endAddress: leg.end_address,
            polyline: route.overview_polyline?.points || ''
          }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      throw new Error(`Directions API error: ${data.status}`);
    }

    return new Response(
      JSON.stringify({ error: 'Invalid action. Use: autocomplete, details, reverse, or directions' }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
    );

  } catch (error: any) {
    console.error('[google-places-autocomplete] Error:', error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
