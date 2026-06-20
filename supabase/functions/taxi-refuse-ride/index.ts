/**
 * TAXI-MOTO: Refus de course
 * Ajoute le conducteur à la liste declined_drivers et notifie le prochain conducteur disponible
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseClient = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  );

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("No authorization header");
    
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser(token);
    if (authError || !user) throw new Error("Authentication failed");

    const { rideId, driverId } = await req.json();
    if (!rideId || !driverId) throw new Error("rideId and driverId required");

    // Récupérer la course actuelle avec toutes les infos nécessaires
    const { data: currentRide, error: rideError } = await supabaseClient
      .from('taxi_trips')
      .select('*')
      .eq('id', rideId)
      .single();

    if (rideError || !currentRide) {
      throw new Error("Ride not found");
    }

    // Vérifier que la course est encore en attente
    if (currentRide.status !== 'requested') {
      console.log('[TAXI-REFUSE] Ride already processed:', currentRide.status);
      return new Response(
        JSON.stringify({ success: false, message: 'Ride already processed' }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Ajouter à declined_drivers
    const declinedList = currentRide.declined_drivers || [];
    if (!declinedList.includes(driverId)) {
      declinedList.push(driverId);
    }

    await supabaseClient
      .from('taxi_trips')
      .update({ declined_drivers: declinedList })
      .eq('id', rideId);

    console.log('[TAXI-REFUSE] Driver added to declined list:', { rideId, driverId, totalDeclined: declinedList.length });

    // Audit
    await supabaseClient.rpc('log_taxi_action', {
      p_action_type: 'ride_refused',
      p_actor_id: user.id,
      p_actor_type: 'driver',
      p_resource_type: 'ride',
      p_resource_id: rideId,
      p_details: { driverId, totalDeclined: declinedList.length }
    });

    // Trouver et notifier le prochain conducteur disponible
    const { data: nearbyDrivers } = await supabaseClient.rpc('find_nearby_taxi_drivers', {
      p_lat: currentRide.pickup_lat,
      p_lng: currentRide.pickup_lng,
      p_radius_km: 15, // Rayon élargi pour plus de conducteurs
      p_limit: 20
    });

    if (nearbyDrivers && nearbyDrivers.length > 0) {
      // Filtrer les conducteurs qui n'ont pas encore refusé
      const availableDrivers = nearbyDrivers.filter(
        (d: any) => !declinedList.includes(d.driver_id)
      );

      console.log('[TAXI-REFUSE] Available drivers after filtering:', availableDrivers.length);

      // Notifier les prochains conducteurs disponibles (max 5)
      const driversToNotify = availableDrivers.slice(0, 5);
      
      for (const driver of driversToNotify) {
        await supabaseClient.rpc('create_taxi_notification', {
          p_user_id: driver.user_id,
          p_type: 'new_ride_request',
          p_title: 'Course disponible !',
          p_body: `Course à ${driver.distance_km.toFixed(1)}km - ${currentRide.price_total} GNF`,
          p_data: { 
            rideId, 
            distance: driver.distance_km, 
            price: currentRide.price_total,
            pickupAddress: currentRide.pickup_address
          },
          p_ride_id: rideId
        });
        console.log('[TAXI-REFUSE] Notified next driver:', driver.driver_id);
      }
    } else {
      console.log('[TAXI-REFUSE] No more drivers available nearby');
    }

    return new Response(
      JSON.stringify({ success: true, driversDeclined: declinedList.length }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    console.error('[TAXI-REFUSE] ERROR:', errorMessage);
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});