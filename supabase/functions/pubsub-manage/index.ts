import { serve } from "https://deno.land/std@0.190.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

type ManageAction = 
  | { action: 'createTopic'; topicName: string }
  | { action: 'deleteTopic'; topicName: string }
  | { action: 'listTopics' }
  | { action: 'createSubscription'; topicName: string; subscriptionName: string; pushEndpoint?: string }
  | { action: 'deleteSubscription'; subscriptionName: string }
  | { action: 'listSubscriptions' };

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

async function createTopic(projectId: string, accessToken: string, topicName: string) {
  const url = `https://pubsub.googleapis.com/v1/projects/${projectId}/topics/${topicName}`;
  
  const response = await fetch(url, {
    method: "PUT",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
  });

  if (!response.ok && response.status !== 409) {
    const errorText = await response.text();
    throw new Error(`Create topic failed: ${response.status} - ${errorText}`);
  }

  return { name: `projects/${projectId}/topics/${topicName}`, created: response.status !== 409 };
}

async function deleteTopic(projectId: string, accessToken: string, topicName: string) {
  const url = `https://pubsub.googleapis.com/v1/projects/${projectId}/topics/${topicName}`;
  
  const response = await fetch(url, {
    method: "DELETE",
    headers: { "Authorization": `Bearer ${accessToken}` },
  });

  if (!response.ok && response.status !== 404) {
    const errorText = await response.text();
    throw new Error(`Delete topic failed: ${response.status} - ${errorText}`);
  }

  return { deleted: response.ok };
}

async function listTopics(projectId: string, accessToken: string) {
  const url = `https://pubsub.googleapis.com/v1/projects/${projectId}/topics`;
  
  const response = await fetch(url, {
    headers: { "Authorization": `Bearer ${accessToken}` },
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`List topics failed: ${response.status} - ${errorText}`);
  }

  const result = await response.json();
  return result.topics || [];
}

async function createSubscription(
  projectId: string, 
  accessToken: string, 
  topicName: string, 
  subscriptionName: string,
  pushEndpoint?: string
) {
  const url = `https://pubsub.googleapis.com/v1/projects/${projectId}/subscriptions/${subscriptionName}`;
  
  const body: any = {
    topic: `projects/${projectId}/topics/${topicName}`,
    ackDeadlineSeconds: 60,
    messageRetentionDuration: "604800s", // 7 days
    expirationPolicy: { ttl: "2678400s" }, // 31 days
  };

  if (pushEndpoint) {
    body.pushConfig = { pushEndpoint };
  }

  const response = await fetch(url, {
    method: "PUT",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok && response.status !== 409) {
    const errorText = await response.text();
    throw new Error(`Create subscription failed: ${response.status} - ${errorText}`);
  }

  return { 
    name: `projects/${projectId}/subscriptions/${subscriptionName}`, 
    created: response.status !== 409 
  };
}

async function deleteSubscription(projectId: string, accessToken: string, subscriptionName: string) {
  const url = `https://pubsub.googleapis.com/v1/projects/${projectId}/subscriptions/${subscriptionName}`;
  
  const response = await fetch(url, {
    method: "DELETE",
    headers: { "Authorization": `Bearer ${accessToken}` },
  });

  if (!response.ok && response.status !== 404) {
    const errorText = await response.text();
    throw new Error(`Delete subscription failed: ${response.status} - ${errorText}`);
  }

  return { deleted: response.ok };
}

async function listSubscriptions(projectId: string, accessToken: string) {
  const url = `https://pubsub.googleapis.com/v1/projects/${projectId}/subscriptions`;
  
  const response = await fetch(url, {
    headers: { "Authorization": `Bearer ${accessToken}` },
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`List subscriptions failed: ${response.status} - ${errorText}`);
  }

  const result = await response.json();
  return result.subscriptions || [];
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
    const request = await req.json() as ManageAction;
    const accessToken = await getAccessToken(serviceAccount);

    // Validate topic/subscription names (must start with letter)
    const validateName = (name: string) => /^[0-9]/.test(name) ? `sol-${name}` : name;

    let result: any;

    switch (request.action) {
      case 'createTopic': {
        const topicName = validateName(request.topicName);
        console.log(`📌 Creating topic: ${topicName}`);
        result = await createTopic(projectId, accessToken, topicName);
        break;
      }
      
      case 'deleteTopic': {
        const topicName = validateName(request.topicName);
        console.log(`🗑️ Deleting topic: ${topicName}`);
        result = await deleteTopic(projectId, accessToken, topicName);
        break;
      }
      
      case 'listTopics':
        console.log('📋 Listing topics');
        result = await listTopics(projectId, accessToken);
        break;
      
      case 'createSubscription': {
        const topicName = validateName(request.topicName);
        const subName = validateName(request.subscriptionName);
        console.log(`📌 Creating subscription: ${subName} for topic: ${topicName}`);
        result = await createSubscription(
          projectId, 
          accessToken, 
          topicName, 
          subName,
          request.pushEndpoint
        );
        break;
      }
      
      case 'deleteSubscription': {
        const subName = validateName(request.subscriptionName);
        console.log(`🗑️ Deleting subscription: ${subName}`);
        result = await deleteSubscription(projectId, accessToken, subName);
        break;
      }
      
      case 'listSubscriptions':
        console.log('📋 Listing subscriptions');
        result = await listSubscriptions(projectId, accessToken);
        break;
      
      default:
        throw new Error('Invalid action');
    }

    console.log('✅ Action completed successfully');

    return new Response(
      JSON.stringify({ 
        success: true, 
        result,
        action: request.action,
        timestamp: new Date().toISOString()
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('❌ Pub/Sub manage error:', error);
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
