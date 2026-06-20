import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface ServiceAccount {
  type: string;
  project_id: string;
  private_key_id: string;
  private_key: string;
  client_email: string;
  client_id: string;
  auth_uri: string;
  token_uri: string;
}

// Cache pour les tokens d'accès (évite de régénérer à chaque appel)
let accessTokenCache: { token: string; expiresAt: number } | null = null;

/**
 * Génère un JWT et l'échange contre un token d'accès Google Cloud
 */
async function getAccessToken(serviceAccount: ServiceAccount): Promise<string> {
  // Vérifier le cache
  if (accessTokenCache && Date.now() < accessTokenCache.expiresAt - 60000) {
    return accessTokenCache.token;
  }

  const now = Math.floor(Date.now() / 1000);
  const exp = now + 3600; // 1 heure

  // Créer le JWT header
  const header = { alg: 'RS256', typ: 'JWT' };
  
  // Créer le JWT payload
  const payload = {
    iss: serviceAccount.client_email,
    scope: 'https://www.googleapis.com/auth/cloud-platform',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: exp,
  };

  // Encoder en base64url
  const encoder = new TextEncoder();
  const headerB64 = btoa(JSON.stringify(header))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const payloadB64 = btoa(JSON.stringify(payload))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  const unsignedToken = `${headerB64}.${payloadB64}`;

  // Importer la clé privée
  const pemContents = serviceAccount.private_key
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s/g, '');
  
  const binaryKey = Uint8Array.from(atob(pemContents), c => c.charCodeAt(0));
  
  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    binaryKey,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign']
  );

  // Signer le token
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    cryptoKey,
    encoder.encode(unsignedToken)
  );

  const signatureB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  const jwt = `${unsignedToken}.${signatureB64}`;

  // Échanger le JWT contre un token d'accès
  const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });

  if (!tokenResponse.ok) {
    const error = await tokenResponse.text();
    console.error('[get-google-secret] Token exchange failed:', error);
    throw new Error(`Failed to get access token: ${error}`);
  }

  const tokenData = await tokenResponse.json();
  
  // Mettre en cache
  accessTokenCache = {
    token: tokenData.access_token,
    expiresAt: Date.now() + (tokenData.expires_in * 1000),
  };

  return tokenData.access_token;
}

/**
 * Récupère un secret depuis Google Secret Manager
 */
async function getSecret(
  projectId: string, 
  accessToken: string, 
  secretName: string,
  version: string = 'latest'
): Promise<string> {
  const url = `https://secretmanager.googleapis.com/v1/projects/${projectId}/secrets/${secretName}/versions/${version}:access`;
  
  console.log(`[get-google-secret] Fetching secret: ${secretName}`);
  
  const response = await fetch(url, {
    headers: {
      'Authorization': `Bearer ${accessToken}`,
    },
  });

  if (!response.ok) {
    const error = await response.text();
    console.error(`[get-google-secret] Failed to get secret ${secretName}:`, error);
    throw new Error(`Failed to get secret: ${error}`);
  }

  const data = await response.json();
  
  // Le payload est en base64
  const secretValue = atob(data.payload.data);
  
  console.log(`[get-google-secret] Successfully retrieved secret: ${secretName}`);
  
  return secretValue;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { secretName, version = 'latest' } = await req.json();

    if (!secretName) {
      return new Response(
        JSON.stringify({ error: 'secretName is required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    // Liste blanche des secrets autorisés (sécurité)
    const allowedSecrets = [
      'google-cloud-api-key',
      'google-maps-api-key',
    ];

    if (!allowedSecrets.includes(secretName)) {
      console.warn(`[get-google-secret] Unauthorized secret request: ${secretName}`);
      return new Response(
        JSON.stringify({ error: 'Secret not allowed' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
      );
    }

    // Récupérer le compte de service
    const serviceAccountJson = Deno.env.get('GOOGLE_CLOUD_SERVICE_ACCOUNT');
    const projectId = Deno.env.get('GOOGLE_CLOUD_PROJECT_ID');

    if (!serviceAccountJson || !projectId) {
      console.error('[get-google-secret] Missing configuration');
      return new Response(
        JSON.stringify({ 
          error: 'Google Cloud configuration missing',
          instructions: [
            'Configurez GOOGLE_CLOUD_SERVICE_ACCOUNT avec le JSON du compte de service',
            'Configurez GOOGLE_CLOUD_PROJECT_ID avec votre ID de projet'
          ]
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
      );
    }

    const serviceAccount = JSON.parse(serviceAccountJson);
    
    // Obtenir un token d'accès
    const accessToken = await getAccessToken(serviceAccount);
    
    // Récupérer le secret
    const secretValue = await getSecret(projectId, accessToken, secretName, version);

    return new Response(
      JSON.stringify({ 
        success: true,
        secretName,
        // On ne renvoie pas la valeur complète pour la sécurité dans les logs
        // La valeur est utilisée côté serveur seulement
        hasValue: !!secretValue,
        valueLength: secretValue.length
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[get-google-secret] Error:', error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
