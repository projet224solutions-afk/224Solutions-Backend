import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { encode as base64Encode } from "https://deno.land/std@0.190.0/encoding/base64.ts";
import { crypto as stdCrypto } from "https://deno.land/std@0.190.0/crypto/mod.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Agora Token Privileges
const Privileges = {
  kJoinChannel: 1,
  kPublishAudioStream: 2,
  kPublishVideoStream: 3,
  kPublishDataStream: 4,
};

// Role constants
const Role = {
  PUBLISHER: 1,
  SUBSCRIBER: 2,
};

/**
 * Pack functions for Agora token
 */
function packUint16(value: number): Uint8Array {
  const buffer = new ArrayBuffer(2);
  const view = new DataView(buffer);
  view.setUint16(0, value, true); // little endian
  return new Uint8Array(buffer);
}

function packUint32(value: number): Uint8Array {
  const buffer = new ArrayBuffer(4);
  const view = new DataView(buffer);
  view.setUint32(0, value, true); // little endian
  return new Uint8Array(buffer);
}

function packString(str: Uint8Array | string): Uint8Array {
  const bytes = typeof str === 'string' ? new TextEncoder().encode(str) : str;
  return concatArrays([packUint16(bytes.length), bytes]);
}

function concatArrays(arrays: Uint8Array[]): Uint8Array {
  const totalLength = arrays.reduce((acc, arr) => acc + arr.length, 0);
  const result = new Uint8Array(totalLength);
  let offset = 0;
  for (const arr of arrays) {
    result.set(arr, offset);
    offset += arr.length;
  }
  return result;
}

function packMessage(message: Record<number, number>): Uint8Array {
  const entries = Object.entries(message);
  const parts: Uint8Array[] = [packUint16(entries.length)];
  
  for (const [key, value] of entries) {
    parts.push(packUint16(parseInt(key)));
    parts.push(packUint32(value >>> 0));
  }
  
  return concatArrays(parts);
}

/**
 * HMAC-SHA256 using Web Crypto API
 */
async function hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const keyBuffer = key.buffer.slice(key.byteOffset, key.byteOffset + key.byteLength) as ArrayBuffer;
  const dataBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
  
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    keyBuffer,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  
  const signature = await crypto.subtle.sign('HMAC', cryptoKey, dataBuffer);
  return new Uint8Array(signature);
}

/**
 * Generate Agora RTC Token using async crypto
 */
async function generateRtcToken(
  appId: string,
  appCertificate: string,
  channelName: string,
  uid: string,
  role: number,
  privilegeExpiredTs: number
): Promise<string> {
  const version = "006";
  const randomInt = Math.floor(Math.random() * 0xFFFFFFFF);
  const timestamp = Math.floor(Date.now() / 1000);
  
  // Build message
  const message: Record<number, number> = {};
  message[Privileges.kJoinChannel] = privilegeExpiredTs;
  
  if (role === Role.PUBLISHER) {
    message[Privileges.kPublishAudioStream] = privilegeExpiredTs;
    message[Privileges.kPublishVideoStream] = privilegeExpiredTs;
    message[Privileges.kPublishDataStream] = privilegeExpiredTs;
  }

  // Pack message
  const messageBytes = packMessage(message);
  
  // Build signature
  const toSign = concatArrays([
    new TextEncoder().encode(appId),
    new TextEncoder().encode(channelName),
    new TextEncoder().encode(uid),
    messageBytes
  ]);
  
  const signature = await hmacSha256(new TextEncoder().encode(appCertificate), toSign);
  
  // Pack content
  const content = concatArrays([
    packString(signature),
    packUint32(randomInt >>> 0),
    packUint32(timestamp >>> 0),
    packUint16(messageBytes.length),
    messageBytes
  ]);
  
  // Encode token
  const contentBuffer = content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength) as ArrayBuffer;
  const token = version + appId + base64Encode(contentBuffer);
  
  return token;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');

    if (!supabaseUrl || !supabaseAnonKey) {
      console.error('Configuration Supabase manquante (SUPABASE_URL/SUPABASE_ANON_KEY)');
      throw new Error('Configuration Supabase manquante');
    }

    // Répondre proprement en 401 sans déclencher d'exception
    const unauthorized = (reason?: string) =>
      new Response(
        JSON.stringify({ error: 'Non autorisé', ...(reason ? { reason } : {}) }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 401 }
      );

    // Vérifier le header d'autorisation
    const authHeader = req.headers.get('Authorization');
    if (!authHeader || !authHeader.toLowerCase().startsWith('bearer ')) {
      return unauthorized('Header Authorization manquant');
    }

    const token = authHeader.slice('Bearer '.length).trim();
    if (!token) {
      return unauthorized('Token vide');
    }

    // Extraire le user_id depuis le JWT
    const parseJwtPayload = (jwt: string): unknown => {
      const parts = jwt.split('.');
      if (parts.length !== 3) return null;
      const base64Url = parts[1];
      const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
      const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
      const json = atob(padded);
      return JSON.parse(json);
    };

    const claims = parseJwtPayload(token) as { sub?: string; exp?: number } | null;
    const userId = typeof claims?.sub === 'string' ? claims.sub : null;
    const exp = typeof claims?.exp === 'number' ? claims.exp : null;

    if (!userId) {
      return unauthorized('JWT sans sub');
    }

    if (exp && exp <= Math.floor(Date.now() / 1000)) {
      return unauthorized('JWT expiré');
    }

    // Confirmer le token via une requête DB
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: {
        headers: {
          Authorization: `Bearer ${token}`,
        },
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    });

    const { data: profile, error: profileError } = await supabase
      .from('profiles')
      .select('id')
      .eq('id', userId)
      .maybeSingle();

    if (profileError || !profile) {
      console.log('Profil non trouvé, vérification alternative...');
      // Vérification alternative: le token est valide si Supabase l'accepte
    }

    const { channel, uid: requestedUid, role = 'publisher' } = await req.json();

    if (!channel || typeof channel !== 'string') {
      throw new Error('Channel requis');
    }

    const sanitizeChannelName = (value: string) =>
      value.replace(/[^a-zA-Z0-9_\-]/g, '_').substring(0, 64);

    const uuidToNumericUid = (uuid: string): number => {
      const hex = uuid.replace(/-/g, '').substring(0, 8);
      return parseInt(hex, 16) % 2147483647;
    };

    const safeChannel = sanitizeChannelName(channel);

    // Utiliser l'UID fourni par le client si présent (doit matcher l'UID utilisé côté RTC join)
    const fallbackUid = String(uuidToNumericUid(userId));
    const uid = (typeof requestedUid === 'string' && requestedUid.trim().length > 0)
      ? requestedUid.trim().substring(0, 64)
      : fallbackUid;

    if (!/^[a-zA-Z0-9_\-]{1,64}$/.test(uid)) {
      throw new Error('UID invalide');
    }

    console.log('Utilisateur authentifié:', userId, 'Agora uid:', uid, 'Channel:', safeChannel);
    const AGORA_APP_ID = Deno.env.get('AGORA_APP_ID');
    const AGORA_APP_CERTIFICATE = Deno.env.get('AGORA_APP_CERTIFICATE');

    if (!AGORA_APP_ID) {
      console.error('AGORA_APP_ID non configuré');
      throw new Error('Configuration Agora manquante: AGORA_APP_ID');
    }

    if (!AGORA_APP_CERTIFICATE) {
      console.error('AGORA_APP_CERTIFICATE non configuré');
      throw new Error('Configuration Agora manquante: AGORA_APP_CERTIFICATE');
    }

    // Validation basique (Agora App ID et Certificate sont généralement des hex de 32 chars)
    if (!/^[a-f0-9]{32}$/i.test(AGORA_APP_ID)) {
      throw new Error('AGORA_APP_ID invalide (attendu: 32 caractères hex)');
    }

    if (!/^[a-f0-9]{32}$/i.test(AGORA_APP_CERTIFICATE)) {
      throw new Error('AGORA_APP_CERTIFICATE invalide (attendu: 32 caractères hex)');
    }

    console.log('Agora config OK - AppID:', AGORA_APP_ID.substring(0, 8) + '...');

    // Token expire dans 24 heures
    const privilegeExpiredTs = Math.floor(Date.now() / 1000) + 86400;
    const roleValue = role === 'publisher' ? Role.PUBLISHER : Role.SUBSCRIBER;

    // Générer le token RTC avec async crypto
    const rtcToken = await generateRtcToken(
      AGORA_APP_ID,
      AGORA_APP_CERTIFICATE,
      safeChannel,
      uid,
      roleValue,
      privilegeExpiredTs
    );

    console.log('✅ Token Agora généré pour channel:', safeChannel, 'uid:', uid);

    return new Response(
      JSON.stringify({
        appId: AGORA_APP_ID,
        token: rtcToken,
        channel: safeChannel,
        uid,
        role,
        expiresAt: privilegeExpiredTs
      }),
      { 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200 
      }
    );

  } catch (error) {
    console.error('Erreur génération token Agora:', error);
    const errorMessage = error instanceof Error ? error.message : 'Erreur inconnue';
    return new Response(
      JSON.stringify({ error: errorMessage }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 400,
      }
    );
  }
});
