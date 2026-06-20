/**
 * 💰 Routes Wallet - Gestion des portefeuilles utilisateurs
 *
 * Utilise la service role de Supabase pour contourner les RLS
 * Ces routes doivent être appelées UNIQUEMENT depuis le frontend autorisé
 */

import express from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import { createClient } from '@supabase/supabase-js';
import { logger } from '../config/logger.js';

const router = express.Router();

// Initialiser Supabase avec service role
const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

/**
 * POST /api/wallet/initialize
 *
 * Initialise ou charge le wallet d'un utilisateur
 * La RLS est contournée via la service_role côté backend
 *
 * Body: {
 *   user_id: string (UUID de l'utilisateur)
 * }
 *
 * Response: {
 *   id: string,
 *   user_id: string,
 *   balance: number,
 *   currency: string,
 *   wallet_status: string,
 *   created_at: string
 * }
 */
router.post('/initialize', verifyJWT, async (req, res) => {
  try {
    const { user_id } = req.body;

    // Valider que le user_id fait partie du token JWT
    if (req.user?.sub !== user_id && req.user?.id !== user_id) {
      return res.status(403).json({
        error: 'Unauthorized',
        message: 'Vous ne pouvez initialiser que votre propre wallet'
      });
    }

    if (!user_id) {
      return res.status(400).json({
        error: 'Bad Request',
        message: 'user_id est requis'
      });
    }

    // Vérifier si l'utilisateur existe dans auth.users
    const { data: userData, error: userError } = await supabase.auth.admin.getUserById(user_id);

    if (userError || !userData) {
      logger.error(`User not found: ${user_id}`, userError);
      return res.status(404).json({
        error: 'Not Found',
        message: 'Utilisateur non trouvé'
      });
    }

    // Vérifier si le wallet existe déjà
    const { data: existingWallet, error: selectError } = await supabase
      .from('wallets')
      .select('*')
      .eq('user_id', user_id)
      .single();

    if (!selectError && existingWallet) {
      // Le wallet existe déjà
      logger.info(`Wallet already exists for user: ${user_id}`);
      return res.json({
        success: true,
        wallet: existingWallet,
        created: false
      });
    }

    // Créer un nouveau wallet
    const { data: newWallet, error: insertError } = await supabase
      .from('wallets')
      .insert({
        user_id,
        balance: 0,
        currency: 'GNF',
        wallet_status: 'active'
      })
      .select()
      .single();

    if (insertError) {
      logger.error(`Failed to create wallet for user: ${user_id}`, insertError);
      return res.status(500).json({
        error: 'Database Error',
        message: 'Impossible de créer le wallet',
        details: insertError.message
      });
    }

    if (!newWallet) {
      logger.error(`Wallet created but not returned for user: ${user_id}`);
      return res.status(500).json({
        error: 'Unexpected Error',
        message: 'Wallet créé mais non retourné'
      });
    }

    logger.info(`Wallet created successfully for user: ${user_id}`);
    res.json({
      success: true,
      wallet: newWallet,
      created: true
    });

  } catch (error) {
    logger.error('Error initializing wallet:', error);
    res.status(500).json({
      error: 'Internal Server Error',
      message: 'Une erreur s\'est produite lors de l\'initialisation du wallet'
    });
  }
});

/**
 * POST /api/wallet/check
 *
 * Vérifie et retourne les informations du wallet
 */
router.post('/check', verifyJWT, async (req, res) => {
  try {
    const { user_id } = req.body || {};
    const currentUserId = user_id || req.user?.sub || req.user?.id;

    if (!currentUserId) {
      return res.status(400).json({
        error: 'Bad Request',
        message: 'Impossible de déterminer l\'utilisateur'
      });
    }

    const { data: wallet, error } = await supabase
      .from('wallets')
      .select('*')
      .eq('user_id', currentUserId)
      .single();

    if (error && error.code !== 'PGRST116') {
      logger.error(`Error checking wallet: ${error.message}`, error);
      return res.status(500).json({
        error: 'Database Error',
        message: 'Erreur lors de la vérification du wallet'
      });
    }

    res.json({
      exists: !!wallet,
      wallet: wallet || null
    });

  } catch (error) {
    logger.error('Error checking wallet:', error);
    res.status(500).json({
      error: 'Internal Server Error',
      message: 'Une erreur s\'est produite'
    });
  }
});

export default router;
