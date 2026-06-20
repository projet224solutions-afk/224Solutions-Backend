/**
 * 🔐 COGNITO AUTH GATEWAY ROUTES
 * Backend centralise toutes les requêtes d'authentification
 * Vérifie les tokens Cognito et synchronise avec Google Cloud SQL
 */

import express from 'express';
import { verifyCognitoToken, requireCognitoRole } from '../middlewares/cognito.middleware.js';
import { syncCognitoUser, getUserByCognitoId, updateUserProfile } from '../services/cognitoSync.service.js';
import { logger } from '../config/logger.js';

const router = express.Router();

/**
 * POST /api/cognito/sync-profile
 * Après inscription/connexion Cognito côté client,
 * synchronise le profil dans Google Cloud SQL
 */
router.post('/sync-profile', verifyCognitoToken, async (req, res) => {
  try {
    const { additionalData } = req.body;

    const result = await syncCognitoUser(req.cognitoUser, {
      ...additionalData,
      ipAddress: req.ip,
      userAgent: req.get('user-agent'),
    });

    if (!result.success) {
      return res.status(500).json({ success: false, error: result.error });
    }

    logger.info(`✅ Profile synced for Cognito user: ${req.cognitoUser.sub}`);
    res.json({
      success: true,
      message: 'Profil synchronisé',
      user: result.user,
    });
  } catch (error) {
    logger.error(`❌ Profile sync error: ${error.message}`);
    res.status(500).json({
      success: false,
      error: 'Erreur lors de la synchronisation du profil',
    });
  }
});

/**
 * GET /api/cognito/me
 * Récupère le profil utilisateur depuis Cloud SQL
 */
router.get('/me', verifyCognitoToken, async (req, res) => {
  try {
    const user = await getUserByCognitoId(req.cognitoUser.sub);

    if (!user) {
      return res.status(404).json({ success: false, error: 'Profil non trouvé' });
    }

    res.json({ success: true, user });
  } catch (error) {
    logger.error(`❌ Get profile error: ${error.message}`);
    res.status(500).json({
      success: false,
      error: 'Erreur lors de la récupération du profil',
    });
  }
});

/**
 * PUT /api/cognito/profile
 * Met à jour le profil dans Cloud SQL
 */
router.put('/profile', verifyCognitoToken, async (req, res) => {
  try {
    const { sub } = req.cognitoUser;
    const result = await updateUserProfile(sub, req.body);

    if (!result.success) {
      return res.status(400).json(result);
    }

    logger.info(`✅ Profile updated for: ${sub}`);
    res.json({ success: true, message: 'Profil mis à jour', user: result.user });
  } catch (error) {
    logger.error(`❌ Update profile error: ${error.message}`);
    res.status(500).json({
      success: false,
      error: 'Erreur lors de la mise à jour du profil',
    });
  }
});

/**
 * DELETE /api/cognito/account
 * Supprime le compte (soft delete)
 */
router.delete('/account', verifyCognitoToken, async (req, res) => {
  try {
    const { sub } = req.cognitoUser;

    const { query } = await import('../config/cloudSql.js');
    await query(
      'UPDATE users SET is_active = false, deleted_at = NOW() WHERE cognito_user_id = $1',
      [sub]
    );

    logger.info(`✅ Account deactivated for: ${sub}`);
    res.json({ success: true, message: 'Compte désactivé' });
  } catch (error) {
    logger.error(`❌ Delete account error: ${error.message}`);
    res.status(500).json({
      success: false,
      error: 'Erreur lors de la désactivation du compte',
    });
  }
});

/**
 * POST /api/cognito/validate-token
 * Endpoint pour que le frontend vérifie la validité du token
 */
router.post('/validate-token', verifyCognitoToken, (req, res) => {
  res.json({
    success: true,
    valid: true,
    user: req.cognitoUser,
  });
});

export default router;
