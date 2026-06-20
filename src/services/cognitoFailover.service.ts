/**
 * 🔁 FAILOVER COGNITO — Supabase reste PRINCIPAL ; Cognito prend le relais UNIQUEMENT
 * quand Supabase est indisponible (panne/5xx/timeout) pour ne pas perdre une inscription
 * ni un login.
 *
 * Activé par config : si les secrets Cognito sont absents, tout renvoie { configured:false }
 * et le code appelant retombe sur le comportement Supabase normal (zéro effet de bord).
 *
 * Réconciliation (côté routes) : un compte créé pendant la panne est recréé dans Supabase
 * au login suivant (avec le mot de passe saisi → AUCUN mot de passe stocké).
 */
import { logger } from '../config/logger.js';

const subtle = globalThis.crypto.subtle;

export function isCognitoConfigured(): boolean {
  return !!(
    (process.env.AWS_COGNITO_USER_POOL_ID || process.env.VITE_AWS_COGNITO_USER_POOL_ID) &&
    (process.env.AWS_COGNITO_CLIENT_ID || process.env.VITE_AWS_COGNITO_CLIENT_ID) &&
    process.env.AWS_ACCESS_KEY_ID &&
    process.env.AWS_SECRET_ACCESS_KEY
  );
}

function cfg() {
  return {
    region: (process.env.AWS_COGNITO_REGION || process.env.VITE_AWS_COGNITO_REGION || 'eu-central-1')
      .replace(/https?:\/\//g, '').replace(/cognito-idp\./g, '').replace(/\.amazonaws\.com.*/g, '').replace(/\/.*/g, '').trim() || 'eu-central-1',
    userPoolId: (process.env.AWS_COGNITO_USER_POOL_ID || process.env.VITE_AWS_COGNITO_USER_POOL_ID || '').trim(),
    clientId: (process.env.AWS_COGNITO_CLIENT_ID || process.env.VITE_AWS_COGNITO_CLIENT_ID || '').trim(),
    clientSecret: (process.env.AWS_COGNITO_CLIENT_SECRET || '').trim(),
    accessKey: (process.env.AWS_ACCESS_KEY_ID || '').trim(),
    secretKey: (process.env.AWS_SECRET_ACCESS_KEY || '').trim(),
  };
}

// ── AWS Signature V4 (Web Crypto, Node 18+) ──
async function sha256(m: string): Promise<ArrayBuffer> { return subtle.digest('SHA-256', new TextEncoder().encode(m)); }
async function hmac(key: ArrayBuffer, m: string): Promise<ArrayBuffer> {
  const k = await subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return subtle.sign('HMAC', k, new TextEncoder().encode(m));
}
function hex(b: ArrayBuffer): string { return Array.from(new Uint8Array(b)).map((x) => x.toString(16).padStart(2, '0')).join(''); }
async function signingKey(secret: string, dateStamp: string, region: string, service: string) {
  const kDate = await hmac(new TextEncoder().encode('AWS4' + secret).buffer as ArrayBuffer, dateStamp);
  const kRegion = await hmac(kDate, region);
  const kService = await hmac(kRegion, service);
  return hmac(kService, 'aws4_request');
}

async function cognitoRequest(target: string, payload: Record<string, unknown>): Promise<{ ok: boolean; status: number; data: any }> {
  const c = cfg();
  const host = `cognito-idp.${c.region}.amazonaws.com`;
  const body = JSON.stringify(payload);
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '').slice(0, 15) + 'Z';
  const dateStamp = amzDate.slice(0, 8);
  const service = 'cognito-idp';
  const scope = `${dateStamp}/${c.region}/${service}/aws4_request`;
  const headers: Record<string, string> = {
    'Content-Type': 'application/x-amz-json-1.1', Host: host, 'X-Amz-Date': amzDate, 'X-Amz-Target': target,
  };
  const sorted = Object.keys(headers).sort();
  const canonicalHeaders = sorted.map((k) => `${k.toLowerCase()}:${headers[k]}\n`).join('');
  const signedHeaders = sorted.map((k) => k.toLowerCase()).join(';');
  const payloadHash = hex(await sha256(body));
  const canonical = ['POST', '/', '', canonicalHeaders, signedHeaders, payloadHash].join('\n');
  const toSign = ['AWS4-HMAC-SHA256', amzDate, scope, hex(await sha256(canonical))].join('\n');
  const sig = hex(await hmac(await signingKey(c.secretKey, dateStamp, c.region, service), toSign));
  headers['Authorization'] = `AWS4-HMAC-SHA256 Credential=${c.accessKey}/${scope}, SignedHeaders=${signedHeaders}, Signature=${sig}`;
  const resp = await fetch(`https://${host}/`, { method: 'POST', headers, body });
  let data: any = null;
  try { data = await resp.json(); } catch { data = {}; }
  return { ok: resp.ok, status: resp.status, data };
}

/** SECRET_HASH si l'App Client a un secret (sinon non requis). */
async function secretHash(username: string): Promise<string | null> {
  const c = cfg();
  if (!c.clientSecret) return null;
  const key = await subtle.importKey('raw', new TextEncoder().encode(c.clientSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await subtle.sign('HMAC', key, new TextEncoder().encode(username + c.clientId));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}

export interface CognitoUserMeta {
  role?: string; firstName?: string; lastName?: string; serviceType?: string; phone?: string; city?: string; country?: string;
}

/** Crée un utilisateur Cognito avec mot de passe PERMANENT (failover signup). */
export async function cognitoCreateUser(email: string, password: string, meta: CognitoUserMeta): Promise<{ ok: boolean; error?: string; exists?: boolean }> {
  if (!isCognitoConfigured()) return { ok: false, error: 'COGNITO_NOT_CONFIGURED' };
  const c = cfg();
  const attrs: Array<{ Name: string; Value: string }> = [
    { Name: 'email', Value: email },
    { Name: 'email_verified', Value: 'true' },
  ];
  if (meta.firstName) attrs.push({ Name: 'given_name', Value: meta.firstName });
  if (meta.lastName) attrs.push({ Name: 'family_name', Value: meta.lastName });
  // Attributs custom (le pool doit les déclarer ; ignorés silencieusement sinon via try secondaire).
  const customAttrs = [...attrs];
  if (meta.role) customAttrs.push({ Name: 'custom:role', Value: meta.role });
  if (meta.serviceType) customAttrs.push({ Name: 'custom:service_type', Value: meta.serviceType });

  let create = await cognitoRequest('AWSCognitoIdentityProviderService.AdminCreateUser', {
    UserPoolId: c.userPoolId, Username: email, MessageAction: 'SUPPRESS', UserAttributes: customAttrs,
  });
  // Si les attributs custom n'existent pas dans le pool → réessayer avec les attributs standard seulement.
  if (!create.ok && /attribute/i.test(JSON.stringify(create.data))) {
    create = await cognitoRequest('AWSCognitoIdentityProviderService.AdminCreateUser', {
      UserPoolId: c.userPoolId, Username: email, MessageAction: 'SUPPRESS', UserAttributes: attrs,
    });
  }
  if (!create.ok) {
    const t = create.data?.__type || '';
    if (/UsernameExistsException/i.test(t)) return { ok: false, exists: true, error: 'USER_EXISTS' };
    logger.error(`[cognitoFailover] AdminCreateUser échec: ${JSON.stringify(create.data)}`);
    return { ok: false, error: create.data?.message || 'COGNITO_CREATE_FAILED' };
  }
  const setPw = await cognitoRequest('AWSCognitoIdentityProviderService.AdminSetUserPassword', {
    UserPoolId: c.userPoolId, Username: email, Password: password, Permanent: true,
  });
  if (!setPw.ok) {
    logger.error(`[cognitoFailover] AdminSetUserPassword échec: ${JSON.stringify(setPw.data)}`);
    return { ok: false, error: 'COGNITO_SETPW_FAILED' };
  }
  logger.info(`[cognitoFailover] ✅ Compte Cognito créé (relais): ${email}`);
  return { ok: true };
}

/** Vérifie les identifiants via Cognito (failover login). Renvoie ok + attributs si valides. */
export async function cognitoVerifyCredentials(email: string, password: string): Promise<{ ok: boolean; meta?: CognitoUserMeta; error?: string }> {
  if (!isCognitoConfigured()) return { ok: false, error: 'COGNITO_NOT_CONFIGURED' };
  const c = cfg();
  const authParams: Record<string, string> = { USERNAME: email, PASSWORD: password };
  const sh = await secretHash(email);
  if (sh) authParams.SECRET_HASH = sh;
  const auth = await cognitoRequest('AWSCognitoIdentityProviderService.AdminInitiateAuth', {
    UserPoolId: c.userPoolId, ClientId: c.clientId, AuthFlow: 'ADMIN_USER_PASSWORD_AUTH', AuthParameters: authParams,
  });
  if (!auth.ok || !auth.data?.AuthenticationResult) {
    const t = auth.data?.__type || '';
    if (/NotAuthorized|UserNotFound/i.test(t)) return { ok: false, error: 'INVALID_CREDENTIALS' };
    return { ok: false, error: auth.data?.message || 'COGNITO_AUTH_FAILED' };
  }
  // Récupérer les attributs (rôle, service, nom) pour la réconciliation Supabase.
  const get = await cognitoRequest('AWSCognitoIdentityProviderService.AdminGetUser', { UserPoolId: c.userPoolId, Username: email });
  const list: Array<{ Name: string; Value: string }> = get.data?.UserAttributes || [];
  const get1 = (n: string) => list.find((a) => a.Name === n)?.Value;
  return {
    ok: true,
    meta: {
      role: get1('custom:role'), serviceType: get1('custom:service_type'),
      firstName: get1('given_name'), lastName: get1('family_name'),
    },
  };
}
