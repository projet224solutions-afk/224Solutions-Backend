/**
 * 🎓 ÉDUCATION — inscription payante (débit élève → net formateur + commission PDG),
 * progression et délivrance de certificat. RPC atomiques (REVOKE PUBLIC).
 *   POST /api/v2/education/enroll                       → l'élève s'inscrit (paie).
 *   POST /api/v2/education/enrollment/:id/progress      → le formateur met à jour la progression.
 *   POST /api/v2/education/enrollment/:id/certificate   → le formateur délivre le certificat.
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

function mapError(msg: string): { code: number; error: string } {
  if (/COURSE_NOT_FOUND|ENROLLMENT_NOT_FOUND/.test(msg)) return { code: 404, error: 'Introuvable' };
  if (/COURSE_NOT_ACTIVE/.test(msg)) return { code: 409, error: 'Ce cours n\'est pas ouvert aux inscriptions' };
  if (/COURSE_FULL/.test(msg)) return { code: 409, error: 'Ce cours est complet' };
  if (/NOT_OWNER/.test(msg)) return { code: 403, error: 'Action réservée au formateur' };
  if (/CERTIFICATE_DISABLED/.test(msg)) return { code: 409, error: 'Certificat désactivé pour ce cours' };
  if (/INSUFFICIENT_FUNDS/.test(msg)) return { code: 402, error: 'Solde wallet insuffisant' };
  if (/WALLET_BLOCKED/.test(msg)) return { code: 403, error: 'Wallet bloqué' };
  return { code: 400, error: msg };
}

router.post('/enroll', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { course_id, student_name, student_phone } = req.body ?? {};
    if (!course_id) { res.status(400).json({ success: false, error: 'course_id requis' }); return; }
    const { data, error } = await supabaseAdmin.rpc('enroll_course_atomic', {
      p_actor_user_id: req.user!.id, p_course_id: course_id,
      p_student_name: student_name ?? null, p_student_phone: student_phone ?? null,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[edu/enroll] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur inscription' }); }
});

router.post('/enrollment/:id/progress', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const percent = Number(req.body?.percent);
    if (!Number.isFinite(percent)) { res.status(400).json({ success: false, error: 'percent invalide' }); return; }
    const { data, error } = await supabaseAdmin.rpc('set_enrollment_progress_atomic', {
      p_actor_user_id: req.user!.id, p_enrollment_id: req.params.id, p_percent: Math.round(percent),
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[edu/progress] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur' }); }
});

router.post('/enrollment/:id/certificate', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('issue_course_certificate_atomic', {
      p_actor_user_id: req.user!.id, p_enrollment_id: req.params.id,
    });
    if (error) { const m = mapError(error.message); res.status(m.code).json({ success: false, error: m.error }); return; }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[edu/cert] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur certificat' }); }
});

export default router;
