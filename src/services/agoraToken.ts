/**
 * 🎫 agoraToken — génération NATIVE (Node) du token RTC Agora, format « 006 » CONFORME.
 *
 * Pourquoi côté backend : le certificat Agora est un SECRET dont la source de vérité doit vivre
 * en `process.env` du backend (convention 224 : aucun secret en base ni en Edge non maîtrisée).
 *
 * ⚠️ IMPORTANT — algorithme validé par un VRAI join Agora (Playwright + agora-rtc-sdk-ng) :
 * l'ancienne implémentation de l'edge `agora-token` était MALFORMÉE (message signé sans
 * salt+timestamp, content sans crc32 channel/uid) → Agora rejetait le token quel que soit le
 * certificat (`invalid token, authorized failed`). Ici on respecte le format officiel
 * (cf. agora-access-token AccessToken build « 006 ») : salt+ts DANS le message signé, puis
 * `signature | crc32(channel) | crc32(uid) | message` dans le content. Ne pas « simplifier ».
 */

import crypto from 'crypto';

// Privilèges Agora (mêmes constantes que le SDK).
const Privileges = {
  kJoinChannel: 1,
  kPublishAudioStream: 2,
  kPublishVideoStream: 3,
  kPublishDataStream: 4,
} as const;

export const AgoraRole = { PUBLISHER: 1, SUBSCRIBER: 2 } as const;
export type AgoraRoleValue = (typeof AgoraRole)[keyof typeof AgoraRole];

/** CRC32 standard (polynôme 0xEDB88320) — requis par le format de token Agora. */
function crc32(buf: Buffer): number {
  let crc = ~0;
  for (let i = 0; i < buf.length; i++) {
    crc ^= buf[i];
    for (let j = 0; j < 8; j++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (~crc) >>> 0;
}

/** Tampon binaire little-endian, à l'identique d'agora-access-token (ByteBuf). */
class ByteBuf {
  private buf = Buffer.alloc(2048);
  private pos = 0;
  putUint16(v: number): this {
    this.buf.writeUInt16LE((v >>> 0) & 0xffff, this.pos);
    this.pos += 2;
    return this;
  }
  putUint32(v: number): this {
    this.buf.writeUInt32LE(v >>> 0, this.pos);
    this.pos += 4;
    return this;
  }
  putBytes(b: Buffer): this {
    this.putUint16(b.length);
    b.copy(this.buf, this.pos);
    this.pos += b.length;
    return this;
  }
  putString(s: Buffer | string): this {
    return this.putBytes(Buffer.isBuffer(s) ? s : Buffer.from(s));
  }
  putTreeMapUint32(map: Record<number, number>): this {
    const keys = Object.keys(map).map(Number).sort((a, b) => a - b);
    this.putUint16(keys.length);
    for (const k of keys) {
      this.putUint16(k);
      this.putUint32(map[k]);
    }
    return this;
  }
  pack(): Buffer {
    return this.buf.subarray(0, this.pos);
  }
}

/** Sanitation du nom de canal — IDENTIQUE à l'edge (remplacement, pas suppression). */
export function sanitizeAgoraChannel(value: string): string {
  return value.replace(/[^a-zA-Z0-9_\-]/g, '_').substring(0, 64);
}

/** UID numérique de repli dérivé d'un UUID — IDENTIQUE à l'edge. */
export function uuidToNumericUid(uuid: string): number {
  const hex = uuid.replace(/-/g, '').substring(0, 8);
  return parseInt(hex, 16) % 2147483647;
}

/**
 * Génère un token RTC « 006 » conforme, signé avec `appCertificate`.
 *
 * @param uid  UID côté RTC. « 0 » (ou 0) = uid « any » → chaîne vide dans le token (le client
 *             DOIT alors joindre avec uid 0/null). Sinon la chaîne décimale exacte.
 * @param privilegeExpiredTs timestamp UNIX (secondes) d'expiration des privilèges.
 */
export function generateAgoraRtcToken(
  appId: string,
  appCertificate: string,
  channelName: string,
  uid: string,
  role: AgoraRoleValue,
  privilegeExpiredTs: number,
): string {
  const uidStr = uid === '0' || uid === '' ? '' : String(uid);
  const ts = Math.floor(Date.now() / 1000) + 24 * 3600; // ts propre du token (24 h)
  const salt = Math.floor(Math.random() * 0xffffffff);

  const privileges: Record<number, number> = { [Privileges.kJoinChannel]: privilegeExpiredTs };
  if (role === AgoraRole.PUBLISHER) {
    privileges[Privileges.kPublishAudioStream] = privilegeExpiredTs;
    privileges[Privileges.kPublishVideoStream] = privilegeExpiredTs;
    privileges[Privileges.kPublishDataStream] = privilegeExpiredTs;
  }

  // Message signé = salt | ts | privilèges  (le salt et le ts DOIVENT être signés).
  const message = new ByteBuf().putUint32(salt).putUint32(ts).putTreeMapUint32(privileges).pack();

  const toSign = Buffer.concat([
    Buffer.from(appId),
    Buffer.from(channelName),
    Buffer.from(uidStr),
    message,
  ]);
  const signature = crypto.createHmac('sha256', Buffer.from(appCertificate)).update(toSign).digest();

  // Content = signature | crc32(channel) | crc32(uid) | message.
  const content = new ByteBuf()
    .putString(signature)
    .putUint32(crc32(Buffer.from(channelName)))
    .putUint32(crc32(Buffer.from(uidStr)))
    .putString(message)
    .pack();

  return '006' + appId + content.toString('base64');
}
