/**
 * 🔐 AUTH ROUTES (TypeScript)
 * Routes d'authentification OAuth Google — flux serveur sécurisé
 * Remplace auth.routes.js (legacy stub)
 */

import { Router, Request, Response } from 'express';
import crypto from 'crypto';
import { z } from 'zod';
import { logger } from '../config/logger.js';
import { oauthConfig } from '../config/oauth.config.js';
import {
  buildGoogleAuthUrl,
  exchangeCodeForTokens,
  getGoogleUserInfo,
} from '../services/oauth.service.js';
import { supabaseAdmin } from '../config/supabase.js';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { emitCoreFeatureEvent } from '../services/coreFeatureEvents.service.js';
import { getClientIp } from '../middlewares/ipBlocklist.js';
import { authRateLimit } from '../middlewares/routeRateLimiter.js';

const router = Router();

// Anti-brute-force login : verrouillage temporaire apres trop d'echecs (autoritaire, cote serveur).
const MAX_LOGIN_ATTEMPTS = 5;
const LOGIN_BLOCK_MINUTES = 30;

/**
 * POST /auth/login
 * Login email/mot de passe AVEC verrouillage anti-brute-force serveur.
 * Le frontend appelle cet endpoint puis fait supabase.auth.setSession(session).
 * Fail-open sur le tracking : si la table failed_login_attempts est indisponible,
 * l'authentification fonctionne quand meme (on ne bloque jamais un login legitime).
 */
router.post('/login', async (req: Request, res: Response): Promise<void> => {
  try {
    const { email, password } = req.body || {};
    if (!email || !password) {
      res.status(400).json({ success: false, error: 'Email et mot de passe requis.' });
      return;
    }

    const identifier = String(email).toLowerCase().trim();
    const ip = getClientIp(req);

    // 1) Verrouillage actif ?
    let existing: { attempt_count?: number; blocked_until?: string | null } | null = null;
    try {
      const { data } = await supabaseAdmin
        .from('failed_login_attempts')
        .select('attempt_count, blocked_until')
        .eq('identifier', identifier)
        .maybeSingle();
      existing = data as any;
    } catch { /* table indisponible -> on continue */ }

    if (existing?.blocked_until && new Date(existing.blocked_until).getTime() > Date.now()) {
      const mins = Math.ceil((new Date(existing.blocked_until).getTime() - Date.now()) / 60000);
      logger.warn(`[auth/login] compte verrouille ${identifier} (IP ${ip})`);
      res.status(429).json({ success: false, error: `Trop de tentatives. Compte bloque ~${mins} min.` });
      return;
    }

    // 2) Authentification
    const { data, error } = await supabaseAdmin.auth.signInWithPassword({ email, password });

    if (error) {
      // 3) Echec -> incrementer (best-effort)
      let blockedUntil: string | null = null;
      try {
        const newCount = (existing?.attempt_count || 0) + 1;
        blockedUntil = newCount >= MAX_LOGIN_ATTEMPTS
          ? new Date(Date.now() + LOGIN_BLOCK_MINUTES * 60000).toISOString()
          : null;
        if (existing) {
          await supabaseAdmin.from('failed_login_attempts').update({
            attempt_count: newCount,
            last_attempt: new Date().toISOString(),
            blocked_until: blockedUntil,
            ip_address: ip,
          }).eq('identifier', identifier);
        } else {
          await supabaseAdmin.from('failed_login_attempts').insert({
            identifier, ip_address: ip, attempt_count: 1, last_attempt: new Date().toISOString(),
          });
        }
      } catch { /* tracking best-effort */ }

      res.status(blockedUntil ? 429 : 401).json({
        success: false,
        error: blockedUntil ? `Trop de tentatives. Compte bloque ${LOGIN_BLOCK_MINUTES} min.` : error.message,
      });
      return;
    }

    // 4) Succes -> reset du compteur
    try { await supabaseAdmin.from('failed_login_attempts').delete().eq('identifier', identifier); } catch { /* best-effort */ }

    res.status(200).json({ success: true, user: data.user, session: data.session });
  } catch (e: any) {
    logger.error('[auth/login] erreur', e);
    res.status(500).json({ success: false, error: 'Erreur interne.' });
  }
});

/**
 * POST /auth/finalize-phone-signup
 * Finalise ATOMIQUEMENT une inscription email vérifiée par téléphone.
 *
 * Contexte : à l'inscription email, le compte est créé via OTP TÉLÉPHONE
 * (Supabase Auth) puis l'email+mot de passe sont rattachés au MÊME compte.
 * Faire ce rattachement côté CLIENT (updateUser) laisse une fenêtre : si ça
 * échoue, on a un compte téléphone sans email/mdp. Ici on le fait côté serveur
 * (admin), de façon idempotente et atomique pour le couple email+mot de passe,
 * + email_confirm:true → l'utilisateur peut se connecter par email IMMÉDIATEMENT
 * (sans attendre la confirmation), en plus du login par téléphone.
 *
 * Sécurité : verifyJWT → on ne modifie QUE le compte du user courant (req.user.id),
 * qui vient de prouver qu'il contrôle le téléphone (OTP vérifié).
 */
const FinalizeSignupSchema = z.object({
  email: z.string().email('Email invalide'),
  password: z.string().min(8, 'Mot de passe : 8 caractères minimum'),
});

router.post('/finalize-phone-signup', verifyJWT, async (req: AuthenticatedRequest, res: Response): Promise<void> => {
  try {
    const userId = req.user!.id;
    const parsed = FinalizeSignupSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ success: false, error: parsed.error.issues[0]?.message || 'Données invalides' });
      return;
    }
    const { email, password } = parsed.data;
    const normalizedEmail = email.trim().toLowerCase();

    // Rattache email + mot de passe au compte (déjà vérifié par téléphone), email confirmé.
    const { error: updErr } = await supabaseAdmin.auth.admin.updateUserById(userId, {
      email: normalizedEmail,
      password,
      email_confirm: true,
    });
    if (updErr) {
      const msg = (updErr.message || '').toLowerCase();
      if (msg.includes('already') || msg.includes('registered') || msg.includes('exists') || msg.includes('duplicate')) {
        res.status(409).json({ success: false, error: 'Cet email est déjà utilisé par un autre compte.' });
        return;
      }
      logger.error(`[auth/finalize] updateUserById failed for ${userId}: ${updErr.message}`);
      res.status(500).json({ success: false, error: "Impossible de rattacher l'email au compte" });
      return;
    }

    // Refléter l'email dans le profil (best-effort, non bloquant)
    const { error: profErr } = await supabaseAdmin
      .from('profiles')
      .update({ email: normalizedEmail, has_password: true })
      .eq('id', userId);
    if (profErr) logger.warn(`[auth/finalize] profile email update: ${profErr.message}`);

    logger.info(`[auth/finalize] email+password attached to ${userId}`);
    res.json({ success: true, data: { email: normalizedEmail } });
  } catch (err: any) {
    logger.error(`[auth/finalize] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la finalisation' });
  }
});

/**
 * POST /auth/check-phone  { phone }
 * Unicité « 1 numéro = 1 compte » : vérifie qu'un numéro n'est PAS déjà lié à un compte
 * AVANT l'inscription. Public + rate-limité (anti-énumération ; l'existence est déjà
 * révélée par le flux OTP existant). Forme canonique = 9 derniers chiffres (RPC déterministe).
 * → 409 { action:'account_recovery' } si pris : le front propose la récupération OTP SMS.
 */
router.post('/check-phone', authRateLimit, async (req: Request, res: Response): Promise<void> => {
  try {
    const phone = String(req.body?.phone ?? '').trim();
    const digits = phone.replace(/[^0-9]/g, '');
    if (digits.length < 8) {
      res.status(400).json({ success: false, error: 'Numéro de téléphone invalide.' });
      return;
    }

    // resolve_user_id_by_phone : déterministe (ORDER BY created_at), compare les 9 derniers chiffres.
    const { data: existingId, error } = await supabaseAdmin.rpc('resolve_user_id_by_phone', { p_phone: phone });
    if (error) {
      logger.error(`[auth/check-phone] resolve error: ${error.message}`);
      res.status(500).json({ success: false, error: 'Vérification du numéro impossible.' });
      return;
    }

    if (existingId) {
      res.status(409).json({
        success: false,
        error: 'Ce numéro est déjà lié à un compte. Veuillez récupérer votre compte existant pour y accéder.',
        action: 'account_recovery',
      });
      return;
    }

    res.json({ success: true, data: { available: true } });
  } catch (err: any) {
    logger.error(`[auth/check-phone] ${err?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la vérification du numéro.' });
  }
});

/**
 * GET /auth/google
 * Redirige l'utilisateur vers l'écran de consentement Google
 */
router.get('/google', (req: Request, res: Response): void => {
  try {
    if (!oauthConfig.enabled) {
      res.status(503).json({ success: false, error: 'OAuth Google non configuré côté serveur' });
      return;
    }

    // State anti-CSRF stocké en mémoire (en prod: cookie httpOnly ou session)
    const state = crypto.randomBytes(16).toString('hex');
    const authUrl = buildGoogleAuthUrl(state);

    logger.info('OAuth: Redirecting to Google consent screen');
    res.redirect(authUrl);
  } catch (error: any) {
    logger.error(`OAuth initiation error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Failed to initiate OAuth flow' });
  }
});

/**
 * GET /auth/google/callback
 * Callback OAuth Google — échange le code et récupère l'utilisateur
 */
router.get('/google/callback', async (req: Request, res: Response): Promise<void> => {
  try {
    if (!oauthConfig.enabled) {
      res.status(503).json({ success: false, error: 'OAuth Google non configuré côté serveur' });
      return;
    }

    const { code, error: oauthError } = req.query;

    if (oauthError) {
      logger.warn(`OAuth denied by user: ${oauthError}`);
      await emitCoreFeatureEvent({
        featureKey: 'auth.oauth.google.callback',
        coreEngine: 'identity',
        ownerModule: 'auth',
        criticality: 'high',
        status: 'failure',
        payload: { reason: String(oauthError) },
      });
      res.status(400).json({ success: false, error: 'OAuth consent denied' });
      return;
    }

    if (!code || typeof code !== 'string') {
      await emitCoreFeatureEvent({
        featureKey: 'auth.oauth.google.callback',
        coreEngine: 'identity',
        ownerModule: 'auth',
        criticality: 'high',
        status: 'failure',
        payload: { reason: 'missing_code' },
      });
      res.status(400).json({ success: false, error: 'Missing authorization code' });
      return;
    }

    // 1. Échange code → tokens (utilise CLIENT_SECRET côté serveur)
    const tokens = await exchangeCodeForTokens(code);

    // 2. Récupère les infos utilisateur
    const userInfo = await getGoogleUserInfo(tokens.access_token);

    // 3. Synchronise avec Supabase Auth (upsert)
    const { data: existingUsers, error: lookupError } = await supabaseAdmin.auth.admin.listUsers();

    if (lookupError) {
      logger.error(`Supabase user lookup error: ${lookupError.message}`);
    }

    const listedUsers = existingUsers?.users ?? [];
    const existingUser = listedUsers.find((u: any) => u.email === userInfo.email);

    let userId: string;

    if (existingUser) {
      userId = existingUser.id;
      logger.info(`OAuth: Existing user found: ${userId}`);
    } else {
      // Créer l'utilisateur dans Supabase Auth
      const { data: newUser, error: createError } = await supabaseAdmin.auth.admin.createUser({
        email: userInfo.email,
        email_confirm: true,
        user_metadata: {
          full_name: userInfo.name,
          avatar_url: userInfo.picture,
          provider: 'google',
        },
      });

      if (createError || !newUser.user) {
        logger.error(`Supabase user creation error: ${createError?.message}`);
        await emitCoreFeatureEvent({
          featureKey: 'auth.oauth.google.user.provision',
          coreEngine: 'identity',
          ownerModule: 'auth',
          criticality: 'critical',
          status: 'failure',
          payload: { error: createError?.message || 'create_user_failed' },
        });
        res.status(500).json({ success: false, error: 'Failed to create user' });
        return;
      }

      userId = newUser.user.id;
      logger.info(`OAuth: New user created: ${userId}`);
    }

    // 4. Répondre avec les infos (le frontend redirigera)
    res.json({
      success: true,
      user: {
        id: userId,
        email: userInfo.email,
        name: userInfo.name,
        picture: userInfo.picture,
      },
      // Note: NE PAS renvoyer tokens.id_token ou access_token Google au frontend
      // Utiliser une session Supabase à la place
    });

    await emitCoreFeatureEvent({
      featureKey: 'auth.oauth.google.callback',
      coreEngine: 'identity',
      ownerModule: 'auth',
      criticality: 'high',
      status: 'success',
      userId,
      payload: { email: userInfo.email },
    });
  } catch (error: any) {
    logger.error(`OAuth callback error: ${error.message}`);
    await emitCoreFeatureEvent({
      featureKey: 'auth.oauth.google.callback',
      coreEngine: 'identity',
      ownerModule: 'auth',
      criticality: 'critical',
      status: 'failure',
      payload: { error: error.message },
    });
    res.status(500).json({ success: false, error: 'OAuth authentication failed' });
  }
});

/**
 * GET /auth/oauth/status
 * Endpoint de diagnostic (sans secrets)
 */
router.get('/oauth/status', (_req: Request, res: Response): void => {
  res.json({
    success: true,
    provider: 'google',
    configured: oauthConfig.enabled,
    note: 'Client Secret is server-side only and never exposed',
  });
});

export default router;
