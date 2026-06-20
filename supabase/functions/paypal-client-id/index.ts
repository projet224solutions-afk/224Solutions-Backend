/**
 * Returns the PayPal Client ID (publishable key) for frontend SDK
 * 224SOLUTIONS
 */
import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }
  const clientId = Deno.env.get("PAYPAL_CLIENT_ID") || "";
  return new Response(JSON.stringify({ clientId }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
