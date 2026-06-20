/**
 * 🔐 OAUTH SERVICE
 * Gestion sécurisée du flux OAuth2 Google côté serveur
 * Le Client Secret n'est JAMAIS exposé au frontend
 */

import { oauthConfig } from '../config/oauth.config.js';
import { logger } from '../config/logger.js';

const { google } = oauthConfig;

export interface GoogleTokenResponse {
  access_token: string;
  id_token: string;
  refresh_token?: string;
  expires_in: number;
  token_type: string;
  scope: string;
}

export interface GoogleUserInfo {
  sub: string;
  email: string;
  email_verified: boolean;
  name: string;
  given_name?: string;
  family_name?: string;
  picture?: string;
  locale?: string;
}

/**
 * Génère l'URL d'autorisation Google OAuth2
 */
export function buildGoogleAuthUrl(state?: string): string {
  const params = new URLSearchParams({
    client_id: google.clientId,
    redirect_uri: google.redirectUri,
    response_type: 'code',
    scope: google.scopes.join(' '),
    access_type: 'offline',
    prompt: 'consent',
    ...(state ? { state } : {}),
  });

  return `${google.authUrl}?${params.toString()}`;
}

/**
 * Échange le code d'autorisation contre des tokens
 * ⚠️ Utilise le CLIENT_SECRET — strictement backend
 */
export async function exchangeCodeForTokens(code: string): Promise<GoogleTokenResponse> {
  logger.info('OAuth: Exchanging authorization code for tokens');

  const response = await fetch(google.tokenUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      code,
      client_id: google.clientId,
      client_secret: google.clientSecret,
      redirect_uri: google.redirectUri,
      grant_type: 'authorization_code',
    }),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    logger.error(`OAuth token exchange failed: ${response.status} ${errorBody}`);
    throw new Error(`OAuth token exchange failed: ${response.status}`);
  }

  const tokens = (await response.json()) as GoogleTokenResponse;
  logger.info('OAuth: Tokens obtained successfully');
  return tokens;
}

/**
 * Récupère les informations utilisateur Google via l'access_token
 */
export async function getGoogleUserInfo(accessToken: string): Promise<GoogleUserInfo> {
  logger.info('OAuth: Fetching Google user info');

  const response = await fetch(google.userInfoUrl, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  if (!response.ok) {
    const errorBody = await response.text();
    logger.error(`OAuth userinfo failed: ${response.status} ${errorBody}`);
    throw new Error(`Failed to fetch Google user info: ${response.status}`);
  }

  const userInfo = (await response.json()) as GoogleUserInfo;
  logger.info(`OAuth: User info retrieved for ${userInfo.email}`);
  return userInfo;
}

/**
 * Rafraîchit un access_token via un refresh_token
 * ⚠️ Utilise le CLIENT_SECRET — strictement backend
 */
export async function refreshAccessToken(refreshToken: string): Promise<GoogleTokenResponse> {
  logger.info('OAuth: Refreshing access token');

  const response = await fetch(google.tokenUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      refresh_token: refreshToken,
      client_id: google.clientId,
      client_secret: google.clientSecret,
      grant_type: 'refresh_token',
    }),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    logger.error(`OAuth token refresh failed: ${response.status} ${errorBody}`);
    throw new Error(`OAuth token refresh failed: ${response.status}`);
  }

  const tokens = (await response.json()) as GoogleTokenResponse;
  logger.info('OAuth: Access token refreshed successfully');
  return tokens;
}
