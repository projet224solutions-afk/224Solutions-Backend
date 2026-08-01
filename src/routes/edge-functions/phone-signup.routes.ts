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
import { randomInt } from 'node:crypto';
import { Router, Request, Response } from 'express';
import { supabaseAdmin } from '../../config/supabase.js';
import { logger } from '../../config/logger.js';
import { sendSms } from '../../services/sms.service.js';
import { sendOtpWhatsApp } from '../../services/whatsappOtp.service.js';
import { recentSendCount, canDeliverTo, dailySmsCount, alertSmsDailyCap } from '../../services/sms/smsGateway.js';
import { routeRateLimit } from '../../middlewares/routeRateLimiter.js';

const router = Router();

const MAX_VERIFY_ATTEMPTS = 3;

// Plafond GLOBAL de SMS OTP par jour (inscription + reset) — la VRAIE protection anti-abus de
// coût : un attaquant visant des centaines de numéros DIFFÉRENTS n'est arrêté ni par la limite
// par numéro ni par celle par IP. Réglable via SMS_DAILY_OTP_CAP (défaut 1000). Dépassement =
// envois OTP publics suspendus + alerte Thierno (system_alerts).
const SMS_DAILY_OTP_CAP = parseInt(process.env.SMS_DAILY_OTP_CAP || '', 10) || 1000;

// Limite par IP RELEVÉE à 25 / 15 min (les opérateurs mobiles guinéens partagent une même IP
// publique entre des milliers d'abonnés : 3/IP bloquait de vrais commerçants). Elle ne sert plus
// qu'à freiner un script — la vraie protection par numéro (recentSendCount, lue en base) reste à 3.
// fail-open : un limiteur ne bloque jamais tout (surtout pas fermé si Redis tousse).
const otpRequestIpLimit = routeRateLimit({
  maxRequests: 25, windowSeconds: 900, keyPrefix: 'phone-otp-ip', perUser: false, perIp: true, failClosed: false,
});

/** Plafond global journalier dépassé ? (compte les SMS OTP réussis du jour, alerte au dépassement.) */
async function otpDailyCapExceeded(): Promise<boolean> {
  const n = await dailySmsCount(['signup', 'reset']);
  if (n >= SMS_DAILY_OTP_CAP) {
    await alertSmsDailyCap(n, SMS_DAILY_OTP_CAP);
    return true;
  }
  return false;
}

/**
 * Normalise en E.164 via LA fonction canonique en base `normalize_phone(p, default_country)` —
 * EXACTEMENT le même normaliseur que la connexion (`resolve_user_id_by_phone` s'appuie dessus),
 * donc plus aucune divergence inscription/connexion. L'ISO du pays (envoyé par le front dans
 * `country_code`) est passé en `default_country` → un numéro LOCAL à 9 chiffres est rattaché au
 * BON pays (SN→+221, ML→+223, CI→+225…), plus jamais forcé en GN. Repli GN UNIQUEMENT quand aucun
 * ISO n'est fourni ET que le numéro est local (journalisé comme anomalie). Ne PAS créer un 3e
 * normaliseur : cette fonction délègue.
 */
async function normalizePhone(raw: string, iso?: string): Promise<string> {
  const input = String(raw || '').trim();
  if (!iso && !input.startsWith('+')) {
    logger.warn(`[phone] numéro local SANS country_code → repli défaut GN pour ${input.slice(0, 4)}*** (le client devrait envoyer l'ISO du pays).`);
  }
  const { data, error } = await supabaseAdmin.rpc('normalize_phone', { p: input, default_country: iso || 'GN' });
  if (!error && typeof data === 'string' && data) return data as string;

  // Repli (RPC indisponible) : cas NON AMBIGUS seulement — on ne PRÉSUME jamais un pays pour un
  // numéro local si un ISO ≠ GN est fourni (c'est précisément le bug qu'on corrige).
  const clean = input.replace(/[\s\-().]/g, '');
  const digits = clean.replace(/[^\d]/g, '');
  if (clean.startsWith('+')) return clean;
  if (digits.startsWith('00') && digits.length >= 11) return '+' + digits.slice(2);
  if (digits.length === 9 && (!iso || iso === 'GN')) return '+224' + digits;
  logger.error(`[phone] normalize_phone indisponible et repli local impossible (iso=${iso || 'aucun'}) : ${error?.message || 'no data'}`);
  throw new Error('phone_normalization_unavailable');
}

/** Réponse générique UNIQUE (anti-énumération) — identique que le numéro existe ou non. */
function genericSent(res: Response, phone: string): void {
  res.json({ success: true, phone });
}

router.post('/phone-signup-send', otpRequestIpLimit, async (req: Request, res: Response): Promise<void> => {
  try {
    const { phone, country_code } = req.body || {};
    if (!phone) { res.status(400).json({ success: false, error: 'Numéro requis' }); return; }

    const iso = typeof country_code === 'string' && country_code.length >= 2 ? country_code.toUpperCase() : undefined;
    const normalized = await normalizePhone(String(phone), iso);

    // Rate-limit PAR NUMÉRO : 3 envois signup / 15 min (compté sur le journal passerelle).
    if ((await recentSendCount(normalized, 'signup')) >= 3) {
      res.status(429).json({ success: false, error: 'Trop de demandes pour ce numéro. Réessayez dans quelques minutes.', error_code: 'RATE_LIMITED' });
      return;
    }

    // PLAFOND GLOBAL journalier (anti-abus de coût) — gate AVANT tout envoi (OTP comme SMS
    // d'avertissement), pour ne pas révéler l'existence d'un compte via ce chemin. Alerte Thierno.
    if (await otpDailyCapExceeded()) {
      res.status(429).json({ success: false, error: 'Service momentanément indisponible, réessayez plus tard.', error_code: 'SMS_DAILY_CAP' });
      return;
    }

    // ANTI-ÉNUMÉRATION : existence par la forme CANONIQUE `phone_e164` (même définition que la
    // connexion) — fini les variantes fabriquées à la main. Erreur DB ⇒ 500, JAMAIS interprétée
    // comme « numéro libre ».
    const { data: existingRows, error: existErr } = await supabaseAdmin
      .from('profiles').select('id').eq('phone_e164', normalized).limit(1);
    if (existErr) {
      logger.error(`[phone-signup-send] contrôle existence: ${existErr.message}`);
      res.status(500).json({ success: false, error: 'Erreur serveur' });
      return;
    }
    if (existingRows && existingRows.length > 0) {
      // Numéro déjà pris : on répond EXACTEMENT comme si un code partait, et on prévient le VRAI
      // propriétaire par SMS (lui seul le voit).
      sendSms(normalized, '224Solutions : un compte existe déjà avec ce numéro. Connectez-vous (ou « Mot de passe oublié »). Si ce n\'était pas vous, ignorez ce message.', iso, 'signup')
        .catch(() => { /* non bloquant */ });
      genericSent(res, normalized);
      return;
    }

    const otp = String(randomInt(100000, 1000000)); // OTP cryptographique (jamais Math.random)
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

    // Envoi de l'OTP par WHATSAPP (canal téléphone actif — décision 01/08/2026). Le code part dans le
    // modèle d'authentification Meta (bouton « copier » natif). Le SMS est GELÉ ; le repli est l'EMAIL.
    const wa = await sendOtpWhatsApp(normalized, otp);
    if (!wa.success) {
      logger.warn(`[phone-signup-send] WhatsApp ${wa.error_code} pour ${normalized.slice(0, 6)}***`);
      if (wa.error_code === 'WHATSAPP_NO_ACCOUNT') {
        // Numéro sans WhatsApp → bascule email (le numéro pourra être vérifié plus tard depuis le profil).
        res.status(400).json({ success: false, error: "Ce numéro n'a pas WhatsApp. Inscrivez-vous avec votre adresse email.", error_code: 'NO_WHATSAPP', use_email: true });
        return;
      }
      if (wa.error_code === 'WHATSAPP_NOT_CONFIGURED') {
        // Compte Meta pas encore approuvé → fail-closed honnête (pas de faux « envoyé »).
        res.status(503).json({ success: false, error: "L'inscription par téléphone (WhatsApp) sera bientôt disponible — utilisez votre adresse email.", error_code: 'WHATSAPP_NOT_CONFIGURED', use_email: true });
        return;
      }
      // Token expiré / échec d'envoi → repli email honnête. AUCUN chemin ne tente le SMS.
      res.status(502).json({ success: false, error: "Envoi WhatsApp indisponible pour l'instant — utilisez l'inscription par email.", error_code: wa.error_code, use_email: true });
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
      city, country, country_code,
      businessName, serviceType, customId,
    } = req.body || {};

    if (!phone || !otp || !password || !firstName || !lastName || !role) {
      res.status(400).json({ success: false, error: 'Données incomplètes' });
      return;
    }
    // Même normaliseur canonique qu'à l'envoi : le front renvoie l'E.164 (idempotent), et si un
    // country_code est fourni il rattache un éventuel numéro local au bon pays → l'identifiant
    // recherché est IDENTIQUE à celui stocké par /phone-signup-send.
    const isoVerify = typeof country_code === 'string' && country_code.length >= 2 ? country_code.toUpperCase() : undefined;
    const normalized = await normalizePhone(String(phone), isoVerify);

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
    const normalized = await normalizePhone(String(phone), iso);

    // Rate-limit PAR NUMÉRO **avant** toute résolution (le 429 ne doit pas être un oracle
    // d'existence : il se déclenche à l'identique que le compte existe ou non).
    if ((await recentSendCount(normalized, 'reset')) >= 3) {
      res.status(429).json({ success: false, error: 'Trop de demandes pour ce numéro. Réessayez dans quelques minutes.', error_code: 'RATE_LIMITED' });
      return;
    }

    // PLAFOND GLOBAL journalier (anti-abus de coût) — état GLOBAL, donc pas un oracle d'existence.
    if (await otpDailyCapExceeded()) {
      res.status(429).json({ success: false, error: 'Service momentanément indisponible, réessayez plus tard.', error_code: 'SMS_DAILY_CAP' });
      return;
    }

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
      // ANTI-ÉNUMÉRATION (validé PDG) : réponse IDENTIQUE à un envoi réussi — l'existence
      // d'un compte n'est JAMAIS révélée. Seul le vrai propriétaire reçoit (ou non) un code.
      // On simule aussi la couverture pays pour ne pas créer d'oracle « 502 = compte existe ».
      if (!(await canDeliverTo(iso))) {
        res.status(502).json({
          success: false,
          error: "L'envoi par SMS est momentanément indisponible. Réessayez, ou utilisez votre adresse email.",
          sms_unavailable: true,
        });
        return;
      }
      res.json({ success: true, sent: true, phone: normalized });
      return;
    }

    const { data: profile } = await supabaseAdmin.from('profiles')
      .select('id, phone, phone_e164').eq('id', userId as string).single();
    const storedPhone: string = (profile?.phone_e164 || profile?.phone || normalized).trim();

    const otp = String(randomInt(100000, 1000000)); // OTP cryptographique (jamais Math.random)
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
      // Panne d'envoi HONNÊTE — même forme que la branche « inconnu + pays non couvert »
      // (aucun drapeau d'existence, l'anti-énumération reste étanche).
      logger.warn(`[phone-send-otp] SMS échec ${storedPhone.slice(0, 6)}***: ${sent.error}`);
      res.status(502).json({
        success: false,
        error: "L'envoi par SMS est momentanément indisponible. Réessayez, ou utilisez votre adresse email.",
        sms_unavailable: true,
      });
      return;
    }

    // Réponse générique — identique à la branche « aucun compte » (anti-énumération).
    res.json({ success: true, sent: true, phone: storedPhone });
  } catch (err: any) {
    logger.error(`[phone-send-otp] ${err?.message || err}`);
    res.status(500).json({ success: false, error: 'Erreur serveur' });
  }
});

export default router;
