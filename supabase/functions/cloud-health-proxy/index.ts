import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    let service: string | undefined;
    try {
      const body = await req.json();
      service = body?.service;
    } catch {
      // Empty body is fine — check all services
    }

    const results: Record<string, any> = {};

    // AWS Backend Health Check
    const awsBackendUrl = Deno.env.get('AWS_BACKEND_URL') || '';

    if (!service || service === 'aws-backend') {
      if (!awsBackendUrl) {
        results['aws-backend'] = {
          status: 'outage',
          responseTime: 0,
          message: 'AWS_BACKEND_URL non configuré',
        };
      } else {
        const start = Date.now();
        try {
          const controller = new AbortController();
          const timeout = setTimeout(() => controller.abort(), 8000);
          const res = await fetch(`${awsBackendUrl}/health`, { signal: controller.signal });
          clearTimeout(timeout);
          const rt = Date.now() - start;
          const isReachable = res.status < 500;
          results['aws-backend'] = {
            status: isReachable ? (rt > 2000 ? 'degraded' : 'operational') : 'degraded',
            responseTime: rt,
            message: isReachable ? `OK - ${rt}ms` : `HTTP ${res.status}`,
            httpStatus: res.status,
          };
        } catch (e: any) {
          results['aws-backend'] = {
            status: 'outage',
            responseTime: Date.now() - start,
            message: e?.name === 'AbortError' ? 'Timeout (>8s)' : `Serveur inaccessible: ${e?.message || 'Erreur réseau'}`,
          };
        }
      }
    }

    // AWS Cognito Check
    if (!service || service === 'aws-cognito') {
      if (!awsBackendUrl) {
        results['aws-cognito'] = {
          status: 'outage',
          responseTime: 0,
          message: 'AWS_BACKEND_URL non configuré',
        };
      } else {
        const start = Date.now();
        try {
          const controller = new AbortController();
          const timeout = setTimeout(() => controller.abort(), 8000);
          const res = await fetch(`${awsBackendUrl}/api/cognito/validate-token`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ token: 'health-check' }),
            signal: controller.signal,
          });
          clearTimeout(timeout);
          const rt = Date.now() - start;
          const isReachable = res.status < 500;
          results['aws-cognito'] = {
            status: isReachable ? (rt > 2000 ? 'degraded' : 'operational') : 'degraded',
            responseTime: rt,
            message: `Cognito accessible - ${rt}ms`,
            httpStatus: res.status,
          };
        } catch (e: any) {
          results['aws-cognito'] = {
            status: 'outage',
            responseTime: Date.now() - start,
            message: e?.name === 'AbortError' ? 'Timeout' : `Inaccessible: ${e?.message || 'Erreur'}`,
          };
        }
      }
    }

    return new Response(JSON.stringify({ 
      status: 'success', 
      results,
      timestamp: new Date().toISOString() 
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    return new Response(JSON.stringify({ 
      status: 'error', 
      error: error instanceof Error ? error.message : 'Unknown' 
    }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
