/**
 * 🔄 COGNITO SYNC SERVICE
 * Synchronise les utilisateurs Cognito avec Google Cloud SQL
 * Crée/met à jour les profils et wallets automatiquement
 */

import { query, withTransaction } from '../config/cloudSql.js';
import { logger } from '../config/logger.js';

/**
 * Synchronise un utilisateur Cognito avec la base Cloud SQL
 * Appelé après chaque connexion/inscription réussie
 */
export async function syncCognitoUser(cognitoUser, additionalData = {}) {
  const {
    sub: cognitoUserId,
    email,
    role = 'client',
    fullName,
    phone,
  } = cognitoUser;

  try {
    const result = await withTransaction(async (client) => {
      // 1. Upsert user
      const userResult = await client.query(
        `INSERT INTO users (cognito_user_id, email, full_name, phone, city, country, last_login_at)
         VALUES ($1, $2, $3, $4, $5, $6, NOW())
         ON CONFLICT (cognito_user_id)
         DO UPDATE SET
           email = EXCLUDED.email,
           full_name = COALESCE(EXCLUDED.full_name, users.full_name),
           phone = COALESCE(EXCLUDED.phone, users.phone),
           city = COALESCE(EXCLUDED.city, users.city),
           country = COALESCE(EXCLUDED.country, users.country),
           last_login_at = NOW(),
           updated_at = NOW()
         RETURNING *`,
        [cognitoUserId, email, fullName, phone, additionalData.city, additionalData.country]
      );

      const user = userResult.rows[0];

      // 2. Assigner le rôle
      await client.query(
        `INSERT INTO user_roles (user_id, role)
         VALUES ($1, $2)
         ON CONFLICT (user_id, role) DO NOTHING`,
        [user.id, role]
      );

      // 3. Créer le wallet
      await client.query(
        `INSERT INTO wallets (user_id, currency)
         VALUES ($1, $2)
         ON CONFLICT (user_id) DO NOTHING`,
        [user.id, additionalData.currency || 'GNF']
      );

      // 4. Log d'audit
      await client.query(
        `INSERT INTO auth_audit_log (user_id, action, ip_address, user_agent, success)
         VALUES ($1, $2, $3, $4, true)`,
        [user.id, 'login_sync', additionalData.ipAddress, additionalData.userAgent]
      );

      return user;
    });

    logger.info(`✅ Cognito user synced: ${cognitoUserId} -> DB user ${result.id}`);
    return { success: true, user: result };
  } catch (error) {
    logger.error(`❌ Cognito sync error: ${error.message}`);
    return { success: false, error: error.message };
  }
}

/**
 * Récupère le profil complet depuis Cloud SQL
 */
export async function getUserByCognitoId(cognitoUserId) {
  try {
    const result = await query(
      `SELECT u.*,
              array_agg(ur.role) as roles,
              w.balance, w.currency
       FROM users u
       LEFT JOIN user_roles ur ON ur.user_id = u.id
       LEFT JOIN wallets w ON w.user_id = u.id
       WHERE u.cognito_user_id = $1 AND u.is_active = true
       GROUP BY u.id, w.balance, w.currency`,
      [cognitoUserId]
    );

    return result.rows[0] || null;
  } catch (error) {
    logger.error(`❌ Get user by Cognito ID error: ${error.message}`);
    return null;
  }
}

/**
 * Met à jour le profil utilisateur
 */
export async function updateUserProfile(cognitoUserId, updates) {
  const allowedFields = ['full_name', 'first_name', 'last_name', 'phone', 'city', 'country', 'avatar_url'];
  const setClauses = [];
  const values = [];
  let paramIndex = 1;

  for (const [key, value] of Object.entries(updates)) {
    if (allowedFields.includes(key) && value !== undefined) {
      setClauses.push(`${key} = $${paramIndex}`);
      values.push(value);
      paramIndex++;
    }
  }

  if (setClauses.length === 0) {
    return { success: false, error: 'Aucun champ à mettre à jour' };
  }

  values.push(cognitoUserId);

  try {
    const result = await query(
      `UPDATE users SET ${setClauses.join(', ')}, updated_at = NOW()
       WHERE cognito_user_id = $${paramIndex}
       RETURNING *`,
      values
    );

    return { success: true, user: result.rows[0] };
  } catch (error) {
    logger.error(`❌ Update profile error: ${error.message}`);
    return { success: false, error: error.message };
  }
}
