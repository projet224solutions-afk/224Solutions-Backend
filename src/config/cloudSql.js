/**
 * 🗄️ GOOGLE CLOUD SQL - CONNECTION POOL
 * Configuration PostgreSQL pour Google Cloud SQL
 * Optimisé pour haute scalabilité (millions d'utilisateurs)
 */

import pg from 'pg';
import { logger } from './logger.js';

const { Pool } = pg;

/**
 * Pool de connexions PostgreSQL
 * En production, utiliser le Cloud SQL Auth Proxy ou connecteur natif
 */
const pool = new Pool({
  // Option 1: Connexion directe (dev/test)
  host: process.env.CLOUD_SQL_HOST || 'localhost',
  port: parseInt(process.env.CLOUD_SQL_PORT || '5432'),
  database: process.env.CLOUD_SQL_DATABASE || '224solutions',
  user: process.env.CLOUD_SQL_USER || 'postgres',
  password: process.env.CLOUD_SQL_PASSWORD || '',

  // Option 2: Via Cloud SQL Proxy (production)
  // connectionString: process.env.DATABASE_URL,

  // Pool settings optimisés pour haute charge
  max: parseInt(process.env.DB_POOL_MAX || '20'),          // Max connexions
  min: parseInt(process.env.DB_POOL_MIN || '5'),            // Min connexions
  idleTimeoutMillis: 30000,                                  // 30s idle timeout
  connectionTimeoutMillis: 10000,                            // 10s connection timeout
  maxUses: 7500,                                             // Recycle après N requêtes

  // SSL pour production
  ssl: process.env.NODE_ENV === 'production' ? {
    rejectUnauthorized: true,
    ca: process.env.CLOUD_SQL_CA_CERT,
  } : false,
});

// Événements du pool
pool.on('connect', () => {
  logger.debug('📦 New Cloud SQL connection established');
});

pool.on('error', (err) => {
  logger.error(`❌ Cloud SQL pool error: ${err.message}`);
});

/**
 * Helper: Exécuter une requête avec retry
 */
export async function query(text, params, retries = 3) {
  let lastError;
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const start = Date.now();
      const result = await pool.query(text, params);
      const duration = Date.now() - start;

      if (duration > 1000) {
        logger.warn(`⚠️ Slow query (${duration}ms): ${text.substring(0, 100)}`);
      }

      return result;
    } catch (error) {
      lastError = error;
      if (attempt === retries) {
        logger.error(`❌ Query failed after ${retries} attempts: ${error.message}`);
        throw error;
      }
      logger.warn(`⚠️ Query attempt ${attempt} failed, retrying...`);
      await new Promise(r => setTimeout(r, 1000 * attempt));
    }
  }
  throw lastError; // Garantit qu'une erreur est toujours lancée
}

/**
 * Transaction helper
 */
export async function withTransaction(callback) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await callback(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

/**
 * Health check
 */
export async function checkConnection() {
  try {
    const result = await pool.query('SELECT NOW() as now');
    return { connected: true, timestamp: result.rows[0].now };
  } catch (error) {
    return { connected: false, error: error.message };
  }
}

export { pool };
export default pool;
