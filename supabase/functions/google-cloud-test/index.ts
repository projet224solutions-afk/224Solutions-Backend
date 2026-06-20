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
    const serviceAccount = Deno.env.get('GOOGLE_CLOUD_SERVICE_ACCOUNT');
    const projectIdEnv = Deno.env.get('GOOGLE_CLOUD_PROJECT_ID');

    // Extract project_id safely - NEVER return raw secrets
    let projectId = 'unknown';
    let serviceAccountEmail = 'unknown';
    let hasValidConfig = false;

    // Try parsing GOOGLE_CLOUD_PROJECT_ID as JSON (it may contain the full service account)
    if (projectIdEnv) {
      try {
        const parsed = JSON.parse(projectIdEnv);
        if (parsed.project_id) {
          projectId = parsed.project_id;
          serviceAccountEmail = parsed.client_email || 'unknown';
          hasValidConfig = true;
        }
      } catch {
        // It's a plain project ID string
        projectId = projectIdEnv;
      }
    }

    // Also check the dedicated service account env var
    if (serviceAccount && !hasValidConfig) {
      try {
        const parsed = JSON.parse(serviceAccount);
        serviceAccountEmail = parsed.client_email || 'unknown';
        if (!projectId || projectId === 'unknown') {
          projectId = parsed.project_id || projectId;
        }
        hasValidConfig = true;
      } catch {
        // Invalid JSON
      }
    }

    if (!hasValidConfig && !projectIdEnv) {
      return new Response(
        JSON.stringify({ 
          status: 'error',
          error: 'Configuration manquante',
          hasProjectId: !!projectIdEnv,
          hasServiceAccount: !!serviceAccount
        }), 
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      );
    }

    // NEVER expose secrets - only return safe metadata
    const result = {
      status: 'success',
      message: 'Configuration Google Cloud valide',
      projectId: projectId,
      serviceAccountEmail: serviceAccountEmail,
      configured: hasValidConfig,
      timestamp: new Date().toISOString()
    };

    return new Response(
      JSON.stringify(result), 
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('❌ Google Cloud test error:', error);
    return new Response(
      JSON.stringify({ 
        status: 'error',
        error: error instanceof Error ? error.message : 'Unknown error' 
      }), 
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );
  }
});