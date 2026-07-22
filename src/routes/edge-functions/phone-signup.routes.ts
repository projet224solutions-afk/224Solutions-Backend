/**
 * EDGE COMPAT — phone-signup-send + phone-signup-verify (inscription par téléphone).
 *
 * RÈGLE UNIVERSELLE (décision PDG) : l'OTP d'inscription part par NOTRE passerelle SMS
 * (`sendSms` → smsGateway : ordre des fournisseurs PAR PAYS configuré en base, Orange
 * prioritaire +224). Le VERIFY crée désormais le compte CÔTÉ NODE (plus d'Edge Supabase) :
 * compte + profil + wallet (devise du pays via triggers DB), atomique côté base.
 *
 * Durcissements :
 *  - rate-limit 3 demandes / 15 min PAR NUMÉRO (journal sms_send_log, multi-instance)
 *    et 3 / 15 min PAR IP (routeRateLimit fail-open) ;
 *  - ANTI-ÉNUMÉRATION : réponse HTTP générique identique que le numéro existe ou non
 *    (le VRAI propriétaire reçoit un SMS « vous avez déjà un compte », l'attaquant ne voit rien) ;
 *  - repli email honnête si aucun fournisseur ne couvre le pays (`sms_unavailable`) ;
 *  - code 6 chiffres, validité 10 min, 3 tentatives, usage unique.
 *
 * Routes PUBLIQUES (utilisateur pas encore créé) → déclarées dans isPublicEdgePath (index.ts).
 */
import { Router, Request, Response } from 'express';
import { supabaseAdmin } from '../../config/supabase.js';
import { logger } from '../../config/logger.js';
import { sendSms } from '../../services/sms.service.js';
import { recentSendCount } from '../../services/sms/smsGateway.js';
import { routeRateLimit } from '../../middlewares/routeRateLimiter.js';

const router = Router();

const MAX_VERIFY_ATTEMPTS = 3;

// 3 demandes / 15 min / IP — fail-open (repli mémoire) : un limiteur ne bloque jamais tout.
const otpRequestIpLimit = routeRateLimit({
  maxRequests: 3, windowSeconds: 900, keyPrefix: 'phone-otp-ip', perUser: false, perIp: true, failClosed: false,
});

/** Normalise en E.164 (le front envoie déjà de l'E.164 ; repli GN uniquement sur 9 chiffres nus). */
function normalizePhone(raw: string): string {
  const clean = String(raw || '').trim().replace(/[\s\-().]/g, '');
  const digits = clean.replace(/[^\d]/g, '');
  if (clean.startsWith('+')) return clean;
  if (digits.startsWith('00') && digits.length >= 12) return '+' + digits.slice(2);
  if (digits.length === 9) return '+224' + digits; // repli GN (le front envoie normalement l'indicatif)
  return '+' + digits;
}

/** Réponse générique UNIQUE (anti-énumération) — identique que le numéro existe ou non. */
function genericSent(res: Response, phone: string): void {
  res.json({ success: true, phone });
}

router.post('/phone-signup-send', otpRequestIpLimit, async (req: Request, res: Response): Promise<void> => {
  try {
    const { phone, country_code } = req.body || {};
    if (!phone) { res.status(400).json({ success: false, error: 'Numéro requis' }); return; }

    const normalized = normalizePhone(String(phone));
    const digits = normalized.replace(/[^\d]/g, '');
    const iso = typeof country_code === 'string' && country_code.length >= 2 ? country_code.toUpperCase() : undefined;

    // Rate-limit PAR NUMÉRO : 3 envois signup / 15 min (compté sur le journal passerelle).
    if ((await recentSendCount(normalized, 'signup')) >= 3) {
      res.status(429).json({ success: false, error: 'Trop de demandes pour ce numéro. Réessayez dans quelques minutes.', error_code: 'RATE_LIMITED' });
      return;
    }

    // Variantes (dont le format espacé « +224 624… » stocké à l'inscription email).
    const spaceVariants: string[] = [];
    for (let codeLen = 1; codeLen <= 4; codeLen++) {
      if (digits.length > codeLen) spaceVariants.push('+' + digits.slice(0, codeLen) + ' ' + digits.slice(codeLen));
    }
    const variants = [...new Set([normalized, '+' + digits, digits, ...spaceVariants])];

    // ANTI-ÉNUMÉRATION : si le numéro a déjà un compte, on répond EXACTEMENT comme si un code
    // partait — et on prévient le vrai propriétaire par SMS (lui seul le voit).
    const { data: existing } = await supabaseAdmin.from('profiles').select('id').in('phone', variants).maybeSingle();
    if (existing) {
      sendSms(normalized, '224Solutions : un compte existe déjà avec ce numéro. Connectez-vous (ou « Mot de passe oublié »). Si ce n\'était pas vous, ignorez ce message.', iso, 'signup')
        .catch(() => { /* non bloquant */ });
      genericSent(res, normalized);
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

    // Envoi via LA passerelle (ordre des fournisseurs par pays configuré en base).
    const message = `224Solutions - Code d'inscription : ${otp}\nValable 10 minutes.`;
    const sent = await sendSms(normalized, message, iso, 'signup');
    if (!sent.ok) {
      // REPLI HONNÊTE : jamais un écran qui prétend avoir envoyé un code qui ne partira pas.
      logger.warn(`[phone-signup-send] SMS échec ${normalized.slice(0, 6)}*** (${iso || 'auto'}): ${sent.error}`);
      res.status(502).json({
        success: false,
        error: "SMS indisponible pour ce pays — utilisez l'inscription par email.",
        sms_unavailable: true,
      });
      return;
    }

    genericSent(res, normalized);
  } catch (err: any) {
    logger.error(`[phone-signup-send] ${err?.message || err}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

/**
 * VERIFY — vérifie l'OTP et crée le compte CÔTÉ NODE (remplace l'Edge Function Supabase).
 * Même contrat de réponse que l'Edge (le front est inchangé). Le profil + wallet (devise du
 * pays) sont créés par les triggers DB (handle_new_user + wallet_set_country_currency) dans
 * la même transaction que le compte → atomique : tout ou rien.
 */
router.post('/phone-signup-verify', async (req: Request, res: Response): Promise<void> => {
  try {
    const {
      phone, otp, password,
      firstName, lastName, role,
      city, country,
      businessName, serviceType, customId,
    } = req.body || {};

    if (!phone || !otp || !password || !firstName || !lastName || !role) {
      res.status(400).json({ success: false, error: 'Données incomplètes' });
      return;
    }
    const normalized = normalizePhone(String(phone));

    // 1) OTP exact, non vérifié, du bon type
    const { data: otpRecord, error: otpError } = await supabaseAdmin
      .from('auth_otp_codes')
      .select('*')
      .eq('identifier', normalized)
      .eq('otp_code', String(otp))
      .eq('verified', false)
      .eq('user_type', 'phone_signup')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (otpError) {
      logger.error(`[phone-signup-verify] DB: ${otpError.message}`);
      res.status(500).json({ success: false, error: 'Erreur serveur' });
      return;
    }

    if (!otpRecord) {
      // Mauvais code → incrémenter les tentatives sur le code actif (3 max, usage unique)
      const { data: existing } = await supabaseAdmin
        .from('auth_otp_codes')
        .select('id, attempts')
        .eq('identifier', normalized)
        .eq('verified', false)
        .eq('user_type', 'phone_signup')
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (existing) {
        const newAttempts = (existing.attempts || 0) + 1;
        await supabaseAdmin.from('auth_otp_codes').update({ attempts: newAttempts }).eq('id', existing.id);
        if (newAttempts >= MAX_VERIFY_ATTEMPTS) {
          await supabaseAdmin.from('auth_otp_codes').delete().eq('id', existing.id); // usage unique : brûlé
          res.status(429).json({ success: false, error: 'Trop de tentatives. Demandez un nouveau code.', locked: true });
          return;
        }
        res.status(401).json({ success: false, error: 'Code incorrect', attempts_remaining: MAX_VERIFY_ATTEMPTS - newAttempts });
        return;
      }
      res.status(401).json({ success: false, error: 'Code invalide ou expiré' });
      return;
    }

    // 2) Expiration
    if (new Date(otpRecord.expires_at) < new Date()) {
      res.status(401).json({ success: false, error: 'Code expiré. Demandez un nouveau code.' });
      return;
    }

    // 3) Marquer vérifié (usage unique)
    await supabaseAdmin
      .from('auth_otp_codes')
      .update({ verified: true, verified_at: new Date().toISOString() })
      .eq('id', otpRecord.id);

    // 4) Créer le compte (admin) — email proxy interne, invisible pour l'utilisateur.
    //    Format IDENTIQUE à l'historique (@phone.224solutions.net) : des comptes existent déjà.
    const digits = normalized.replace(/[^\d]/g, '');
    const proxyEmail = `${digits}@phone.224solutions.net`;

    const { data: newUser, error: createError } = await supabaseAdmin.auth.admin.createUser({
      email: proxyEmail,
      phone: normalized,
      password: String(password),
      phone_confirm: true,
      email_confirm: true,
      user_metadata: {
        first_name: firstName,
        last_name: lastName,
        role,
        phone: normalized,
        country: country || '',
        city: city || '',
        custom_id: customId || null,
        business_name: businessName || null,
        service_type: serviceType || null,
      },
    });

    if (createError) {
      logger.error(`[phone-signup-verify] création: ${createError.message}`);
      if (/already (been )?registered|Email address/i.test(createError.message || '')) {
        res.status(409).json({ success: false, error: 'Ce numéro est déjà associé à un compte.', alreadyExists: true });
        return;
      }
      res.status(500).json({ success: false, error: 'Erreur lors de la création du compte' });
      return;
    }

    logger.info(`[phone-signup-verify] compte créé: ${newUser.user.id}`);
    res.json({ success: true, userId: newUser.user.id, email: proxyEmail });
  } catch (err: any) {
    logger.error(`[phone-signup-verify] ${err?.message || err}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

/**
 * RESET / CONNEXION PAR TÉLÉPHONE — envoi d'OTP (remplace l'Edge `phone-send-otp` :
 * recherche par égalité stricte de formats + Twilio direct → c'était LA cause du
 * « Ce numéro n'est lié à aucun compte » alors que le compte existe, et un envoi HORS passerelle).
 *
 * Recherche CANONIQUE : resolve_user_id_by_phone (normalisation E.164 avec pays du contexte,
 * égalité sur profiles.phone_e164 — fini les « 9 derniers chiffres »). Envoi via LA passerelle
 * (usage 'reset'). Réponses HONNÊTES : found:false (vrai « aucun compte ») distinct de
 * sms_unavailable (panne d'envoi) — jamais l'un déguisé en l'autre.
 */
router.post('/phone-send-otp', otpRequestIpLimit, async (req: Request, res: Response): Promise<void> => {
  try {
    const { phone, country_code } = req.body || {};
    if (!phone) { res.status(400).json({ success: false, error: 'Numéro requis' }); return; }
    const iso = typeof country_code === 'string' && country_code.length >= 2 ? country_code.toUpperCase() : undefined;

    // Recherche canonique (tolérante à la saisie : local / 0 / espaces / 00 / +E.164)
    const { data: userId, error: rpcErr } = await supabaseAdmin.rpc('resolve_user_id_by_phone', {
      p_phone: String(phone), p_country: iso || null,
    });
    if (rpcErr) {
      logger.error(`[phone-send-otp] resolve: ${rpcErr.message}`);
      res.status(500).json({ success: false, error: 'Erreur serveur' });
      return;
    }
    if (!userId) {
      // VRAI « aucun compte » — le front guide vers l'email (jamais un mensonge de panne).
      res.json({ success: false, found: false });
      return;
    }

    const { data: profile } = await supabaseAdmin.from('profiles')
      .select('id, phone, phone_e164').eq('id', userId as string).single();
    const storedPhone: string = (profile?.phone_e164 || profile?.phone || String(phone)).trim();

    // Rate-limit PAR NUMÉRO : 3 / 15 min (journal passerelle, multi-instance)
    if ((await recentSendCount(storedPhone, 'reset')) >= 3) {
      res.status(429).json({ success: false, error: 'Trop de demandes pour ce numéro. Réessayez dans quelques minutes.', error_code: 'RATE_LIMITED' });
      return;
    }

    const otp = Math.floor(100000 + Math.random() * 900000).toString();
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000);

    await supabaseAdmin.from('auth_otp_codes').delete()
      .eq('identifier', storedPhone).eq('user_type', 'phone_login').eq('verified', false);

    const { error: insertError } = await supabaseAdmin.from('auth_otp_codes').insert({
      user_type: 'phone_login', // contrat historique — phone-verify-otp (Edge) lit ce type
      user_id: userId as string,
      identifier: storedPhone,
      otp_code: otp,
      expires_at: expiresAt.toISOString(),
      verified: false,
      attempts: 0,
      created_at: new Date().toISOString(),
    });
    if (insertError) {
      logger.error(`[phone-send-otp] OTP insert: ${insertError.message}`);
      res.status(500).json({ success: false, error: 'Erreur serveur' });
      return;
    }

    const sent = await sendSms(storedPhone, `224Solutions - Votre code de vérification : ${otp}\nValable 10 minutes.`, iso, 'reset');
    if (!sent.ok) {
      logger.warn(`[phone-send-otp] SMS échec ${storedPhone.slice(0, 6)}***: ${sent.error}`);
      res.status(502).json({
        success: false,
        error: "L'envoi par SMS est momentanément indisponible. Réessayez, ou utilisez votre adresse email.",
        sms_unavailable: true,
        found: true, // le compte EXISTE — jamais « aucun compte » pour une panne d'envoi
      });
      return;
    }

    res.json({ success: true, found: true, phone: storedPhone });
  } catch (err: any) {
    logger.error(`[phone-send-otp] ${err?.message || err}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

export default router;
