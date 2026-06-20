/**
 * 📄 CONTRATS — lien de signature PUBLIC par jeton.
 *
 * Permet à un client (même non inscrit) d'ouvrir et signer un contrat via
 * /contrat/<share_token>. Le jeton est l'unique secret ; tout passe par
 * supabaseAdmin (service_role) — aucun accès anon direct à la table `contracts`.
 *
 *   GET  /api/contracts/public/:token        → contenu du contrat (lecture seule)
 *   POST /api/contracts/public/:token/sign   → enregistre la signature client
 */

import { Router, Request, Response } from 'express';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

// Champs exposés publiquement (pas de données internes superflues).
const PUBLIC_FIELDS =
  'id, contract_type, client_name, contract_content, status, client_signature_url, vendor_signature_url, signed_at, created_at';

/** GET /api/contracts/public/:token — contrat par jeton (lecture seule). */
router.get('/public/:token', async (req: Request, res: Response) => {
  try {
    const token = String(req.params.token || '').trim();
    if (!token) { res.status(400).json({ success: false, error: 'Jeton manquant' }); return; }

    const { data, error } = await supabaseAdmin
      .from('contracts')
      .select(PUBLIC_FIELDS)
      .eq('share_token', token)
      .maybeSingle();

    if (error) { logger.error(`[contracts/public] ${error.message}`); res.status(500).json({ success: false, error: 'Erreur interne' }); return; }
    if (!data) { res.status(404).json({ success: false, error: 'Contrat introuvable ou lien invalide' }); return; }

    res.json({ success: true, data });
  } catch (e: any) {
    logger.error(`[contracts/public GET] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** POST /api/contracts/public/:token/sign — signature client (idempotent). */
router.post('/public/:token/sign', async (req: Request, res: Response) => {
  try {
    const token = String(req.params.token || '').trim();
    const { signature_data } = req.body || {};
    if (!token) { res.status(400).json({ success: false, error: 'Jeton manquant' }); return; }
    if (!signature_data || typeof signature_data !== 'string' || !signature_data.startsWith('data:image')) {
      res.status(400).json({ success: false, error: 'Signature invalide' }); return;
    }

    const { data: contract, error: fetchErr } = await supabaseAdmin
      .from('contracts')
      .select('id, status')
      .eq('share_token', token)
      .maybeSingle();

    if (fetchErr) { logger.error(`[contracts/sign] ${fetchErr.message}`); res.status(500).json({ success: false, error: 'Erreur interne' }); return; }
    if (!contract) { res.status(404).json({ success: false, error: 'Contrat introuvable ou lien invalide' }); return; }

    if (contract.status === 'signed') {
      res.json({ success: true, already_signed: true });
      return;
    }
    if (contract.status === 'archived') {
      res.status(409).json({ success: false, error: 'Contrat archivé, signature impossible' });
      return;
    }

    // Claim atomique : ne signe que si pas déjà signé (anti double-signature concurrente).
    const { data: updated, error: updErr } = await supabaseAdmin
      .from('contracts')
      .update({
        client_signature_url: signature_data,
        status: 'signed',
        signed_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq('share_token', token)
      .neq('status', 'signed')
      .select('id')
      .maybeSingle();

    if (updErr) { logger.error(`[contracts/sign] update ${updErr.message}`); res.status(500).json({ success: false, error: 'Échec de la signature' }); return; }
    if (!updated) { res.json({ success: true, already_signed: true }); return; }

    logger.info(`[contracts/sign] contrat signé via lien public: ${contract.id}`);
    res.json({ success: true });
  } catch (e: any) {
    logger.error(`[contracts/public POST sign] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

export default router;
