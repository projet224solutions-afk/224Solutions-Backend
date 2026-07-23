/**
 * 🏢 ROUTES BUREAU SYNDICAT (BACKEND) — auth JWT + opérations SCOPÉES au bureau
 * ---------------------------------------------------------------------------
 * Ferme la faille d'isolation : le `bureau_id` provient TOUJOURS du JWT validé
 * (jamais du client). Les RPC bureau (stats/véhicule/membre) ne sont plus appelées
 * en anon mais via service_role ici, après authentification.
 */

import { Router, Response } from 'express';
import { z } from 'zod';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { signBureauToken } from '../services/bureauAuth.service.js';
import { verifyBureauJWT, type BureauRequest } from '../middlewares/bureauAuth.middleware.js';
import { authRateLimit } from '../middlewares/routeRateLimiter.js';

/**
 * Anti-injection de filtre PostgREST : un `identifier` interpolé dans `.or(...)` ne doit
 * contenir que des caractères valides d'un email ou d'un code bureau. On retire notamment
 * les métacaractères `, ( ) : *` qui permettraient d'injecter des conditions supplémentaires.
 */
function sanitizeIdentifier(raw: string): string {
  return String(raw || '').trim().replace(/[^A-Za-z0-9._%+@-]/g, '');
}

const router = Router();

const otpSchema = z.object({
  identifier: z.string().trim().min(1),
  otp: z.string().trim().regex(/^\d{6}$/, 'Code à 6 chiffres requis'),
});

/**
 * POST /api/v2/bureau/auth/verify-otp — vérifie l'OTP (RPC) puis émet un JWT bureau signé.
 * (L'envoi de l'OTP reste géré en amont ; ici on valide et on délivre la session sûre.)
 */
router.post('/auth/verify-otp', async (req: BureauRequest, res: Response) => {
  try {
    const parsed = otpSchema.safeParse(req.body);
    if (!parsed.success) { res.status(400).json({ success: false, error: parsed.error.issues[0].message }); return; }
    const { identifier, otp } = parsed.data;

    const { data: verify, error: vErr } = await supabaseAdmin.rpc('verify_otp_code', {
      p_identifier: identifier, p_user_type: 'bureau', p_otp_code: otp,
    });
    if (vErr) { logger.error(`[bureau/verify-otp] ${vErr.message}`); res.status(500).json({ success: false, error: 'Erreur de vérification' }); return; }

    const row = Array.isArray(verify) ? verify[0] : verify;
    if (!row?.is_valid) {
      res.status(401).json({ success: false, error: row?.message || 'Code incorrect', attempts_remaining: row?.attempts_remaining });
      return;
    }

    const { data: bureau } = await supabaseAdmin
      .from('syndicate_bureaus')
      .select('id, bureau_code, prefecture, commune, status')
      .eq('id', row.user_id)
      .maybeSingle();
    if (!bureau) { res.status(404).json({ success: false, error: 'Bureau introuvable' }); return; }
    if (bureau.status && ['suspended', 'deleted', 'inactive'].includes(String(bureau.status).toLowerCase())) {
      res.status(403).json({ success: false, error: 'Bureau inactif' }); return;
    }

    const { token, expiresIn } = signBureauToken({ bureauId: bureau.id, bureauCode: bureau.bureau_code });
    res.json({
      success: true, token, expiresIn,
      bureau: { id: bureau.id, bureau_code: bureau.bureau_code, prefecture: bureau.prefecture, commune: bureau.commune },
    });
  } catch (e: any) {
    logger.error(`[bureau/verify-otp] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

/**
 * POST /api/v2/bureau/auth/resend-otp — régénère et renvoie un OTP au bureau (étape 1 déjà passée).
 * Réplique le pipeline du login (generate_otp_code → send-otp-email) sans redemander le mot de passe.
 */
router.post('/auth/resend-otp', authRateLimit, async (req: BureauRequest, res: Response) => {
  try {
    const identifier = sanitizeIdentifier(req.body?.identifier);
    if (!identifier) { res.status(400).json({ success: false, error: 'identifier requis' }); return; }

    // Résoudre le bureau par email du président OU code bureau
    const { data: bureau } = await supabaseAdmin
      .from('syndicate_bureaus')
      .select('id, bureau_code, president_email, president_name, status')
      .or(`president_email.eq.${identifier},bureau_code.eq.${identifier}`)
      .maybeSingle();
    if (!bureau) { res.status(404).json({ success: false, error: 'Bureau introuvable' }); return; }
    if (bureau.status && ['suspended', 'deleted', 'inactive'].includes(String(bureau.status).toLowerCase())) {
      res.status(403).json({ success: false, error: 'Bureau inactif' }); return;
    }

    // Générer un nouvel OTP (même RPC que le login)
    const { data: otpData, error: otpErr } = await supabaseAdmin.rpc('generate_otp_code', {
      p_identifier: identifier,
      p_user_type: 'bureau',
      p_user_id: bureau.id,
      p_ip_address: (req.headers['x-forwarded-for'] as string) || req.ip || 'unknown',
      p_user_agent: (req.headers['user-agent'] as string) || 'unknown',
    });
    const otpRow = Array.isArray(otpData) ? otpData[0] : otpData;
    if (otpErr || !otpRow?.otp_code) {
      logger.error(`[bureau/resend-otp] génération OTP: ${otpErr?.message || 'vide'}`);
      res.status(500).json({ success: false, error: 'Impossible de générer le code' }); return;
    }

    // Envoyer par email via la même fonction que le login (best-effort)
    try {
      await supabaseAdmin.functions.invoke('send-otp-email', {
        body: { email: bureau.president_email, otp: otpRow.otp_code, userType: 'bureau', userName: bureau.president_name || 'Président' },
      });
    } catch (e: any) {
      logger.warn(`[bureau/resend-otp] envoi email: ${e?.message}`);
    }

    res.json({ success: true, otp_expires_at: otpRow.expires_at });
  } catch (e: any) {
    logger.error(`[bureau/resend-otp] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

/** GET /api/v2/bureau/stats — stats temps réel DU bureau authentifié (jamais un autre). */
router.get('/stats', verifyBureauJWT, async (req: BureauRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('get_bureau_realtime_stats', { p_bureau_id: req.bureau!.bureau_id });
    if (error) throw error;
    res.json({ success: true, stats: Array.isArray(data) ? data[0] : data });
  } catch (e: any) {
    logger.error(`[bureau/stats] ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur stats bureau' });
  }
});

/** POST /api/v2/bureau/vehicle — ajoute un véhicule AU bureau authentifié. */
router.post('/vehicle', verifyBureauJWT, async (req: BureauRequest, res: Response) => {
  try {
    const b = req.body || {};
    const { data, error } = await supabaseAdmin.rpc('add_vehicle_for_bureau', {
      p_bureau_id: req.bureau!.bureau_id, // forcé depuis le JWT
      p_owner_name: b.owner_name ?? null,
      p_member_id: b.member_id ?? null,
      p_serial_number: b.serial_number ?? null,
      p_license_plate: b.license_plate ?? null,
      p_vehicle_type: b.vehicle_type ?? 'motorcycle',
      p_brand: b.brand ?? null,
      p_model: b.model ?? null,
      p_year: b.year ?? null,
      p_color: b.color ?? null,
      p_driver_photo_url: b.driver_photo_url ?? null,
      p_driver_date_of_birth: b.driver_date_of_birth ?? null,
    });
    if (error) throw error;
    res.json({ success: true, result: data });
  } catch (e: any) {
    logger.error(`[bureau/vehicle] ${e?.message}`);
    res.status(400).json({ success: false, error: e?.message || 'Erreur ajout véhicule' });
  }
});

/** POST /api/v2/bureau/member — ajoute un membre AU bureau authentifié. */
router.post('/member', verifyBureauJWT, async (req: BureauRequest, res: Response) => {
  try {
    const nom = String(req.body?.nom || req.body?.p_nom || '').trim();
    if (!nom) { res.status(400).json({ success: false, error: 'Nom requis' }); return; }
    const { data, error } = await supabaseAdmin.rpc('add_syndicate_member_for_vehicle', {
      p_bureau_id: req.bureau!.bureau_id, // forcé depuis le JWT
      p_nom: nom,
    });
    if (error) throw error;
    res.json({ success: true, member_id: data });
  } catch (e: any) {
    logger.error(`[bureau/member] ${e?.message}`);
    res.status(400).json({ success: false, error: e?.message || 'Erreur ajout membre' });
  }
});

export default router;
