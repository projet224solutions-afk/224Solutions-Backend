/**
 * 🔐 COGNITO AUTH PROXY
 * Proxy sécurisé pour les opérations Cognito nécessitant SECRET_HASH
 * Calcule le HMAC-SHA256 côté serveur pour les App Clients avec secret
 * 
 * Actions supportées: signIn, signUp, forgotPassword, confirmSignUp, confirmPassword
 */

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version',
};

/**
 * Calcule le SECRET_HASH requis par Cognito pour les clients avec secret
 * HMAC-SHA256(username + clientId, clientSecret) en base64
 */
async function computeSecretHash(username: string, clientId: string, clientSecret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(clientSecret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const signature = await crypto.subtle.sign(
    'HMAC',
    key,
    encoder.encode(username + clientId)
  );
  // Base64 encode
  return btoa(String.fromCharCode(...new Uint8Array(signature)));
}

/**
 * Appel direct à l'API Cognito (sans AWS Sig V4, car les actions client n'en ont pas besoin)
 */
async function cognitoClientRequest(target: string, payload: Record<string, unknown>, region: string): Promise<{ ok: boolean; data: any }> {
  const cleanRegion = region.replace(/https?:\/\//g, '').replace(/cognito-idp\./g, '').replace(/\.amazonaws\.com.*/g, '').replace(/\/.*/g, '').trim() || 'eu-central-1';
  const host = `cognito-idp.${cleanRegion}.amazonaws.com`;
  
  const response = await fetch(`https://${host}/`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-amz-json-1.1',
      'X-Amz-Target': `AWSCognitoIdentityProviderService.${target}`,
    },
    body: JSON.stringify(payload),
  });
  
  const data = await response.json();
  return { ok: response.ok, data };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { action, email, password, code, newPassword, attributes } = await req.json();

    if (!action || !email) {
      return new Response(JSON.stringify({ error: 'action et email requis' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const region = Deno.env.get('AWS_COGNITO_REGION') || 'eu-central-1';
    const clientId = Deno.env.get('AWS_COGNITO_CLIENT_ID') || Deno.env.get('VITE_AWS_COGNITO_CLIENT_ID') || '';
    const clientSecret = Deno.env.get('AWS_COGNITO_CLIENT_SECRET') || '';
    const userPoolId = Deno.env.get('AWS_COGNITO_USER_POOL_ID') || '';

    if (!clientId) {
      return new Response(JSON.stringify({ error: 'COGNITO_CLIENT_ID non configuré' }), {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    // Calculer SECRET_HASH si un secret est configuré
    let secretHash: string | undefined;
    if (clientSecret) {
      secretHash = await computeSecretHash(email, clientId, clientSecret);
    }

    let result: { ok: boolean; data: any };

    switch (action) {
      case 'signIn': {
        if (!password) {
          return new Response(JSON.stringify({ error: 'password requis pour signIn' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        // Utiliser AdminInitiateAuth (nécessite AWS credentials) pour éviter SRP côté client
        // On utilise AdminInitiateAuth avec USER_PASSWORD_AUTH
        const accessKey = Deno.env.get('AWS_ACCESS_KEY_ID') || '';
        const secretKey = Deno.env.get('AWS_SECRET_ACCESS_KEY') || '';
        
        if (accessKey && secretKey) {
          // Utiliser l'API Admin (plus fiable avec secret)
          const authParams: Record<string, string> = {
            USERNAME: email,
            PASSWORD: password,
          };
          if (secretHash) authParams.SECRET_HASH = secretHash;

          result = await cognitoAdminRequest(
            'AWSCognitoIdentityProviderService.AdminInitiateAuth',
            {
              AuthFlow: 'ADMIN_USER_PASSWORD_AUTH',
              ClientId: clientId,
              UserPoolId: userPoolId,
              AuthParameters: authParams,
            },
            region, accessKey, secretKey
          );
        } else {
          // Fallback: InitiateAuth avec USER_PASSWORD_AUTH
          const authParams: Record<string, string> = {
            USERNAME: email,
            PASSWORD: password,
          };
          if (secretHash) authParams.SECRET_HASH = secretHash;

          result = await cognitoClientRequest('InitiateAuth', {
            AuthFlow: 'USER_PASSWORD_AUTH',
            ClientId: clientId,
            AuthParameters: authParams,
          }, region);
        }

        if (!result.ok) {
          const errorType = result.data?.__type?.split('#').pop() || 'AuthError';
          return new Response(JSON.stringify({ 
            error: result.data?.message || 'Erreur d\'authentification',
            code: errorType,
          }), {
            status: 401,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        // Retourner les tokens
        return new Response(JSON.stringify({
          success: true,
          authResult: result.data.AuthenticationResult,
          challengeName: result.data.ChallengeName,
          session: result.data.Session,
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      case 'signUp': {
        if (!password) {
          return new Response(JSON.stringify({ error: 'password requis pour signUp' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const userAttributes = [{ Name: 'email', Value: email }];
        if (attributes) {
          Object.entries(attributes).forEach(([key, value]) => {
            if (value) userAttributes.push({ Name: key, Value: value as string });
          });
        }

        const signUpPayload: Record<string, unknown> = {
          ClientId: clientId,
          Username: email,
          Password: password,
          UserAttributes: userAttributes,
        };
        if (secretHash) signUpPayload.SecretHash = secretHash;

        result = await cognitoClientRequest('SignUp', signUpPayload, region);

        if (!result.ok) {
          const errorType = result.data?.__type?.split('#').pop() || 'SignUpError';
          return new Response(JSON.stringify({
            error: result.data?.message || 'Erreur d\'inscription',
            code: errorType,
          }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        return new Response(JSON.stringify({
          success: true,
          userConfirmed: result.data.UserConfirmed,
          userSub: result.data.UserSub,
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      case 'confirmSignUp': {
        if (!code) {
          return new Response(JSON.stringify({ error: 'code requis pour confirmSignUp' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const confirmPayload: Record<string, unknown> = {
          ClientId: clientId,
          Username: email,
          ConfirmationCode: code,
        };
        if (secretHash) confirmPayload.SecretHash = secretHash;

        result = await cognitoClientRequest('ConfirmSignUp', confirmPayload, region);

        if (!result.ok) {
          return new Response(JSON.stringify({
            error: result.data?.message || 'Erreur de confirmation',
            code: result.data?.__type?.split('#').pop() || 'ConfirmError',
          }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        return new Response(JSON.stringify({ success: true }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      case 'forgotPassword': {
        const forgotPayload: Record<string, unknown> = {
          ClientId: clientId,
          Username: email,
        };
        if (secretHash) forgotPayload.SecretHash = secretHash;

        result = await cognitoClientRequest('ForgotPassword', forgotPayload, region);

        if (!result.ok) {
          return new Response(JSON.stringify({
            error: result.data?.message || 'Erreur de réinitialisation',
            code: result.data?.__type?.split('#').pop() || 'ForgotPasswordError',
          }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        return new Response(JSON.stringify({ 
          success: true,
          deliveryMedium: result.data?.CodeDeliveryDetails?.DeliveryMedium,
          destination: result.data?.CodeDeliveryDetails?.Destination,
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      case 'confirmPassword': {
        if (!code || !newPassword) {
          return new Response(JSON.stringify({ error: 'code et newPassword requis' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        const confirmPwPayload: Record<string, unknown> = {
          ClientId: clientId,
          Username: email,
          ConfirmationCode: code,
          Password: newPassword,
        };
        if (secretHash) confirmPwPayload.SecretHash = secretHash;

        result = await cognitoClientRequest('ConfirmForgotPassword', confirmPwPayload, region);

        if (!result.ok) {
          return new Response(JSON.stringify({
            error: result.data?.message || 'Erreur de confirmation',
            code: result.data?.__type?.split('#').pop() || 'ConfirmPasswordError',
          }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }

        return new Response(JSON.stringify({ success: true }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      default:
        return new Response(JSON.stringify({ error: `Action inconnue: ${action}` }), {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
    }
  } catch (err) {
    console.error('❌ cognito-auth-proxy error:', err);
    return new Response(JSON.stringify({ error: err instanceof Error ? err.message : 'Erreur interne' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});

// ============================================
// AWS Signature V4 pour AdminInitiateAuth
// ============================================
async function sha256(message: string): Promise<ArrayBuffer> {
  return await crypto.subtle.digest('SHA-256', new TextEncoder().encode(message));
}

async function hmacSha256(key: ArrayBuffer, message: string): Promise<ArrayBuffer> {
  const cryptoKey = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return await crypto.subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(message));
}

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer)).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function getSignatureKey(key: string, dateStamp: string, region: string, service: string) {
  const kDate = await hmacSha256(new TextEncoder().encode('AWS4' + key).buffer, dateStamp);
  const kRegion = await hmacSha256(kDate, region);
  const kService = await hmacSha256(kRegion, service);
  return await hmacSha256(kService, 'aws4_request');
}

async function cognitoAdminRequest(target: string, payload: Record<string, unknown>, region: string, accessKey: string, secretKey: string): Promise<{ ok: boolean; data: any }> {
  const cleanRegion = region.replace(/https?:\/\//g, '').replace(/cognito-idp\./g, '').replace(/\.amazonaws\.com.*/g, '').replace(/\/.*/g, '').trim() || 'eu-central-1';
  const host = `cognito-idp.${cleanRegion}.amazonaws.com`;
  const body = JSON.stringify(payload);
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:\-]|\.\d{3}/g, '').slice(0, 15) + 'Z';
  const dateStamp = amzDate.slice(0, 8);
  const service = 'cognito-idp';
  const credentialScope = `${dateStamp}/${cleanRegion}/${service}/aws4_request`;

  const headers: Record<string, string> = {
    'Content-Type': 'application/x-amz-json-1.1',
    'Host': host,
    'X-Amz-Date': amzDate,
    'X-Amz-Target': target,
  };

  const sortedHeaders = Object.keys(headers).sort();
  const canonicalHeaders = sortedHeaders.map(k => `${k.toLowerCase()}:${headers[k]}\n`).join('');
  const signedHeaders = sortedHeaders.map(k => k.toLowerCase()).join(';');
  const payloadHash = toHex(await sha256(body));
  const canonicalRequest = ['POST', '/', '', canonicalHeaders, signedHeaders, payloadHash].join('\n');
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, credentialScope, toHex(await sha256(canonicalRequest))].join('\n');
  const signingKey = await getSignatureKey(secretKey, dateStamp, cleanRegion, service);
  const signature = toHex(await hmacSha256(signingKey, stringToSign));

  headers['Authorization'] = `AWS4-HMAC-SHA256 Credential=${accessKey}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

  const response = await fetch(`https://${host}/`, { method: 'POST', headers, body });
  return { ok: response.ok, data: await response.json() };
}
