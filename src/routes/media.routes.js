/**
 * 📸 MEDIA PROCESSING ROUTES
 * Upload et traitement de médias
 */

import express from 'express';
import multer from 'multer';
import { mkdirSync, readFileSync, unlinkSync } from 'fs';
import { authenticateToken } from '../middlewares/auth.js';
import { uploadRateLimiter } from '../middlewares/rateLimiter.js';
import { logger } from '../config/logger.js';
import { supabaseAdmin } from '../config/supabase.js';

const router = express.Router();
const uploadDestination = process.env.VERCEL ? '/tmp/uploads' : (process.env.UPLOAD_PATH || './uploads/');

// Ensure upload directory exists (writable /tmp on Lambda, local dir otherwise)
try { mkdirSync(uploadDestination, { recursive: true }); } catch (_) { /* ignore if already exists */ }

// Configuration Multer
const upload = multer({
  dest: uploadDestination,
  limits: {
    fileSize: parseInt(process.env.MAX_FILE_SIZE) || 10 * 1024 * 1024 // 10MB
  },
  fileFilter: (req, file, cb) => {
    const allowedMimes = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'];

    if (allowedMimes.includes(file.mimetype)) {
      cb(null, true);
    } else {
      cb(new Error('Invalid file type. Only images are allowed.'));
    }
  }
});

// Protection: Authentification + Rate limiting
router.use(authenticateToken);
router.use(uploadRateLimiter);

/**
 * POST /media/upload
 * Upload d'un fichier média
 */
router.post('/upload', upload.single('file'), async (req, res) => {
  let localFilePath = null;
  try {
    if (!req.file) {
      return res.status(400).json({ success: false, error: 'No file uploaded' });
    }

    localFilePath = req.file.path;
    const userId = req.user.id;
    const originalName = req.file.originalname.replace(/[^a-zA-Z0-9._-]/g, '_');
    const storagePath = `uploads/${userId}/${Date.now()}-${originalName}`;

    logger.info(`Upload vers Supabase Storage: ${storagePath} par ${userId}`);

    const fileBuffer = readFileSync(localFilePath);

    // Vérifier le type RÉEL du fichier via magic bytes (indépendant du header client) — Correction 8
    const { fileTypeFromBuffer } = await import('file-type');
    const detectedType = await fileTypeFromBuffer(fileBuffer);
    const allowedRealMimes = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'];
    if (!detectedType || !allowedRealMimes.includes(detectedType.mime)) {
      logger.warn(`Upload refusé — type réel: ${detectedType?.mime || 'inconnu'}, déclaré: ${req.file.mimetype} par user ${userId}`);
      return res.status(400).json({ success: false, error: 'Type de fichier invalide — le contenu ne correspond pas à une image autorisée' });
    }

    const { data, error: uploadError } = await supabaseAdmin.storage
      .from('media')
      .upload(storagePath, fileBuffer, { contentType: detectedType.mime, upsert: false });

    if (uploadError) {
      logger.error(`Erreur upload Supabase Storage: ${uploadError.message}`);
      return res.status(500).json({ success: false, error: 'Échec upload cloud' });
    }

    const { data: urlData } = supabaseAdmin.storage.from('media').getPublicUrl(data.path);
    logger.info(`Upload réussi: ${urlData.publicUrl}`);

    res.json({
      success: true,
      message: 'Fichier uploadé avec succès',
      file: { url: urlData.publicUrl, path: data.path, originalname: req.file.originalname, size: req.file.size, mimetype: detectedType.mime },
    });
  } catch (error) {
    logger.error(`Upload error: ${error.message}`);
    res.status(500).json({ success: false, error: error.message });
  } finally {
    if (localFilePath) { try { unlinkSync(localFilePath); } catch { /* ignore */ } }
  }
});

/**
 * POST /media/optimize
 * Optimisation d'images (compression, resize)
 */
router.post('/optimize', upload.single('image'), async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({
        success: false,
        error: 'No image provided'
      });
    }

    logger.info(`Image optimization requested by ${req.user.id}`);

    return res.status(501).json({ success: false, error: 'Optimisation non encore implémentée — utiliser directement /upload' });
  } catch (error) {
    logger.error(`Optimization error: ${error.message}`);
    res.status(500).json({
      success: false,
      error: error.message
    });
  }
});

export default router;
