/**
 * 🔐 IDEMPOTENCY MIDDLEWARE - Phase 4 (Production Hardened)
 *
 * Prévient les doubles débits et créations dupliquées.
 * Le client envoie un header `Idempotency-Key` (UUID v4).
 *
 * Améliorations production :
 *   - Lié au user_id (isolation par utilisateur)
 *   - Hash du payload pour détecter les réutilisations frauduleuses
 *   - Gestion d'état processing/completed/failed
 *   - Rejet si même clé + payload différent
 */

import { Request, Response, NextFunction } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import crypto from 'crypto';

interface AuthenticatedRequest extends Request {
  user?: { id: string; [key: string]: any };
}

function hashPayload(body: unknown): string {
  const normalized = JSON.stringify(body ?? {});
  return crypto.createHash('sha256').update(normalized).digest('hex');
}

export async function idempotencyGuard(req: AuthenticatedRequest, res: Response, next: NextFunction): Promise<void> {
  const idempotencyKey = req.headers['idempotency-key'] as string;

  if (!idempotencyKey) {
    res.status(400).json({
      success: false,
      error: 'Header Idempotency-Key requis pour cette opération',
      error_code: 'IDEMPOTENCY_KEY_MISSING',
    });
    return;
  }

  // Valider format UUID
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!uuidRegex.test(idempotencyKey)) {
    res.status(400).json({
      success: false,
      error: 'Idempotency-Key doit être un UUID v4 valide',
      error_code: 'IDEMPOTENCY_KEY_INVALID',
    });
    return;
  }

  const userId = req.user?.id;
  if (!userId) {
    res.status(401).json({ success: false, error: 'Authentification requise' });
    return;
  }

  const payloadHash = hashPayload(req.body);

  try {
    // Vérifier si la clé existe déjà pour cet utilisateur
    const { data: existing } = await supabaseAdmin
      .from('idempotency_keys')
      .select('response_body, response_status, status, payload_hash')
      .eq('key', idempotencyKey)
      .eq('user_id', userId)
      .maybeSingle();

    if (existing) {
      // Même clé mais payload différent → rejet (réutilisation frauduleuse)
      if (existing.payload_hash && existing.payload_hash !== payloadHash) {
        logger.warn(`Idempotency key reuse with different payload: key=${idempotencyKey}, user=${userId}`);
        res.status(422).json({
          success: false,
          error: 'Idempotency-Key déjà utilisée avec un payload différent',
        });
        return;
      }

      // Opération encore en cours → retry trop rapide
      if (existing.status === 'processing') {
        res.status(409).json({
          success: false,
          error: 'Opération en cours de traitement, veuillez patienter',
        });
        return;
      }

      // Opération terminée → rejouer la réponse
      if (existing.status === 'completed' && existing.response_body) {
        logger.info(`Idempotent replay: key=${idempotencyKey}, user=${userId}`);
        res.status(existing.response_status || 200).json(existing.response_body);
        return;
      }

      // Statut 'failed' → laisser réessayer
      if (existing.status === 'failed') {
        await supabaseAdmin
          .from('idempotency_keys')
          .update({ status: 'processing', updated_at: new Date().toISOString() })
          .eq('key', idempotencyKey)
          .eq('user_id', userId);
      }
    } else {
      // Insérer la clé en statut 'processing'
      const { error: insertError } = await supabaseAdmin
        .from('idempotency_keys')
        .insert({
          key: idempotencyKey,
          user_id: userId,
          payload_hash: payloadHash,
          status: 'processing',
          method: req.method,
          path: req.originalUrl,
          expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
        });

      if (insertError) {
        // Conflit unique → requête concurrente
        if (insertError.code === '23505') {
          res.status(409).json({
            success: false,
            error: 'Opération déjà en cours de traitement',
          });
          return;
        }
        throw insertError;
      }
    }

    // Intercepter la réponse pour la stocker avec le bon statut
    const originalJson = res.json.bind(res);
    res.json = function (body: any) {
      const finalStatus = res.statusCode >= 200 && res.statusCode < 300 ? 'completed' : 'failed';

      supabaseAdmin
        .from('idempotency_keys')
        .update({
          response_body: body,
          response_status: res.statusCode,
          status: finalStatus,
          updated_at: new Date().toISOString(),
        })
        .eq('key', idempotencyKey)
        .eq('user_id', userId)
        .then(({ error }) => {
          if (error) {
            logger.warn(`Failed to update idempotency key: ${error.message}`);
          }
        });

      return originalJson(body);
    };

    next();
  } catch (error: any) {
    logger.error(`Idempotency middleware error: ${error.message}`);

    // Si la table idempotency_keys n'existe pas en production (code PostgreSQL 42P01),
    // laisser passer la requête plutôt que de bloquer toutes les commandes.
    const msg = String(error?.message || '');
    const isTableMissing =
      error?.code === '42P01' ||
      msg.includes('relation') ||
      msg.includes('does not exist') ||
      msg.includes('idempotency_keys');

    if (isTableMissing) {
      logger.warn('[Idempotency] Table absente — bypass (fail-open). Appliquer la migration SQL idempotency_keys.');
      next();
      return;
    }

    // Pour toutes les autres erreurs inattendues → fail-open (ne pas bloquer la commande)
    // La protection réelle est dans create_order_core (vérification stock atomique)
    logger.warn(`[Idempotency] Erreur inattendue — bypass fail-open: ${msg}`);
    try {
      await supabaseAdmin
        .from('idempotency_keys')
        .update({ status: 'failed', updated_at: new Date().toISOString() })
        .eq('key', idempotencyKey)
        .eq('user_id', userId);
    } catch {
      // ignore — on ne bloque pas la requête pour ça
    }
    next();
  }
}
