/**
 * 📞 CRÉATION DE COMPTE AUTH AVEC TÉLÉPHONE COMME IDENTIFIANT
 *
 * Objectif : un utilisateur créé par un agent/staff (email + téléphone + mot de passe) doit
 * pouvoir se connecter avec son EMAIL **OU** son TÉLÉPHONE + mot de passe. Supabase supporte
 * le téléphone comme identifiant natif dès lors que le compte a `phone` + `phone_confirm:true`
 * (vérifié en prod : `signInWithPassword({phone, password})` fonctionne SANS provider SMS
 * Supabase actif, car aucun SMS n'est émis pour un login par mot de passe).
 *
 * DÉGRADATION DOUBLON (jamais d'échec de création) : si le numéro est DÉJÀ lié à un autre
 * compte auth (« phone already registered »), on NE échoue PAS la création — on recrée le
 * compte SANS le champ `phone` auth (le téléphone reste en métadonnées + profil) et on renvoie
 * `phoneLoginAvailable:false` + un message clair. La connexion se fera alors par email.
 */
import type { User } from '@supabase/supabase-js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { formatPhoneIntl } from './phoneFormat.js';

export interface CreateAuthUserWithPhoneParams {
  email: string;
  password: string;
  phone?: string | null;
  countryCode?: string;
  user_metadata?: Record<string, unknown>;
  email_confirm?: boolean;
}

export interface CreateAuthUserWithPhoneResult {
  user: User | null;
  /** Erreur NON liée au doublon téléphone (email déjà pris, etc.) — l'appelant la gère. */
  error: { message?: string; code?: string; status?: number } | null;
  /** true = le login par téléphone est disponible ; false = email uniquement (doublon numéro). */
  phoneLoginAvailable: boolean;
  /** Message utilisateur si le login téléphone est indisponible (doublon numéro). */
  phoneMessage?: string;
  /** Numéro E.164 effectivement utilisé (ou tenté), pour info/log. */
  phoneE164?: string;
}

/** Détecte une erreur « numéro déjà enregistré » (le message Supabase varie selon les versions). */
function isPhoneDuplicateError(error: { message?: string; code?: string } | null): boolean {
  if (!error) return false;
  if (error.code === 'phone_exists') return true;
  const msg = String(error.message || '').toLowerCase();
  return msg.includes('phone') && /(already|registered|exists|taken|duplicate|been)/.test(msg);
}

/**
 * Crée un compte auth avec le téléphone comme identifiant (phone + phone_confirm), avec
 * dégradation gracieuse en email-only si le numéro est déjà pris. Voir l'entête du fichier.
 */
export async function createAuthUserWithPhone(
  params: CreateAuthUserWithPhoneParams,
): Promise<CreateAuthUserWithPhoneResult> {
  const { email, password, phone, countryCode, user_metadata = {}, email_confirm = true } = params;
  const rawPhone = String(phone || '').trim();
  const e164 = rawPhone ? formatPhoneIntl(rawPhone, countryCode) : undefined;

  // Cas 1 — téléphone fourni : tenter AVEC le téléphone comme identifiant.
  if (e164) {
    const { data, error } = await supabaseAdmin.auth.admin.createUser({
      email, password, email_confirm, phone: e164, phone_confirm: true, user_metadata,
    });
    if (!error && data?.user) {
      return { user: data.user, error: null, phoneLoginAvailable: true, phoneE164: e164 };
    }
    // Doublon téléphone → dégrader en email-only (NE PAS échouer la création).
    if (isPhoneDuplicateError(error)) {
      logger.warn(`[authPhone] numéro ${e164} déjà lié à un autre compte → création email-only (${error?.message})`);
      const { data: d2, error: e2 } = await supabaseAdmin.auth.admin.createUser({
        email, password, email_confirm, user_metadata,
      });
      if (e2 || !d2?.user) return { user: null, error: e2 ?? { message: 'Création compte échouée' }, phoneLoginAvailable: false, phoneE164: e164 };
      return {
        user: d2.user, error: null, phoneLoginAvailable: false, phoneE164: e164,
        phoneMessage: 'Ce numéro est déjà lié à un autre compte — connexion par email uniquement.',
      };
    }
    // Autre erreur (email déjà pris, mot de passe faible, …) → remonter telle quelle.
    return { user: null, error: error ?? { message: 'Création compte échouée' }, phoneLoginAvailable: false, phoneE164: e164 };
  }

  // Cas 2 — pas de téléphone : création email-only classique.
  const { data, error } = await supabaseAdmin.auth.admin.createUser({ email, password, email_confirm, user_metadata });
  return { user: data?.user ?? null, error: error ?? null, phoneLoginAvailable: false };
}
