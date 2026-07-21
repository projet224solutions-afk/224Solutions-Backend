/**
 * EDGE COMPAT — phone-signup-send (routage SMS multi-pays).
 *
 * Remplace l'Edge Function Supabase `phone-signup-send` qui était câblée EN DUR sur Twilio
 * (aucun Orange pour la Guinée, aucun repli). Ici l'OTP d'inscription part par la cascade
 * `sendSms(to, msg, countryCode)` : Orange (GN + pays configurés) → Twilio international → Edge,
 * avec bascule automatique. Si AUCUN fournisseur ne couvre le pays → repli email GUIDÉ
 * (flag `sms_unavailable` → le front propose l'inscription par email, jamais d'impasse).
 *
 * Le VERIFY d'inscription reste sur l'Edge Function (il ne fait aucun envoi SMS).
 * Route PUBLIQUE (utilisateur pas encore créé) → déclarée dans isPublicEdgePath (index.ts).
 */
import { Router, Request, Response } from 'express';
import { supabaseAdmin } from '../../config/supabase.js';
import { logger } from '../../config/logger.js';
import { sendSms } from '../../services/sms.service.js';

const router = Router();

/** Normalise en E.164 (le front envoie déjà de l'E.164 ; repli GN uniquement sur 9 chiffres nus). */
function normalizePhone(raw: string): string {
  const clean = String(raw || '').trim().replace(/[\s\-().]/g, '');
  const digits = clean.replace(/[^\d]/g, '');
  if (clean.startsWith('+')) return clean;
  if (digits.startsWith('00') && digits.length >= 12) return '+' + digits.slice(2);
  if (digits.length === 9) return '+224' + digits; // repli GN (le front envoie normalement l'indicatif)
  return '+' + digits;
}

router.post('/phone-signup-send', async (req: Request, res: Response): Promise<void> => {
  try {
    const { phone, country_code } = req.body || {};
    if (!phone) { res.status(400).json({ success: false, error: 'Numéro requis' }); return; }

    const normalized = normalizePhone(String(phone));
    const digits = normalized.replace(/[^\d]/g, '');

    // Variantes (dont le format espacé « +224 624… » stocké à l'inscription email).
    const spaceVariants: string[] = [];
    for (let codeLen = 1; codeLen <= 4; codeLen++) {
      if (digits.length > codeLen) spaceVariants.push('+' + digits.slice(0, codeLen) + ' ' + digits.slice(codeLen));
    }
    const variants = [...new Set([normalized, '+' + digits, digits, ...spaceVariants])];

    // Le numéro ne doit pas déjà exister (1 numéro = 1 compte).
    const { data: existing } = await supabaseAdmin.from('profiles').select('id').in('phone', variants).maybeSingle();
    if (existing) {
      res.json({ success: false, error: 'Ce numéro est déjà associé à un compte. Connectez-vous.', alreadyExists: true });
      return;
    }

    const otp = Math.floor(100000 + Math.random() * 900000).toString();
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000);

    await supabaseAdmin.from('auth_otp_codes').delete()
      .eq('identifier', normalized).eq('user_type', 'phone_signup').eq('verified', false);

    const { error: insertError } = await supabaseAdmin.from('auth_otp_codes').insert({
      user_type: 'phone_signup',
      user_id: '00000000-0000-0000-0000-000000000000', // placeholder — compte pas encore créé
      identifier: normalized,
      otp_code: otp,
      expires_at: expiresAt.toISOString(),
      verified: false,
      attempts: 0,
      created_at: new Date().toISOString(),
    });
    if (insertError) {
      logger.error(`[phone-signup-send] OTP insert: ${insertError.message}`);
      res.status(500).json({ success: false, error: 'Erreur serveur' });
      return;
    }

    // Envoi via la cascade multi-fournisseurs, routée par pays (indicatif déduit du E.164 si country_code absent).
    const iso = typeof country_code === 'string' && country_code.length >= 2 ? country_code.toUpperCase() : undefined;
    const message = `224Solutions - Code d'inscription : ${otp}\nValable 10 minutes.`;
    const sent = await sendSms(normalized, message, iso);
    if (!sent.ok) {
      logger.warn(`[phone-signup-send] SMS échec ${normalized} (${iso || 'auto'}): ${sent.error}`);
      res.status(502).json({
        success: false,
        error: "SMS indisponible pour ce pays — utilisez l'inscription par email.",
        sms_unavailable: true,
      });
      return;
    }

    res.json({ success: true, phone: normalized });
  } catch (err: any) {
    logger.error(`[phone-signup-send] ${err?.message || err}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

export default router;
