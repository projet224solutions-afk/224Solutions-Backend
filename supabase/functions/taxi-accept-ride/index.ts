/**
 * TAXI-MOTO: Acceptation de course avec locks anti-race
 * Gère l'acceptation sécurisée avec vérification de disponibilité
 */

import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const logStep = (step: string, details?: unknown) => {
  console.log(`[TAXI-ACCEPT] ${step}`, details ? JSON.stringify(details) : '');
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
    logStep('Function started');

    // Auth
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("No authorization header");
    
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser(token);
    if (authError || !user) throw new Error("Authentication failed");
    
    logStep('User authenticated', { userId: user.id });

    // Parse request
    const { rideId, driverId } = await req.json();
    if (!rideId || !driverId) throw new Error("rideId and driverId required");
    
    logStep('Request parsed', { rideId, driverId });

    // 1. ACQUIRE LOCK
    const lockId = `driver_${user.id}`;
    const { data: lockAcquired } = await supabaseClient.rpc('acquire_taxi_lock', {
      p_resource_type: 'ride',
      p_resource_id: rideId,
      p_locked_by: lockId,
      p_ttl_seconds: 30
    });

    if (!lockAcquired) {
      logStep('Lock failed - ride already being processed');
      return new Response(
        JSON.stringify({ error: 'Cette course est déjà en cours d\'attribution', code: 'LOCKED' }),
        { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    logStep('Lock acquired');

    try {
      // 2. CHECK RIDE STATUS
      const { data: ride, error: rideError } = await supabaseClient
        .from('taxi_trips')
        .select('status, driver_id, customer_id')
        .eq('id', rideId)
        .single();

      if (rideError) throw rideError;
      if (!ride) throw new Error('Ride not found');

      if (ride.status !== 'requested') {
        logStep('Ride not available', { currentStatus: ride.status });
        return new Response(
          JSON.stringify({ error: 'Course déjà attribuée ou expirée', code: 'ALREADY_ASSIGNED' }),
          { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      logStep('Ride available');

      // 3. VERIFY DRIVER STATUS
      const { data: driver } = await supabaseClient
        .from('taxi_drivers')
        .select('status, is_online')
        .eq('id', driverId)
        .eq('user_id', user.id)
        .single();

      const validStatuses = ['available', 'online'];
      if (!driver || !driver.is_online || !validStatuses.includes(driver.status)) {
        logStep('Driver validation failed', { driver, expected: validStatuses });
        throw new Error('Driver not available');
      }

      logStep('Driver verified');

      // 4. ASSIGN RIDE
      const { error: updateError } = await supabaseClient
        .from('taxi_trips')
        .update({
          driver_id: driverId,
          status: 'accepted',
          accepted_at: new Date().toISOString(),
        })
        .eq('id', rideId)
        .eq('status', 'requested'); // Optimistic concurrency

      if (updateError) throw updateError;

      logStep('Ride assigned');

      // 5. UPDATE DRIVER STATUS
      await supabaseClient
        .from('taxi_drivers')
        .update({ status: 'on_trip', updated_at: new Date().toISOString() })
        .eq('id', driverId);

      logStep('Driver status updated');

      // 6. AUDIT LOG
      await supabaseClient.rpc('log_taxi_action', {
        p_action_type: 'ride_accepted',
        p_actor_id: user.id,
        p_actor_type: 'driver',
        p_resource_type: 'ride',
        p_resource_id: rideId,
        p_details: { driverId, timestamp: new Date().toISOString() }
      });

      logStep('Audit logged');

      // 7. NOTIFY CUSTOMER
      await supabaseClient.rpc('create_taxi_notification', {
        p_user_id: ride.customer_id,
        p_type: 'ride_accepted',
        p_title: 'Conducteur en route !',
        p_body: 'Votre conducteur arrive',
        p_data: { rideId, driverId },
        p_ride_id: rideId
      });

      logStep('Customer notified');

      return new Response(
        JSON.stringify({ success: true, rideId }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );

    } finally {
      // 8. RELEASE LOCK
      await supabaseClient.rpc('release_taxi_lock', {
        p_resource_type: 'ride',
        p_resource_id: rideId,
        p_locked_by: lockId
      });
      logStep('Lock released');
    }

  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    logStep('ERROR', { message: errorMessage });
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});