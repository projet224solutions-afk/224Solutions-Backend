/**
 * 🔐 AUTH BUREAU SYNDICAT — JWT signé serveur
 * ---------------------------------------------------------------------------
 * AVANT : la « session » bureau était un simple objet JSON renvoyé au client
 * (non signé, non stocké) → forgeable, et les RPC bureau étaient ouvertes à `anon`
 * avec un bureau_id fourni par le client → lecture/écriture inter-bureaux.
 *
 * ICI : après vérification de l'OTP, le BACKEND signe un JWT (secret serveur) portant
 * le bureau_id. Toute opération bureau passe par un middleware qui valide ce JWT et
 * SCOPE l'opération au bureau du token (jamais un bureau_id venu du client).
 */

import jwt from 'jsonwebtoken';
import { env } from '../config/env.js';

const ISSUER = '224solutions-bureau';
const TTL_SECONDS = 24 * 60 * 60; // 24 h

export interface BureauTokenPayload {
  sub: string;          // bureau_id (syndicate_bureaus.id)
  bureau_id: string;
  bureau_code?: string;
  role: 'bureau_president';
  type: 'bureau';
}

function secret(): string {
  // Réutilise le secret serveur (jamais exposé au client). Requis pour signer/valider.
  const s = env.JWT_SECRET;
  if (!s || s.length < 32) {
    throw new Error('JWT_SECRET absent/trop court — impossible de signer un token bureau sûr');
  }
  return s;
}

export function signBureauToken(input: { bureauId: string; bureauCode?: string }): { token: string; expiresIn: number } {
  const payload: BureauTokenPayload = {
    sub: input.bureauId,
    bureau_id: input.bureauId,
    bureau_code: input.bureauCode,
    role: 'bureau_president',
    type: 'bureau',
  };
  const token = jwt.sign(payload, secret(), { expiresIn: TTL_SECONDS, issuer: ISSUER });
  return { token, expiresIn: TTL_SECONDS };
}

export function verifyBureauToken(token: string): BureauTokenPayload | null {
  try {
    const decoded = jwt.verify(token, secret(), { issuer: ISSUER }) as BureauTokenPayload;
    if (decoded?.type !== 'bureau' || !decoded.bureau_id) return null;
    return decoded;
  } catch {
    return null;
  }
}
