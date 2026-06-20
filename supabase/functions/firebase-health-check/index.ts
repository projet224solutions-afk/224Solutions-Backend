import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  const start = Date.now();

  try {
    // Test Firebase FCM endpoint reachability
    const fcmUrl = 'https://fcm.googleapis.com/fcm/send';
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);

    try {
      const res = await fetch(fcmUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({}),
        signal: controller.signal,
      });
      clearTimeout(timeout);
      const rt = Date.now() - start;

      // 401 = endpoint reachable but unauthorized (expected without key)
      // Any response < 500 means FCM infrastructure is up
      const isUp = res.status < 500;

      return new Response(JSON.stringify({
        status: isUp ? (rt > 3000 ? 'degraded' : 'operational') : 'degraded',
        responseTime: rt,
        message: isUp ? `FCM accessible - ${rt}ms (HTTP ${res.status})` : `FCM error HTTP ${res.status}`,
        httpStatus: res.status,
      }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    } catch (fetchErr: any) {
      clearTimeout(timeout);
      const rt = Date.now() - start;
      return new Response(JSON.stringify({
        status: fetchErr?.name === 'AbortError' ? 'degraded' : 'outage',
        responseTime: rt,
        message: fetchErr?.name === 'AbortError' ? 'FCM timeout (>5s)' : `FCM inaccessible: ${fetchErr?.message}`,
      }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }
  } catch (error) {
    return new Response(JSON.stringify({
      status: 'outage',
      responseTime: Date.now() - start,
      message: error instanceof Error ? error.message : 'Unknown error',
    }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
});
