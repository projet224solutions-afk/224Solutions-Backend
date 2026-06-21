/**
 * ⚙️ JOBS & CRON ROUTES
 * Routes pour les tâches programmées et jobs lourds
 */

import express from 'express';
import { authenticateToken, requireRole } from '../middlewares/auth.js';
import { logger } from '../config/logger.js';

const router = express.Router();

// Protection: Authentification requise
router.use(authenticateToken);

/**
 * POST /jobs/process-images
 * Traitement batch d'images
 */
router.post('/process-images', requireRole('admin', 'vendeur'), async (req, res) => {
  try {
    const { images, operations } = req.body;

    logger.info(`Image processing job started by ${req.user.id}`);

    // Enfile le job si la file (Redis/BullMQ) est configurée, sinon 501 honnête (pas de faux succès).
    if (process.env.REDIS_URL) {
      const { jobQueue } = await import('../jobs/jobQueue.js');
      await jobQueue.enqueue('process-images', { images, operations, userId: req.user.id });
      return res.json({ success: true, message: 'Job d\'images enfilé', count: images?.length || 0 });
    }
    return res.status(501).json({
      success: false,
      error: 'Traitement d\'images non disponible — file de jobs (Redis) non configurée',
    });
  } catch (error) {
    logger.error(`Image processing error: ${error.message}`);
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

/**
 * POST /jobs/generate-reports
 * Génération de rapports lourds
 */
router.post('/generate-reports', requireRole('admin', 'vendeur'), async (req, res) => {
  try {
    const { reportType, dateRange, filters } = req.body;

    logger.info(`Report generation started: ${reportType} by ${req.user.id}`);

    return res.status(501).json({
      success: false,
      error: 'Génération de rapports non encore implémentée',
      hint: 'Utiliser les exports CSV depuis le dashboard PDG',
    });
  } catch (error) {
    logger.error(`Report generation error: ${error.message}`);
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

/**
 * GET /jobs/:jobId/status
 * Vérifier le statut d'un job
 */
router.get('/:jobId/status', async (req, res) => {
  try {
    const { jobId } = req.params;

    return res.status(501).json({ success: false, error: 'Statut jobs non disponible' });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

export default router;
