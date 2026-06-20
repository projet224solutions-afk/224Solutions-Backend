import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface PubSubMessage {
  topic: string;
  data: Record<string, unknown>;
  attributes?: Record<string, string>;
}

async function getAccessToken(serviceAccount: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  
  // Create JWT header and payload
  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/pubsub",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };

  // Base64URL encode
  const base64UrlEncode = (obj: any) => {
    const json = JSON.stringify(obj);
    const base64 = btoa(json);
    return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };

  const headerEncoded = base64UrlEncode(header);
  const payloadEncoded = base64UrlEncode(payload);
  const signatureInput = `${headerEncoded}.${payloadEncoded}`;

  // Import private key
  const pemHeader = "-----BEGIN PRIVATE KEY-----";
  const pemFooter = "-----END PRIVATE KEY-----";
  const pemContents = serviceAccount.private_key
    .replace(pemHeader, "")
    .replace(pemFooter, "")
    .replace(/\s/g, "");
  
  const binaryDer = Uint8Array.from(atob(pemContents), c => c.charCodeAt(0));
  
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryDer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  // Sign the JWT
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signatureInput)
  );

  const signatureEncoded = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  const jwt = `${signatureInput}.${signatureEncoded}`;

  // Exchange JWT for access token
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  const tokenData = await tokenResponse.json();
  
  if (!tokenData.access_token) {
    throw new Error(`Failed to get access token: ${JSON.stringify(tokenData)}`);
  }
  
  return tokenData.access_token;
}

async function publishMessage(
  projectId: string,
  accessToken: string,
  topic: string,
  data: Record<string, unknown>,
  attributes?: Record<string, string>
): Promise<{ messageId: string }> {
  const url = `https://pubsub.googleapis.com/v1/projects/${projectId}/topics/${topic}:publish`;
  
  const messageData = btoa(JSON.stringify(data));
  
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      messages: [{
        data: messageData,
        attributes: attributes || {},
      }],
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Pub/Sub publish failed: ${response.status} - ${errorText}`);
  }

  const result = await response.json();
  return { messageId: result.messageIds?.[0] || "unknown" };
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Get and parse configuration (handle swapped env vars)
    let projectId = Deno.env.get('GOOGLE_CLOUD_PROJECT_ID');
    let serviceAccountJson = Deno.env.get('GOOGLE_CLOUD_SERVICE_ACCOUNT');

    // Check if variables are swapped (projectId contains JSON)
    if (projectId && projectId.includes('{') && projectId.includes('project_id')) {
      serviceAccountJson = projectId;
      const parsed = JSON.parse(projectId);
      projectId = parsed.project_id;
    }

    if (!projectId || !serviceAccountJson) {
      throw new Error('Google Cloud configuration missing');
    }

    const serviceAccount = JSON.parse(serviceAccountJson);
    const { topic, data, attributes } = await req.json() as PubSubMessage;

    if (!topic || !data) {
      throw new Error('Topic and data are required');
    }

    // Ensure topic name is valid (prefix with 'sol-' if starts with number)
    const validTopic = /^[0-9]/.test(topic) ? `sol-${topic}` : topic;

    console.log(`📤 Publishing to topic: ${validTopic}`);
    
    const accessToken = await getAccessToken(serviceAccount);
    const result = await publishMessage(projectId, accessToken, validTopic, data, attributes);

    console.log(`✅ Message published with ID: ${result.messageId}`);

    return new Response(
      JSON.stringify({ 
        success: true, 
        messageId: result.messageId,
        topic,
        timestamp: new Date().toISOString()
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('❌ Pub/Sub publish error:', error);
    return new Response(
      JSON.stringify({ 
        success: false, 
        error: error instanceof Error ? error.message : 'Unknown error' 
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    );
  }
});
