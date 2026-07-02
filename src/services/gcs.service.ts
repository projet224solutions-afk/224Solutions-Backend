/**
 * ☁️ GCS — génération d'URL signées V4 (compte de service), portage Node de l'Edge
 * Function `gcs-signed-url`. Utilisé pour stocker images/vidéos dans le bucket GCS.
 *
 * Config (VPS .env) :
 *   • GOOGLE_CLOUD_SERVICE_ACCOUNT_B64  = base64 du JSON du compte de service (recommandé)
 *   • ou GOOGLE_CLOUD_SERVICE_ACCOUNT   = le JSON brut du compte de service (une ligne)
 *   • GCS_BUCKET_NAME                   = nom du bucket (défaut '224solutions')
 * Le JSON doit contenir client_email, private_key (PEM), project_id.
 */
import crypto from 'node:crypto';

export interface ServiceAccount {
  type?: string;
  project_id: string;
  private_key_id: string;
  private_key: string;
  client_email: string;
  client_id?: string;
}

export function getBucketName(): string {
  return process.env.GCS_BUCKET_NAME || '224solutions';
}

/** Bucket PRIVÉ (données sensibles : preuves de livraison). Jamais public en lecture. */
export function getPrivateBucketName(): string {
  return process.env.GCS_PRIVATE_BUCKET_NAME || '224solutions-private';
}

/** Charge + valide le compte de service depuis l'env (base64 prioritaire, sinon JSON brut). */
export function loadServiceAccount(): ServiceAccount | null {
  const b64 = process.env.GOOGLE_CLOUD_SERVICE_ACCOUNT_B64;
  const raw = process.env.GOOGLE_CLOUD_SERVICE_ACCOUNT;
  let jsonStr: string | null = null;

  if (b64 && b64.trim()) {
    try { jsonStr = Buffer.from(b64.trim(), 'base64').toString('utf8'); } catch { /* ignore */ }
  }
  if (!jsonStr && raw && raw.trim()) jsonStr = raw.trim();
  if (!jsonStr) return null;

  try {
    const sa = JSON.parse(jsonStr) as ServiceAccount;
    if (sa && sa.client_email && sa.private_key && sa.project_id) return sa;
  } catch { /* JSON invalide */ }
  return null;
}

/** Nom de fichier unique (réplique l'Edge : baseName-timestamp-random.ext). */
export function generateUniqueFileName(originalName: string): string {
  const timestamp = Date.now();
  const random = crypto.randomBytes(4).toString('hex').slice(0, 6);
  const extension = originalName.split('.').pop() || '';
  const baseName = originalName.replace(/\.[^/.]+$/, '').replace(/[^a-zA-Z0-9]/g, '-');
  return extension ? `${baseName}-${timestamp}-${random}.${extension}` : `${baseName}-${timestamp}-${random}`;
}

/** Jeton de suppression HMAC-SHA256(objectPath) avec private_key_id (secret serveur). */
export function computeDeleteToken(secret: string, objectPath: string): string {
  return crypto.createHmac('sha256', secret).update(objectPath).digest('hex');
}

/**
 * Génère une URL signée GCS V4 (GOOG4-RSA-SHA256, en-tête signé = host, payload non signé).
 * Identique à l'Edge Function (compatibilité totale côté client).
 */
export function generateSignedUrl(
  serviceAccount: ServiceAccount,
  bucketName: string,
  objectPath: string,
  options: { method: 'GET' | 'PUT' | 'DELETE'; expiresInSeconds: number }
): string {
  const now = new Date();
  const timestamp = now.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, ''); // YYYYMMDDTHHMMSSZ
  const datestamp = timestamp.slice(0, 8);

  const credentialScope = `${datestamp}/auto/storage/goog4_request`;
  const credential = `${serviceAccount.client_email}/${credentialScope}`;
  const signedHeaders = 'host';
  const host = `${bucketName}.storage.googleapis.com`;

  const queryParams: Record<string, string> = {
    'X-Goog-Algorithm': 'GOOG4-RSA-SHA256',
    'X-Goog-Credential': credential,
    'X-Goog-Date': timestamp,
    'X-Goog-Expires': String(options.expiresInSeconds),
    'X-Goog-SignedHeaders': signedHeaders,
  };

  const canonicalQueryString = Object.keys(queryParams).sort()
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(queryParams[k])}`)
    .join('&');

  const encodedPath = `/${encodeURIComponent(objectPath).replace(/%2F/g, '/')}`;
  const canonicalHeaders = `host:${host}\n`;
  const canonicalRequest = [
    options.method,
    encodedPath,
    canonicalQueryString,
    canonicalHeaders,
    signedHeaders,
    'UNSIGNED-PAYLOAD',
  ].join('\n');

  const canonicalRequestHashHex = crypto.createHash('sha256').update(canonicalRequest).digest('hex');
  const stringToSign = ['GOOG4-RSA-SHA256', timestamp, credentialScope, canonicalRequestHashHex].join('\n');

  const signatureHex = crypto.createSign('RSA-SHA256').update(stringToSign).sign(serviceAccount.private_key, 'hex');

  return `https://${host}${encodedPath}?${canonicalQueryString}&X-Goog-Signature=${signatureHex}`;
}
