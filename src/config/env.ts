/**
 * 🔧 ENVIRONMENT CONFIGURATION
 * Validation et typage des variables d'environnement
 * Aucun fallback sur les secrets critiques
 */

// dotenv.config() appelé dans server.ts
// NB : ne JAMAIS logguer la valeur d'un secret (ni même l'URL Supabase en clair).
// La validation/synthèse au démarrage se fait via assertSecretsOnBoot() (plus bas),
// appelée dans server.ts — sortie redacted uniquement.

function requireEnv(key: string): string {
  const value = process.env[key];
  if (!value) {
    throw new Error(`❌ CRITICAL: Missing required environment variable: ${key}`);
  }
  return value;
}

function optionalEnv(key: string, defaultValue: string): string {
  return process.env[key] || defaultValue;
}

function optionalEnvInt(key: string, defaultValue: number): number {
  const val = process.env[key];
  return val ? parseInt(val, 10) : defaultValue;
}

const defaultUploadPath = process.env.VERCEL ? '/tmp/uploads' : './uploads';

export const env = {
  // Server
  NODE_ENV: optionalEnv('NODE_ENV', 'development'),
  PORT: optionalEnvInt('PORT', 3001),

  // Supabase (required)
  SUPABASE_URL: requireEnv('SUPABASE_URL'),
  SUPABASE_SERVICE_ROLE_KEY: requireEnv('SUPABASE_SERVICE_ROLE_KEY'),
  SUPABASE_ANON_KEY: optionalEnv('SUPABASE_ANON_KEY', ''),

  // Security
  INTERNAL_API_KEY: optionalEnv('INTERNAL_API_KEY', ''),
  JWT_SECRET: optionalEnv('JWT_SECRET', ''),

  // 2FA admin (step-up TOTP serveur sur les ops financières sensibles)
  // ADMIN_MFA_ENFORCED='false' par défaut : transition non-bloquante — un admin SANS
  // 2FA enrôlé garde l'accès (un avertissement est loggé), le temps que tous enrôlent.
  // Passer à 'true' une fois les admins enrôlés → l'accès aux ops sensibles EXIGE la 2FA.
  // ⚠️ PRODUCTION : avant d'activer, vérifier que TOUS les admins ont enrôlé leur TOTP :
  //   SELECT id, email, is_mfa_enrolled FROM profiles WHERE role IN ('admin','pdg','ceo');
  ADMIN_MFA_ENFORCED: optionalEnv('ADMIN_MFA_ENFORCED', 'false') === 'true',
  // Clé de chiffrement du secret TOTP au repos (repli sur d'autres secrets serveur déjà
  // présents — jamais en clair, jamais côté client). Dérivée en clé 32 octets (scrypt).
  MFA_ENCRYPTION_KEY: optionalEnv(
    'MFA_ENCRYPTION_KEY',
    process.env.CCP_ENCRYPTION_KEY || process.env.TRANSACTION_SECRET_KEY || process.env.JWT_SECRET || ''
  ),

  // Secrets d'intégration (paiements / cloud) — centralisés ici, jamais en dur.
  // Optionnels au boot (warn), mais requis fonctionnellement quand le service est utilisé.
  STRIPE_SECRET_KEY: optionalEnv('STRIPE_SECRET_KEY', ''),
  STRIPE_WEBHOOK_SECRET: optionalEnv('STRIPE_WEBHOOK_SECRET', ''),
  PAYPAL_CLIENT_SECRET: optionalEnv('PAYPAL_CLIENT_SECRET', ''),
  TRANSACTION_SECRET_KEY: optionalEnv('TRANSACTION_SECRET_KEY', ''),
  CCP_ENCRYPTION_KEY: optionalEnv('CCP_ENCRYPTION_KEY', ''),
  RESEND_API_KEY: optionalEnv('RESEND_API_KEY', ''),
  TWILIO_ACCOUNT_SID: optionalEnv('TWILIO_ACCOUNT_SID', ''),
  TWILIO_AUTH_TOKEN: optionalEnv('TWILIO_AUTH_TOKEN', ''),
  TWILIO_PHONE_NUMBER: optionalEnv('TWILIO_PHONE_NUMBER', ''),
  TWILIO_MESSAGING_SERVICE_SID: optionalEnv('TWILIO_MESSAGING_SERVICE_SID', ''),

  // Orange SMS : UN SEUL couple d'identifiants pour TOUTE l'application (tous pays).
  // La config PAR PAYS (sender address/name, activation) vit dans ORANGE_SMS_{ISO}_*,
  // lue dynamiquement par le provider (services/sms/orangeSms.ts) — PAS ici.
  ORANGE_CLIENT_ID: optionalEnv('ORANGE_CLIENT_ID', ''),
  ORANGE_CLIENT_SECRET: optionalEnv('ORANGE_CLIENT_SECRET', ''),
  // Alternative : l'« en-tête d'autorisation » prêt à l'emploi affiché par MyApps
  // (« Basic <base64(client_id:client_secret)> »). Si renseigné, il PRIME sur le
  // couple ID/Secret — on peut coller la valeur d'Orange telle quelle.
  ORANGE_AUTHORIZATION: optionalEnv('ORANGE_AUTHORIZATION', ''),
  ORANGE_SMS_ENABLED: optionalEnv('ORANGE_SMS_ENABLED', 'false') === 'true',
  ORANGE_SMS_LOW_BALANCE_THRESHOLD: optionalEnvInt('ORANGE_SMS_LOW_BALANCE_THRESHOLD', 100),

  // Live shopping : fournisseur du transport vidéo (agora en Vague 1, livekit en Vague 2).
  // Doit rester aligné avec VITE_LIVE_PROVIDER côté frontend.
  LIVE_PROVIDER: optionalEnv('LIVE_PROVIDER', 'agora'),

  // Agora (appels + live) : App ID + Certificate signent les tokens RTC. Source de vérité =
  // backend (jamais côté client). Quand présents, le backend génère le token NATIVEMENT
  // (services/agoraToken.ts) au lieu de proxifier l'edge Supabase — le certificat vit ici,
  // aligné sur la console Agora. Optionnels au boot ; si absents, repli sur l'edge (transition).
  AGORA_APP_ID: optionalEnv('AGORA_APP_ID', ''),
  AGORA_APP_CERTIFICATE: optionalEnv('AGORA_APP_CERTIFICATE', ''),

  // Agora Cloud Recording (replay serveur GARANTI) — REST acquire/start/stop en Basic auth avec
  // les clés RESTful de la console Agora (DISTINCTES de l'App Certificate). Le fichier est écrit
  // DIRECTEMENT dans notre bucket GCS via l'API S3-compatible → il faut une clé HMAC GCS (≠ service
  // account RSA). TOUS optionnels : absents → l'enregistrement serveur est désactivé (best-effort,
  // le repli client prend le relais). JAMAIS en base — process.env uniquement.
  AGORA_CUSTOMER_ID: optionalEnv('AGORA_CUSTOMER_ID', ''),
  AGORA_CUSTOMER_SECRET: optionalEnv('AGORA_CUSTOMER_SECRET', ''),
  GCS_HMAC_ACCESS_KEY: optionalEnv('GCS_HMAC_ACCESS_KEY', ''),
  GCS_HMAC_SECRET: optionalEnv('GCS_HMAC_SECRET', ''),

  // OAuth (Google)
  OAUTH_CLIENT_ID: optionalEnv('OAUTH_CLIENT_ID', ''),
  OAUTH_CLIENT_SECRET: optionalEnv('OAUTH_CLIENT_SECRET', ''),
  OAUTH_REDIRECT_URI: optionalEnv('OAUTH_REDIRECT_URI', ''),

  // CORS
  CORS_ORIGINS: optionalEnv(
    'CORS_ORIGINS',
    'http://localhost,http://localhost:3000,http://localhost:5173,http://localhost:8080,http://127.0.0.1:3000,http://127.0.0.1:5173,http://127.0.0.1:8080,http://[::1]:3000,http://[::1]:5173,http://[::1]:8080,https://localhost:5173,capacitor://localhost,ionic://localhost,https://224solution.net,https://www.224solution.net,https://*.224solution.net'
  ),

  // CSP
  CSP_CONNECT_SRC: optionalEnv('CSP_CONNECT_SRC', ''),

  // Rate limiting
  RATE_LIMIT_WINDOW_MS: optionalEnvInt('RATE_LIMIT_WINDOW_MS', 60000),
  // 300 req/min = 5 req/s par IP : suffisant pour une app mobile active (une session
  // ouverte génère ~10-30 req/min en usage normal). Les routes sensibles (login, OTP,
  // paiement) ont en plus des limites dédiées via routeRateLimiter — cette limite est
  // le filet de sécurité global anti brute-force. Augmenter via .env si trafic légitime bloqué.
  RATE_LIMIT_MAX_REQUESTS: optionalEnvInt('RATE_LIMIT_MAX_REQUESTS', 300),

  // Uploads
  MAX_FILE_SIZE: optionalEnvInt('MAX_FILE_SIZE', 10 * 1024 * 1024),
  UPLOAD_PATH: optionalEnv('UPLOAD_PATH', defaultUploadPath),

  // Logging
  LOG_LEVEL: optionalEnv('LOG_LEVEL', 'info'),
  LOG_FILE: optionalEnv('LOG_FILE', './logs/backend.log'),

  // Cron
  ENABLE_CRON_JOBS: optionalEnv('ENABLE_CRON_JOBS', 'true') === 'true',

  // Feature flags
  ENABLE_MONITORING: optionalEnv('ENABLE_MONITORING', 'true') === 'true',

  // Scaling horizontal (ECS Fargate) : les tâches de fond (file de jobs + surveillance 24/7)
  // ne doivent tourner que sur UN worker, pas dans chaque conteneur web (sinon doublons).
  // Défaut 'true' = comportement actuel inchangé. Mettre 'false' sur le service WEB,
  // 'true' sur le service WORKER unique. (Un verrou Redis sert en plus de garde-fou.)
  RUN_BACKGROUND_JOBS: optionalEnv('RUN_BACKGROUND_JOBS', 'true') === 'true',

  get isProduction(): boolean {
    return this.NODE_ENV === 'production';
  },

  get isDevelopment(): boolean {
    return this.NODE_ENV === 'development';
  },

  get corsOrigins(): string[] {
    const defaults = [
      'http://localhost',
      'http://localhost:3000',
      'http://localhost:5173',
      'http://localhost:8080',
      'http://127.0.0.1:3000',
      'http://127.0.0.1:5173',
      'http://127.0.0.1:8080',
      'http://[::1]:3000',
      'http://[::1]:5173',
      'http://[::1]:8080',
      'https://localhost:5173',
      'capacitor://localhost',
      'ionic://localhost',
      'https://224solution.net',
      'https://www.224solution.net',
      'https://*.224solution.net',
    ];

    return [...new Set([
      ...defaults,
      ...this.CORS_ORIGINS.split(',').map(s => s.trim()).filter(Boolean),
    ])];
  },

  get oauthConfigured(): boolean {
    return Boolean(this.OAUTH_CLIENT_ID && this.OAUTH_CLIENT_SECRET && this.OAUTH_REDIRECT_URI);
  }
} as const;

// ─────────────────────────────────────────────────────────────────────
// SEAM VAULT : point d'indirection unique pour récupérer un secret.
// Aujourd'hui : variables d'environnement. Demain : brancher ici un vrai
// coffre (Supabase Vault / AWS Secrets Manager / HashiCorp Vault) sans
// toucher au reste du code — il suffira de remplacer l'implémentation.
// ─────────────────────────────────────────────────────────────────────
export function getSecret(key: string, opts: { required?: boolean } = {}): string {
  const value = process.env[key] || '';
  if (!value && opts.required) {
    throw new Error(`❌ CRITICAL: secret manquant: ${key}`);
  }
  return value;
}

// ─────────────────────────────────────────────────────────────────────
// VALIDATION AU DÉMARRAGE (appelée dans server.ts)
//  - fail-fast en PRODUCTION sur les anomalies dangereuses (secret faible) ;
//  - avertissements clairs (redacted) pour les secrets manquants/recommandés.
//  - N'imprime JAMAIS la valeur d'un secret.
// ─────────────────────────────────────────────────────────────────────
export function assertSecretsOnBoot(): void {
  const isProd = env.isProduction;
  const errors: string[] = [];
  const warnings: string[] = [];

  // JWT_SECRET : sert de repli de vérification quand Supabase Auth est indisponible.
  // Un secret FAIBLE est PIRE qu'absent (tokens forgeables en HS256) → bloquant en prod.
  const jwtSecret = process.env.JWT_SECRET || '';
  if (jwtSecret) {
    if (jwtSecret.length < 32) {
      (isProd ? errors : warnings).push(
        'JWT_SECRET trop court (<32 caractères) — un token forgé peut usurper n\'importe quel utilisateur'
      );
    }
  } else if (isProd) {
    warnings.push(
      'JWT_SECRET absent en production — si Supabase Auth est indisponible, le fallback JWT est désactivé. ' +
      'Définir JWT_SECRET (≥32 chars) pour sécuriser la continuité de service.'
    );
  } else {
    warnings.push('JWT_SECRET absent — repli d\'auth local désactivé (OK si Supabase Auth seul)');
  }

  // MFA_ENCRYPTION_KEY : si vide, les secrets TOTP sont chiffrés avec '' → trivial à déchiffrer
  const mfaKey = process.env.MFA_ENCRYPTION_KEY
    || process.env.CCP_ENCRYPTION_KEY
    || process.env.TRANSACTION_SECRET_KEY
    || process.env.JWT_SECRET
    || '';
  if (!mfaKey && isProd) {
    errors.push(
      'MFA_ENCRYPTION_KEY manquante (et aucun secret de fallback configuré) — ' +
      'les secrets TOTP admin seraient stockés sans chiffrement. Définir MFA_ENCRYPTION_KEY en production.'
    );
  }

  // Clé d'API interne (routes machine-à-machine)
  if (process.env.INTERNAL_API_KEY) {
    if (process.env.INTERNAL_API_KEY.length < 16) {
      (isProd ? errors : warnings).push('INTERNAL_API_KEY trop courte (<16 caractères)');
    }
  } else {
    warnings.push('INTERNAL_API_KEY absente — routes internes inutilisables');
  }

  // Secrets de paiement recommandés (warn — requis seulement si le service est actif)
  for (const k of ['STRIPE_SECRET_KEY', 'STRIPE_WEBHOOK_SECRET']) {
    if (!process.env[k]) warnings.push(`${k} absent — paiements ${k.includes('WEBHOOK') ? 'webhook ' : ''}Stripe indisponibles`);
  }

  // Orange SMS : activé sans identifiants (ni couple ID/Secret, ni en-tête Basic) →
  // le provider basculera systématiquement sur Twilio. Aucune valeur affichée.
  if (env.ORANGE_SMS_ENABLED
      && !(process.env.ORANGE_CLIENT_ID && process.env.ORANGE_CLIENT_SECRET)
      && !process.env.ORANGE_AUTHORIZATION) {
    warnings.push('ORANGE_SMS_ENABLED=true mais aucun identifiant (ORANGE_CLIENT_ID/SECRET ou ORANGE_AUTHORIZATION) — Orange sera ignoré (bascule Twilio)');
  }

  for (const w of warnings) console.warn(`[secrets] ⚠️  ${w}`);

  if (errors.length) {
    for (const e of errors) console.error(`[secrets] ❌ ${e}`);
    throw new Error(`Secrets invalides en production (${errors.length}). Démarrage interrompu.`);
  }

  // Synthèse redacted (aucune valeur affichée)
  console.log(`[secrets] ✅ Validation OK (env=${env.NODE_ENV}, warnings=${warnings.length})`);
}
