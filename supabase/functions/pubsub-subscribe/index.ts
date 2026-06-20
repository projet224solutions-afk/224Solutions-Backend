import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface PullRequest {
  subscription: string;
  maxMessages?: number;
}

async function getAccessToken(serviceAccount: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  
  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/pubsub",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };

  const base64UrlEncode = (obj: any) => {
    const json = JSON.stringify(obj);
    const base64 = btoa(json);
    return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };

  const headerEncoded = base64UrlEncode(header);
  const payloadEncoded = base64UrlEncode(payload);
  const signatureInput = `${headerEncoded}.${payloadEncoded}`;

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

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signatureInput)
  );

  const signatureEncoded = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  const jwt = `${signatureInput}.${signatureEncoded}`;

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

async function pullMessages(
  projectId: string,
  accessToken: string,
  subscription: string,
  maxMessages: number = 10
): Promise<any[]> {
  const url = `https://pubsub.googleapis.com/v1/projects/${projectId}/subscriptions/${subscription}:pull`;
  
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      maxMessages,
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Pub/Sub pull failed: ${response.status} - ${errorText}`);
  }

  const result = await response.json();
  
  // Decode messages
  const messages = (result.receivedMessages || []).map((rm: any) => ({
    ackId: rm.ackId,
    messageId: rm.message.messageId,
    data: JSON.parse(atob(rm.message.data)),
    attributes: rm.message.attributes || {},
    publishTime: rm.message.publishTime,
  }));

  return messages;
}

async function acknowledgeMessages(
  projectId: string,
  accessToken: string,
  subscription: string,
  ackIds: string[]
): Promise<void> {
  if (ackIds.length === 0) return;

  const url = `https://pubsub.googleapis.com/v1/projects/${projectId}/subscriptions/${subscription}:acknowledge`;
  
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ ackIds }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Pub/Sub acknowledge failed: ${response.status} - ${errorText}`);
  }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // Get and parse configuration (handle swapped env vars)
    let projectId = Deno.env.get('GOOGLE_CLOUD_PROJECT_ID');
    let serviceAccountJson = Deno.env.get('GOOGLE_CLOUD_SERVICE_ACCOUNT');

    if (projectId && projectId.includes('{') && projectId.includes('project_id')) {
      serviceAccountJson = projectId;
      const parsed = JSON.parse(projectId);
      projectId = parsed.project_id;
    }

    if (!projectId || !serviceAccountJson) {
      throw new Error('Google Cloud configuration missing');
    }

    const serviceAccount = JSON.parse(serviceAccountJson);
    const { subscription, maxMessages = 10, autoAck = true } = await req.json() as PullRequest & { autoAck?: boolean };

    if (!subscription) {
      throw new Error('Subscription name is required');
    }

    console.log(`📥 Pulling messages from subscription: ${subscription}`);
    
    const accessToken = await getAccessToken(serviceAccount);
    const messages = await pullMessages(projectId, accessToken, subscription, maxMessages);

    console.log(`📨 Received ${messages.length} messages`);

    // Auto-acknowledge if requested
    if (autoAck && messages.length > 0) {
      const ackIds = messages.map((m: any) => m.ackId);
      await acknowledgeMessages(projectId, accessToken, subscription, ackIds);
      console.log(`✅ Acknowledged ${ackIds.length} messages`);
    }

    return new Response(
      JSON.stringify({ 
        success: true, 
        messages,
        count: messages.length,
        subscription,
        timestamp: new Date().toISOString()
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('❌ Pub/Sub subscribe error:', error);
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
