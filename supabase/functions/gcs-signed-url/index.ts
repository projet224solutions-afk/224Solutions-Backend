import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
}

interface SignedUrlRequest {
  action: 'upload' | 'download' | 'delete';
  fileName: string;
  contentType?: string;
  folder?: string;
  expiresInMinutes?: number;
  deleteToken?: string; // jeton de suppression délivré à l'upload (rollback sécurisé)
}

/**
 * Jeton de suppression : HMAC-SHA256(objectPath) avec une clé SERVEUR (private_key_id
 * du compte de service, jamais exposée au client). Seul celui qui a reçu ce jeton à
 * l'upload peut supprimer l'objet → empêche un utilisateur de supprimer les fichiers
 * d'autrui en devinant un chemin depuis une URL publique.
 */
async function computeDeleteToken(secret: string, objectPath: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(objectPath));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Génère une URL signée pour Google Cloud Storage
 * Compatible avec V4 signing
 */
async function generateSignedUrl(
  serviceAccount: ServiceAccount,
  bucketName: string,
  objectPath: string,
  options: {
    method: 'GET' | 'PUT' | 'DELETE';
    contentType?: string;
    expiresInSeconds: number;
  }
): Promise<string> {
  const now = new Date();
  const timestamp = now.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  const datestamp = timestamp.slice(0, 8);
  
  const credentialScope = `${datestamp}/auto/storage/goog4_request`;
  const credential = `${serviceAccount.client_email}/${credentialScope}`;

  // Headers signés
  const signedHeaders = 'host';
  const host = `${bucketName}.storage.googleapis.com`;

  // Paramètres de requête canoniques
  const queryParams: Record<string, string> = {
    'X-Goog-Algorithm': 'GOOG4-RSA-SHA256',
    'X-Goog-Credential': credential,
    'X-Goog-Date': timestamp,
    'X-Goog-Expires': options.expiresInSeconds.toString(),
    'X-Goog-SignedHeaders': signedHeaders,
  };

  // Trier les paramètres
  const sortedParams = Object.keys(queryParams).sort();
  const canonicalQueryString = sortedParams
    .map(key => `${encodeURIComponent(key)}=${encodeURIComponent(queryParams[key])}`)
    .join('&');

  // Headers canoniques
  const canonicalHeaders = `host:${host}\n`;

  // Requête canonique
  const canonicalRequest = [
    options.method,
    `/${encodeURIComponent(objectPath).replace(/%2F/g, '/')}`,
    canonicalQueryString,
    canonicalHeaders,
    signedHeaders,
    'UNSIGNED-PAYLOAD',
  ].join('\n');

  // String to sign
  const encoder = new TextEncoder();
  const canonicalRequestHash = await crypto.subtle.digest(
    'SHA-256',
    encoder.encode(canonicalRequest)
  );
  const canonicalRequestHashHex = Array.from(new Uint8Array(canonicalRequestHash))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');

  const stringToSign = [
    'GOOG4-RSA-SHA256',
    timestamp,
    credentialScope,
    canonicalRequestHashHex,
  ].join('\n');

  // Importer la clé privée et signer
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

  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    cryptoKey,
    encoder.encode(stringToSign)
  );

  const signatureHex = Array.from(new Uint8Array(signature))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');

  // Construire l'URL finale
  const signedUrl = `https://${host}/${encodeURIComponent(objectPath).replace(/%2F/g, '/')}?${canonicalQueryString}&X-Goog-Signature=${signatureHex}`;

  return signedUrl;
}

/**
 * Génère un nom de fichier unique
 */
function generateUniqueFileName(originalName: string): string {
  const timestamp = Date.now();
  const random = Math.random().toString(36).substring(2, 8);
  const extension = originalName.split('.').pop() || '';
  const baseName = originalName.replace(/\.[^/.]+$/, '').replace(/[^a-zA-Z0-9]/g, '-');
  return `${baseName}-${timestamp}-${random}.${extension}`;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  // Health check public (GET) — sans auth
  if (req.method === 'GET') {
    const hasServiceAccount = !!Deno.env.get('GOOGLE_CLOUD_SERVICE_ACCOUNT');
    const bucketName = Deno.env.get('GCS_BUCKET_NAME') || '224solutions';
    return new Response(
      JSON.stringify({ status: hasServiceAccount ? 'ok' : 'not_configured', bucket: bucketName, ts: new Date().toISOString() }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  try {
    // Vérifier l'authentification
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    // Initialiser Supabase avec le token de l'utilisateur
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: { headers: { Authorization: authHeader } }
    });

    // Vérifier l'utilisateur
    const { data: { user }, error: userError } = await supabase.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: 'Invalid user' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );
    }

    const request = await req.json();

    // Health check support
    if (request.healthCheck === true) {
      const hasServiceAccount = !!Deno.env.get('GOOGLE_CLOUD_SERVICE_ACCOUNT');
      const bucketName = Deno.env.get('GCS_BUCKET_NAME') || '224solutions';
      return new Response(
        JSON.stringify({ 
          status: hasServiceAccount ? 'ok' : 'not_configured',
          bucket: bucketName,
          timestamp: new Date().toISOString()
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { 
      action, 
      fileName, 
      contentType = 'application/octet-stream', 
      folder = '',
      expiresInMinutes = 15 
    } = request as SignedUrlRequest;

    // Validation
    if (!action || !fileName) {
      return new Response(
        JSON.stringify({ error: 'action and fileName are required' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    if (!['upload', 'download', 'delete'].includes(action)) {
      return new Response(
        JSON.stringify({ error: 'action must be "upload", "download" or "delete"' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
      );
    }

    console.log(`[gcs-signed-url] User ${user.id} requesting ${action} URL for file: ${fileName}`);

    // Récupérer la configuration
    const serviceAccountJson = Deno.env.get('GOOGLE_CLOUD_SERVICE_ACCOUNT');
    const bucketName = Deno.env.get('GCS_BUCKET_NAME') || '224solutions';

    console.log(`[gcs-signed-url] Bucket: ${bucketName}`);
    console.log(`[gcs-signed-url] Service account configured: ${!!serviceAccountJson}`);
    
    if (serviceAccountJson) {
      console.log(`[gcs-signed-url] Service account JSON length: ${serviceAccountJson.length} chars`);
    }

    if (!serviceAccountJson) {
      console.error('[gcs-signed-url] GOOGLE_CLOUD_SERVICE_ACCOUNT secret is NOT configured!');
      return new Response(
        JSON.stringify({ 
          error: 'GCS not configured',
          fallback: true,
          message: 'GOOGLE_CLOUD_SERVICE_ACCOUNT secret is missing. Please add it in Lovable settings.',
          debug: {
            hasServiceAccount: false,
            bucketName,
          }
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 503 }
      );
    }

    let serviceAccount: ServiceAccount;
    try {
      serviceAccount = JSON.parse(serviceAccountJson);
      
      console.log(`[gcs-signed-url] Service account parsed successfully`);
      console.log(`[gcs-signed-url] Project: ${serviceAccount.project_id}`);
      console.log(`[gcs-signed-url] Client email: ${serviceAccount.client_email}`);
      console.log(`[gcs-signed-url] Has private_key: ${!!serviceAccount.private_key}`);
      
      // Validate required fields
      if (!serviceAccount.client_email || !serviceAccount.private_key || !serviceAccount.project_id) {
        console.error('[gcs-signed-url] Invalid service account: missing required fields');
        console.error(`  - client_email: ${!!serviceAccount.client_email}`);
        console.error(`  - private_key: ${!!serviceAccount.private_key}`);
        console.error(`  - project_id: ${!!serviceAccount.project_id}`);
        return new Response(
          JSON.stringify({ 
            error: 'Invalid GCS configuration',
            fallback: true,
            message: 'Service account is missing required fields (client_email, private_key, or project_id)',
            debug: {
              hasClientEmail: !!serviceAccount.client_email,
              hasPrivateKey: !!serviceAccount.private_key,
              hasProjectId: !!serviceAccount.project_id,
            }
          }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 503 }
        );
      }
    } catch (parseError) {
      console.error('[gcs-signed-url] Failed to parse service account JSON:', parseError);
      console.error('[gcs-signed-url] First 100 chars of JSON:', serviceAccountJson.substring(0, 100));
      return new Response(
        JSON.stringify({ 
          error: 'Invalid GCS configuration',
          fallback: true,
          message: 'Failed to parse service account JSON. Make sure it is valid JSON format.',
          debug: {
            parseError: String(parseError),
            jsonLength: serviceAccountJson.length,
          }
        }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 503 }
      );
    }

    // ── Suppression atomique (rollback d'un fichier orphelin) ──────────────
    // Le client passe fileName = objectPath complet (déjà préfixé du dossier).
    // On génère une URL signée DELETE et on l'exécute CÔTÉ SERVEUR (pas de CORS).
    if (action === 'delete') {
      const delObjectPath = folder ? `${folder}/${fileName}` : fileName;

      // 🔒 Autorisation : exiger le jeton signé délivré à l'upload (sinon n'importe
      // quel utilisateur authentifié pourrait supprimer le fichier d'autrui).
      const expectedToken = await computeDeleteToken(serviceAccount.private_key_id, delObjectPath);
      if (!request.deleteToken || request.deleteToken !== expectedToken) {
        console.warn(`[gcs-signed-url] DELETE refusé (jeton invalide) pour ${delObjectPath}`);
        return new Response(
          JSON.stringify({ error: 'invalid_delete_token' }),
          { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 403 }
        );
      }

      const signedDeleteUrl = await generateSignedUrl(serviceAccount, bucketName, delObjectPath, {
        method: 'DELETE',
        expiresInSeconds: 120,
      });
      const delResp = await fetch(signedDeleteUrl, { method: 'DELETE' });
      // 204 = supprimé ; 404 = déjà absent → on considère que c'est OK (idempotent).
      const ok = delResp.ok || delResp.status === 404;
      console.log(`[gcs-signed-url] DELETE ${delObjectPath} → HTTP ${delResp.status} (ok=${ok})`);
      return new Response(
        JSON.stringify({ success: ok, status: delResp.status, objectPath: delObjectPath }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: ok ? 200 : 502 }
      );
    }

    // Générer le chemin de l'objet
    const uniqueFileName = action === 'upload'
      ? generateUniqueFileName(fileName)
      : fileName;
    
    const objectPath = folder 
      ? `${folder}/${uniqueFileName}` 
      : uniqueFileName;

    console.log(`[gcs-signed-url] Generating ${action} URL for: ${objectPath}`);

    // Générer l'URL signée
    const signedUrl = await generateSignedUrl(
      serviceAccount,
      bucketName,
      objectPath,
      {
        method: action === 'upload' ? 'PUT' : 'GET',
        contentType: action === 'upload' ? contentType : undefined,
        expiresInSeconds: expiresInMinutes * 60,
      }
    );

    console.log(`[gcs-signed-url] Generated ${action} URL successfully`);

    // Jeton de suppression sécurisé délivré à l'upload (pour un rollback ultérieur).
    const deleteToken = action === 'upload'
      ? await computeDeleteToken(serviceAccount.private_key_id, objectPath)
      : undefined;

    return new Response(
      JSON.stringify({
        success: true,
        signedUrl,
        objectPath,
        bucket: bucketName,
        expiresAt: new Date(Date.now() + expiresInMinutes * 60 * 1000).toISOString(),
        // Pour l'upload, on renvoie aussi l'URL publique finale (si le bucket est configuré pour)
        publicUrl: `https://storage.googleapis.com/${bucketName}/${objectPath}`,
        deleteToken,
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('[gcs-signed-url] Error:', error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 500 }
    );
  }
});
