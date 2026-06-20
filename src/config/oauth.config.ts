/**
 * 🔐 OAUTH CONFIGURATION
 * Configuration centralisée pour Google OAuth2
 * ⚠️ Ce fichier est BACKEND-ONLY — jamais importé côté frontend
 */

import { env } from './env.js';

export const oauthConfig = {
  enabled: env.oauthConfigured,
  google: {
    clientId: env.OAUTH_CLIENT_ID,
    clientSecret: env.OAUTH_CLIENT_SECRET,
    redirectUri: env.OAUTH_REDIRECT_URI,
    authUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
    tokenUrl: 'https://oauth2.googleapis.com/token',
    userInfoUrl: 'https://www.googleapis.com/oauth2/v3/userinfo',
    scopes: ['openid', 'email', 'profile'],
  },
} as const;
