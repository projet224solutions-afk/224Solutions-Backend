/**
 * INTEGRATION GUIDE - Add Edge Functions to Backend
 * 
 * This file contains the exact code you need to add to backend/src/server.ts
 * to integrate the migrated Edge Functions.
 */

// ============ STEP 1: Add this import (around line 50, after other imports)
/*
// @ts-ignore
import edgeFunctionsRoutes from './routes/edge-functions/index.js';
*/

// ============ STEP 2: Mount the route (around line 150, after other app.use() calls)
/*
// Edge Functions - Migrated from Supabase
app.use('/edge-functions', edgeFunctionsRoutes);
*/

// ============ STEP 3: Verify environment variables in .env
/*
# Stripe
STRIPE_SECRET_KEY=sk_live_...
STRIPE_WEBHOOK_SECRET=whsec_...

# PayPal
PAYPAL_CLIENT_ID=...
PAYPAL_CLIENT_SECRET=...

# JWT
JWT_SECRET=your-jwt-secret

# Password reset
PASSWORD_RESET_REDIRECT_URL=https://your-app.com/reset-password

# AWS Cognito (if using MFA)
AWS_COGNITO_REGION=us-east-1
AWS_COGNITO_USER_POOL_ID=...
AWS_COGNITO_CLIENT_ID=...
*/

export const EDGE_FUNCTIONS_INTEGRATION = {
  step1_import: `// @ts-ignore\nimport edgeFunctionsRoutes from './routes/edge-functions/index.js';`,
  step2_mount: `app.use('/edge-functions', edgeFunctionsRoutes);`,
  endpoints: {
    auth: [
      "POST   /edge-functions/auth/login",
      "POST   /edge-functions/auth/verify-otp",
      "POST   /edge-functions/auth/agent/login",
      "POST   /edge-functions/auth/bureau/login",
      "POST   /edge-functions/auth/reset-password",
      "PATCH  /edge-functions/auth/change-password",
      "POST   /edge-functions/auth/pdg/mfa",
    ],
    payments: [
      "POST   /edge-functions/payments/stripe/intent",
      "POST   /edge-functions/payments/stripe/webhook",
      "POST   /edge-functions/payments/stripe/deposit",
      "POST   /edge-functions/payments/paypal/webhook",
      "POST   /edge-functions/payments/escrow/create",
      "POST   /edge-functions/payments/escrow/release",
      "POST   /edge-functions/payments/wallet/transfer",
      "GET    /edge-functions/payments/wallet/balance",
    ],
  },
};
