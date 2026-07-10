/**
 * 👤 PROFILES ROUTES - Backend Node.js (service_role)
 *
 * Ferme la fuite d'isolation des profils (voir docs/AUDIT_PROFILES_ACCESS.md).
 * Après le DROP de la policy RLS `USING(true)` sur `public.profiles`, un utilisateur
 * `authenticated` ne voit plus QUE son propre profil. Toute lecture LÉGITIME d'un
 * profil TIERS passe désormais par ces endpoints (service_role → contourne la RLS),
 * qui :
 *   1. vérifient SERVEUR le lien légitime demandeur↔cible (course / commande / conversation) ;
 *   2. ne renvoient que des colonnes MINIMALES (jamais email, pièces, adresse — sauf contact
 *      téléphonique d'un tiers explicitement lié) ;
 *   3. journalisent les accès contact pour audit RGPD.
 *
 * Endpoints (montés sur /api/v2/profiles) :
 *   - GET  /:id/contact          → contact d'un tiers lié (nom + téléphone)
 *   - POST /display-names        → noms d'affichage en lot (sans PII)
 *   - GET  /resolve?identifier=  → résolution EXACTE d'un destinataire (0 ou 1, sans PII)
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';
import { ok, fail } from '../utils/apiResponse.js';
// @ts-ignore — middleware JS sans types
import { createRedisLimiter } from '../middlewares/rateLimiter.js';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PHONE_RE = /^\+?[\d\s().-]{7,}$/;
const PDG_ROLES = ['admin', 'pdg', 'ceo'];

/** Anti-énumération : limite la résolution de destinataire par IP. */
const resolveLimiter = createRedisLimiter({
  max: 40,
  windowSeconds: 60,
  keyPrefix: 'profiles-resolve',
  label: 'profiles-resolve',
  message: 'Trop de recherches. Réessayez dans une minute.',
});

function phoneVariants(raw: string): string[] {
  const compact = raw.replace(/[\s().-]/g, '');
  const digits = compact.replace(/[^\d]/g, '');
  const withPlus = digits ? `+${digits}` : '';
  const noPrefix = digits.startsWith('00') ? digits.slice(2) : digits;
  return Array.from(new Set([raw.trim(), compact, digits, withPlus, noPrefix].filter(Boolean)));
}

function composeFullName(p: any): string {
  return (
    String(p?.full_name || '').trim() ||
    `${String(p?.first_name || '').trim()} ${String(p?.last_name || '').trim()}`.trim() ||
    ''
  );
}

/** L'appelant est-il admin / PDG / CEO (profil ou pdg_management actif) ? */
async function isAdminOrPdg(user: AuthenticatedRequest['user']): Promise<boolean> {
  if (!user) return false;
  if (PDG_ROLES.includes(String(user.role || '').toLowerCase())) return true;
  const { data } = await supabaseAdmin
    .from('pdg_management')
    .select('id')
    .eq('user_id', user.id)
    .eq('is_active', true)
    .maybeSingle();
  return !!data;
}

/**
 * Existe-t-il un lien LÉGITIME demandeur↔cible autorisant la lecture du contact ?
 * Vérifié 100% côté serveur (service_role) — jamais depuis le client.
 *   - Course taxi (taxi_trips : driver_id/customer_id sont des user_id) dans les 2 sens
 *   - Course taxi (taxi_rides : customer_id=user, driver_id→taxi_drivers.user_id)
 *   - Livraison (deliveries : driver_id→profiles.id, client_id) dans les 2 sens
 *   - Commande (orders : customer_id ↔ vendors.user_id) dans les 2 sens
 *   - Conversation partagée (conversation_participants)
 */
async function hasLegitimateLink(callerId: string, targetId: string): Promise<boolean> {
  // 1. Course taxi (table live : taxi_trips, ids = user_id)
  try {
    const { data } = await supabaseAdmin
      .from('taxi_trips')
      .select('id')
      .or(
        `and(driver_id.eq.${callerId},customer_id.eq.${targetId}),` +
          `and(driver_id.eq.${targetId},customer_id.eq.${callerId})`,
      )
      .limit(1)
      .maybeSingle();
    if (data) return true;
  } catch { /* table absente → ignorer */ }

  // 2. Course taxi (taxi_rides : driver_id → taxi_drivers.id)
  try {
    // 2a. l'appelant est le CLIENT, la cible est le CHAUFFEUR
    const { data: targetDriver } = await supabaseAdmin
      .from('taxi_drivers').select('id').eq('user_id', targetId);
    const targetDriverIds = (targetDriver || []).map((d: any) => d.id);
    if (targetDriverIds.length) {
      const { data } = await supabaseAdmin
        .from('taxi_rides').select('id')
        .eq('customer_id', callerId).in('driver_id', targetDriverIds).limit(1).maybeSingle();
      if (data) return true;
    }
    // 2b. l'appelant est le CHAUFFEUR, la cible est le CLIENT
    const { data: callerDriver } = await supabaseAdmin
      .from('taxi_drivers').select('id').eq('user_id', callerId);
    const callerDriverIds = (callerDriver || []).map((d: any) => d.id);
    if (callerDriverIds.length) {
      const { data } = await supabaseAdmin
        .from('taxi_rides').select('id')
        .eq('customer_id', targetId).in('driver_id', callerDriverIds).limit(1).maybeSingle();
      if (data) return true;
    }
  } catch { /* table absente → ignorer */ }

  // 3. Livraison (deliveries : driver_id → profiles.id, client_id)
  try {
    const { data } = await supabaseAdmin
      .from('deliveries')
      .select('id')
      .or(
        `and(driver_id.eq.${callerId},client_id.eq.${targetId}),` +
          `and(driver_id.eq.${targetId},client_id.eq.${callerId})`,
      )
      .limit(1)
      .maybeSingle();
    if (data) return true;
  } catch { /* colonne client_id absente → ignorer */ }

  // 4. Commande (orders : customer_id ↔ vendors.user_id)
  try {
    const { data: vendorRows } = await supabaseAdmin
      .from('vendors').select('id, user_id').or(`user_id.eq.${callerId},user_id.eq.${targetId}`);
    const callerVendorIds = (vendorRows || []).filter((v: any) => v.user_id === callerId).map((v: any) => v.id);
    const targetVendorIds = (vendorRows || []).filter((v: any) => v.user_id === targetId).map((v: any) => v.id);
    // 4a. appelant = client, cible = vendeur
    if (targetVendorIds.length) {
      const { data } = await supabaseAdmin
        .from('orders').select('id')
        .eq('customer_id', callerId).in('vendor_id', targetVendorIds).limit(1).maybeSingle();
      if (data) return true;
    }
    // 4b. appelant = vendeur, cible = client
    if (callerVendorIds.length) {
      const { data } = await supabaseAdmin
        .from('orders').select('id')
        .eq('customer_id', targetId).in('vendor_id', callerVendorIds).limit(1).maybeSingle();
      if (data) return true;
    }
  } catch { /* table absente → ignorer */ }

  // 5. Conversation partagée
  try {
    const { data: callerConvs } = await supabaseAdmin
      .from('conversation_participants').select('conversation_id').eq('user_id', callerId);
    const convIds = (callerConvs || []).map((c: any) => c.conversation_id).filter(Boolean);
    if (convIds.length) {
      const { data } = await supabaseAdmin
        .from('conversation_participants').select('id')
        .eq('user_id', targetId).in('conversation_id', convIds).limit(1).maybeSingle();
      if (data) return true;
    }
  } catch { /* table absente → ignorer */ }

  return false;
}

/**
 * GET /api/v2/profiles/:id/contact
 * Contact d'un TIERS (nom + téléphone) SI ET SEULEMENT SI un lien légitime existe.
 * Colonnes minimales — jamais email, pièces, adresse. Accès journalisé (RGPD).
 */
router.get('/:id/contact', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const callerId = req.user!.id;
    const targetId = String(req.params.id || '').trim();

    if (!UUID_RE.test(targetId)) {
      return fail(res, 400, 'Identifiant invalide', 'INVALID_ID');
    }

    // Autorisation : soi-même, admin/PDG, ou lien vérifié serveur.
    let authorized = callerId === targetId;
    let reason = 'self';
    if (!authorized && (await isAdminOrPdg(req.user))) {
      authorized = true;
      reason = 'admin';
    }
    if (!authorized && (await hasLegitimateLink(callerId, targetId))) {
      authorized = true;
      reason = 'link';
    }

    if (!authorized) {
      logger.warn(`[profiles/contact] refus ${callerId} → ${targetId} (aucun lien)`);
      return fail(res, 403, "Vous n'êtes pas autorisé à voir ce contact", 'CONTACT_FORBIDDEN');
    }

    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('id, first_name, last_name, full_name, avatar_url, phone')
      .eq('id', targetId)
      .maybeSingle();

    if (!profile) {
      return fail(res, 404, 'Profil introuvable', 'PROFILE_NOT_FOUND');
    }

    // Journalisation RGPD (best-effort, non bloquant) — sauf lecture de son propre profil.
    if (reason !== 'self') {
      try {
        await supabaseAdmin.from('audit_logs').insert({
          actor_id: callerId,
          action: 'PROFILE_CONTACT_ACCESS',
          target_type: 'user',
          target_id: targetId,
        });
      } catch (e: any) {
        // Non bloquant (ne jamais bloquer le contact), mais l'échec d'une trace RGPD
        // doit remonter en log serveur — jamais avalé silencieusement.
        logger.warn(`[profiles/contact] audit insert failed: ${e?.message || e}`);
      }
    }

    const p = profile as any;
    return ok(res, {
      id: p.id,
      first_name: p.first_name || null,
      last_name: p.last_name || null,
      full_name: composeFullName(p) || null,
      avatar_url: p.avatar_url || null,
      phone: p.phone || null,
    });
  } catch (error: any) {
    logger.error(`[profiles/contact] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de la récupération du contact');
  }
});

/**
 * POST /api/v2/profiles/display-names
 * Noms d'affichage en lot (historique tx, listes, avis, langue de traduction).
 * SANS PII (jamais email/phone). Authentifié suffit (noms = semi-publics).
 * Body : { ids: string[] } (plafonné à 200).
 */
router.post('/display-names', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const rawIds = Array.isArray(req.body?.ids) ? req.body.ids : [];
    const ids = Array.from(
      new Set(rawIds.map((x: unknown) => String(x || '').trim()).filter((x: string) => UUID_RE.test(x))),
    ).slice(0, 200);

    if (ids.length === 0) {
      return ok(res, []);
    }

    const { data: profiles } = await supabaseAdmin
      .from('profiles')
      .select('id, first_name, last_name, full_name, avatar_url, public_id, preferred_language')
      .in('id', ids);

    const result = (profiles || []).map((p: any) => ({
      id: p.id,
      full_name: composeFullName(p) || null,
      avatar_url: p.avatar_url || null,
      public_id: p.public_id || null,
      preferred_language: p.preferred_language || null,
    }));

    return ok(res, result);
  } catch (error: any) {
    logger.error(`[profiles/display-names] ${error?.message}`);
    return fail(res, 500, "Erreur lors de la récupération des noms d'affichage");
  }
});

/**
 * Résout un identifiant EXACT vers un user_id (pas de ILIKE, pas de liste).
 * Ordre : UUID → user_ids.custom_id → profiles.public_id/custom_id → email exact → téléphone exact.
 */
async function resolveExactUserId(identifier: string): Promise<string | null> {
  const raw = String(identifier || '').trim();
  if (!raw) return null;

  if (UUID_RE.test(raw)) {
    const { data } = await supabaseAdmin.from('profiles').select('id').eq('id', raw).maybeSingle();
    return data?.id ?? null;
  }

  const upper = raw.toUpperCase();

  // custom_id (ex: CLT0005) → user_ids
  const { data: uid } = await supabaseAdmin
    .from('user_ids').select('user_id').eq('custom_id', upper).maybeSingle();
  if (uid?.user_id) {
    const { data } = await supabaseAdmin.from('profiles').select('id').eq('id', uid.user_id).maybeSingle();
    if (data?.id) return data.id;
  }

  // public_id / custom_id exact sur profiles.
  // 🔒 Anti-injection PostgREST : on ne compose JAMAIS un filtre .or() avec l'entrée brute
  // (une virgule/point/parenthèse injecterait des conditions). Allowlist STRICT du code +
  // deux .eq() paramétrés (les valeurs .eq sont échappées par le client Supabase).
  if (/^[A-Za-z0-9_-]{1,32}$/.test(upper)) {
    const { data: byPublicId } = await supabaseAdmin
      .from('profiles').select('id').eq('public_id', upper).limit(1).maybeSingle();
    if (byPublicId?.id) return byPublicId.id;
    const { data: byCustomId } = await supabaseAdmin
      .from('profiles').select('id').eq('custom_id', upper).limit(1).maybeSingle();
    if (byCustomId?.id) return byCustomId.id;
  }

  // email exact
  if (raw.includes('@')) {
    const { data: byEmail } = await supabaseAdmin
      .from('profiles').select('id').eq('email', raw.toLowerCase()).maybeSingle();
    if (byEmail?.id) return byEmail.id;
  }

  // téléphone exact (variantes de formatage, jamais ILIKE)
  if (PHONE_RE.test(raw)) {
    try {
      const { data: rpcId, error: rpcErr } = await supabaseAdmin
        .rpc('resolve_user_id_by_phone', { p_phone: raw });
      if (!rpcErr && rpcId) return rpcId as string;
    } catch { /* RPC absente → repli variantes */ }
    const filter = phoneVariants(raw).map((v) => `phone.eq.${v}`).join(',');
    const { data: byPhone } = await supabaseAdmin
      .from('profiles').select('id').or(filter).limit(1).maybeSingle();
    if (byPhone?.id) return byPhone.id;
  }

  return null;
}

/**
 * GET /api/v2/profiles/resolve?identifier=
 * Résolution EXACTE d'un destinataire (transfert d'argent, messagerie).
 * Renvoie 0 ou 1 correspondance : { id, full_name, public_id, avatar_url } — JAMAIS email/phone,
 * JAMAIS de liste, JAMAIS de recherche floue (anti-énumération). Rate-limité par IP.
 */
router.get('/resolve', resolveLimiter, verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const identifier = String(req.query.identifier || '').trim();
    if (!identifier) {
      return fail(res, 400, 'Identifiant requis', 'IDENTIFIER_REQUIRED');
    }

    const userId = await resolveExactUserId(identifier);
    if (!userId) {
      // Pas d'erreur : simplement aucune correspondance (anti-énumération : même forme de réponse).
      return ok(res, null);
    }

    const { data: profile } = await supabaseAdmin
      .from('profiles')
      .select('id, first_name, last_name, full_name, public_id, avatar_url')
      .eq('id', userId)
      .maybeSingle();

    if (!profile) {
      return ok(res, null);
    }

    const p = profile as any;
    return ok(res, {
      id: p.id,
      full_name: composeFullName(p) || null,
      public_id: p.public_id || null,
      avatar_url: p.avatar_url || null,
    });
  } catch (error: any) {
    logger.error(`[profiles/resolve] ${error?.message}`);
    return fail(res, 500, 'Erreur lors de la résolution du destinataire');
  }
});

export default router;
