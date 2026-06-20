/**
 * 🔐 MIDDLEWARE COGNITO JWT VERIFICATION
 * Vérifie les tokens JWT émis par AWS Cognito
 * Compatible AWS Lambda + API Gateway
 */

import jwt from 'jsonwebtoken';
import jwksClient from 'jwks-rsa';
import { logger } from '../config/logger.js';

// Cache JWKS client par région/pool
const jwksClients = new Map();

function getJwksClient(region, userPoolId) {
  const key = `${region}:${userPoolId}`;
  if (!jwksClients.has(key)) {
    jwksClients.set(key, jwksClient({
      jwksUri: `https://cognito-idp.${region}.amazonaws.com/${userPoolId}/.well-known/jwks.json`,
      cache: true,
      cacheMaxEntries: 5,
      cacheMaxAge: 600000, // 10 min
    }));
  }
  return jwksClients.get(key);
}

/**
 * Récupère la clé publique de signature depuis JWKS
 */
function getSigningKey(client, kid) {
  return new Promise((resolve, reject) => {
    client.getSigningKey(kid, (err, key) => {
      if (err) {
        reject(err);
        return;
      }
      resolve(key.getPublicKey());
    });
  });
}

/**
 * Middleware: Vérifie le token Cognito JWT
 * Extrait les claims et ajoute req.cognitoUser
 */
export async function verifyCognitoToken(req, res, next) {
  try {
    const authHeader = req.headers.authorization;
    const token = authHeader && authHeader.split(' ')[1];

    if (!token) {
      return res.status(401).json({
        success: false,
        error: 'Token d\'accès Cognito requis',
      });
    }

    // Décoder le header pour récupérer le kid
    const decoded = jwt.decode(token, { complete: true });
    if (!decoded || !decoded.header.kid) {
      return res.status(401).json({
        success: false,
        error: 'Token JWT malformé',
      });
    }

    const region = process.env.AWS_COGNITO_REGION;
    const userPoolId = process.env.AWS_COGNITO_USER_POOL_ID;

    if (!region || !userPoolId) {
      logger.error('AWS_COGNITO_REGION ou AWS_COGNITO_USER_POOL_ID non configuré');
      return res.status(500).json({
        success: false,
        error: 'Configuration Cognito manquante côté serveur',
      });
    }

    // Récupérer la clé publique via JWKS
    const client = getJwksClient(region, userPoolId);
    const signingKey = await getSigningKey(client, decoded.header.kid);

    // Vérifier le token (signature + expiration + issuer)
    const payload = jwt.verify(token, signingKey, {
      issuer: `https://cognito-idp.${region}.amazonaws.com/${userPoolId}`,
      algorithms: ['RS256'],
    });

    // Vérifier le token_use (id ou access)
    if (payload.token_use !== 'id' && payload.token_use !== 'access') {
      return res.status(401).json({
        success: false,
        error: 'Type de token invalide',
      });
    }

    // Ajouter les infos utilisateur à la requête
    req.cognitoUser = {
      sub: payload.sub,
      email: payload.email,
      emailVerified: payload.email_verified,
      role: payload['custom:role'] || payload['cognito:groups']?.[0] || 'client',
      phone: payload.phone_number,
      fullName: payload.name || payload['custom:full_name'],
      tokenUse: payload.token_use,
      aud: payload.aud,
      iss: payload.iss,
    };

    logger.info(`✅ Cognito user authenticated: ${payload.sub} (${payload.email})`);
    next();
  } catch (error) {
    if (error.name === 'TokenExpiredError') {
      return res.status(401).json({
        success: false,
        error: 'Token expiré',
        code: 'TOKEN_EXPIRED',
      });
    }

    logger.error(`❌ Cognito auth error: ${error.message}`);
    return res.status(403).json({
      success: false,
      error: 'Token Cognito invalide',
    });
  }
}

/**
 * Middleware: Vérifie le rôle Cognito
 */
export function requireCognitoRole(...allowedRoles) {
  return (req, res, next) => {
    if (!req.cognitoUser) {
      return res.status(401).json({
        success: false,
        error: 'Authentification Cognito requise',
      });
    }

    if (!allowedRoles.includes(req.cognitoUser.role)) {
      logger.warn(`Access denied for Cognito user ${req.cognitoUser.sub} - Required: ${allowedRoles.join(', ')}`);
      return res.status(403).json({
        success: false,
        error: 'Permissions insuffisantes',
      });
    }

    next();
  };
}
