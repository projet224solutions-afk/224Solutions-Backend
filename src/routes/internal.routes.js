/**
 * 🔒 INTERNAL API ROUTES
 * Routes protégées par clé API interne (communication inter-backends)
 */

import express from 'express';
import { authenticateInternal } from '../middlewares/auth.js';
import { logger } from '../config/logger.js';

const router = express.Router();

// Toutes les routes sont protégées par clé API interne
router.use(authenticateInternal);

/**
 * POST /internal/trigger-job
 * Déclenche un job depuis Edge Functions
 */
router.post('/trigger-job', async (req, res) => {
  try {
    const { jobType, payload } = req.body;

    logger.info(`Internal job triggered: ${jobType}`);

    // Enfile via la file de jobs (Redis/BullMQ) si configurée, sinon 501 honnête.
    if (process.env.REDIS_URL && jobType) {
      const { jobQueue } = await import('../jobs/jobQueue.js');
      await jobQueue.enqueue(jobType, payload || {});
      logger.info(`Internal job enqueued: ${jobType}`);
      return res.json({ success: true, message: 'Job déclenché', jobType });
    }
    logger.warn(`Internal job non disponible: ${jobType}`);
    return res.status(501).json({
      success: false,
      error: `Job "${jobType}" non disponible — file de jobs (Redis) non configurée ou jobType manquant`,
    });
  } catch (error) {
    logger.error(`Internal job error: ${error.message}`);
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

/**
 * POST /internal/process-batch
 * Traitement batch de données
 */
router.post('/process-batch', async (req, res) => {
  try {
    const { data, operation } = req.body;

    logger.info(`Batch processing started: ${operation}`);

    return res.status(501).json({
      success: false,
      error: 'Traitement batch non encore implémenté',
    });
  } catch (error) {
    logger.error(`Batch processing error: ${error.message}`);
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

export default router;
