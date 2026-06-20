/**
 * 🚀 AWS LAMBDA - AUTH GATEWAY
 * Fonction Lambda pour API Gateway
 * Point d'entrée centralisé pour l'authentification Cognito
 *
 * Déploiement: AWS Lambda + API Gateway (HTTP API)
 * Runtime: Node.js 20.x
 */

import jwt from 'jsonwebtoken';
import jwksClient from 'jwks-rsa';

// Configuration
const REGION = process.env.AWS_COGNITO_REGION;
const USER_POOL_ID = process.env.AWS_COGNITO_USER_POOL_ID;
const JWKS_URI = `https://cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}/.well-known/jwks.json`;

// Cache JWKS
const client = jwksClient({
  jwksUri: JWKS_URI,
  cache: true,
  cacheMaxEntries: 5,
  cacheMaxAge: 600000,
});

function getSigningKey(kid) {
  return new Promise((resolve, reject) => {
    client.getSigningKey(kid, (err, key) => {
      if (err) reject(err);
      else resolve(key.getPublicKey());
    });
  });
}

/**
 * Handler principal Lambda
 */
export const handler = async (event) => {
  const { routeKey, body, headers } = event;
  const parsedBody = body ? JSON.parse(body) : {};

  try {
    switch (routeKey) {
      case 'POST /auth/validate-token':
        return await validateToken(headers);

      case 'POST /auth/sync-profile':
        return await syncProfile(headers, parsedBody);

      case 'GET /auth/me':
        return await getProfile(headers);

      default:
        return response(404, { error: 'Route not found' });
    }
  } catch (error) {
    console.error('Lambda error:', error);
    return response(500, { error: 'Internal server error' });
  }
};

/**
 * Valider un token Cognito
 */
async function validateToken(headers) {
  const token = extractToken(headers);
  if (!token) return response(401, { error: 'Token requis' });

  try {
    const user = await verifyCognitoJWT(token);
    return response(200, { valid: true, user });
  } catch (error) {
    return response(401, { valid: false, error: error.message });
  }
}

/**
 * Synchroniser le profil après login
 */
async function syncProfile(headers, body) {
  const token = extractToken(headers);
  if (!token) return response(401, { error: 'Token requis' });

  try {
    const user = await verifyCognitoJWT(token);

    // TODO: Connecter à Cloud SQL via pg
    // const dbUser = await syncToCloudSQL(user, body.additionalData);

    return response(200, {
      success: true,
      message: 'Profil synchronisé',
      user: {
        cognitoUserId: user.sub,
        email: user.email,
        role: user.role,
      },
    });
  } catch (error) {
    return response(403, { error: 'Token invalide' });
  }
}

/**
 * Récupérer le profil
 */
async function getProfile(headers) {
  const token = extractToken(headers);
  if (!token) return response(401, { error: 'Token requis' });

  try {
    const user = await verifyCognitoJWT(token);

    // TODO: Récupérer depuis Cloud SQL
    return response(200, {
      success: true,
      user: {
        cognitoUserId: user.sub,
        email: user.email,
        role: user.role,
      },
    });
  } catch (error) {
    return response(403, { error: 'Token invalide' });
  }
}

/**
 * Vérifier le JWT Cognito
 */
async function verifyCognitoJWT(token) {
  const decoded = jwt.decode(token, { complete: true });
  if (!decoded) throw new Error('Token malformé');

  const signingKey = await getSigningKey(decoded.header.kid);
  const payload = jwt.verify(token, signingKey, {
    issuer: `https://cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}`,
    algorithms: ['RS256'],
  });

  return {
    sub: payload.sub,
    email: payload.email,
    emailVerified: payload.email_verified,
    role: payload['custom:role'] || 'client',
    phone: payload.phone_number,
    fullName: payload.name,
  };
}

/**
 * Extraire le Bearer token
 */
function extractToken(headers) {
  const auth = headers?.authorization || headers?.Authorization;
  return auth?.replace('Bearer ', '') || null;
}

/**
 * Helper réponse Lambda
 */
function response(statusCode, body) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'authorization, content-type',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    },
    body: JSON.stringify(body),
  };
}
