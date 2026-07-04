/**
 * 🚕 TAXI ROUTES - Backend Node.js
 *
 * Résolution sécurisée d'une cible de suivi (client) pour le taxi-moto.
 * Service role → peut lire profiles + user_ids (RLS bloqué côté frontend).
 *
 * Un compte SUPPRIMÉ n'a plus de ligne profiles/user_ids → la résolution échoue
 * → le chauffeur ne peut plus le retrouver.
 *
 * Endpoint (monté sur /api/v2/taxi) :
 *   - GET /resolve-target?q=<ID | UUID | custom_id | téléphone | email>
 */

import { Router, Response } from 'express';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PHONE_RE = /^\+?[\d\s().-]{7,}$/;

function phoneVariants(raw: string): string[] {
  const compact = raw.replace(/[\s().-]/g, '');
  const digits = compact.replace(/[^\d]/g, '');
  const withPlus = digits ? `+${digits}` : '';
  const noPrefix = digits.startsWith('00') ? digits.slice(2) : digits;
  return Array.from(new Set([raw.trim(), compact, digits, withPlus, noPrefix].filter(Boolean)));
}

/** Extrait un id depuis un lien …/track/<id> ou renvoie la saisie telle quelle. */
function extractRaw(input: string): string {
  const trimmed = String(input || '').trim();
  const uuid = trimmed.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i);
  if (uuid) return uuid[0];
  const fromPath = trimmed.match(/\/track\/([^/?#\s]+)/i);
  if (fromPath) return decodeURIComponent(fromPath[1]);
  return trimmed;
}

/**
 * Résout un identifiant vers un user_id ACTIF (présent dans profiles).
 * Retourne null si aucun compte actif (inexistant ou supprimé).
 */
async function findActiveUserId(raw: string): Promise<string | null> {
  // 1. UUID → profiles.id
  if (UUID_RE.test(raw)) {
    const { data } = await supabaseAdmin.from('profiles').select('id').eq('id', raw).maybeSingle();
    return data?.id ?? null;
  }

  // 2. custom_id (ex: CLT0005) → user_ids.custom_id → user_id → vérifier profiles
  const { data: uid } = await supabaseAdmin
    .from('user_ids').select('user_id').eq('custom_id', raw.toUpperCase()).maybeSingle();
  if (uid?.user_id) {
    const { data } = await supabaseAdmin.from('profiles').select('id').eq('id', uid.user_id).maybeSingle();
    if (data?.id) return data.id;
  }

  // 3. public_id → profiles.public_id
  const { data: byPublic } = await supabaseAdmin
    .from('profiles').select('id')
    .or(`public_id.eq.${raw},public_id.eq.${raw.toUpperCase()}`)
    .limit(1).maybeSingle();
  if (byPublic?.id) return byPublic.id;

  // 4. téléphone → profiles.phone (robuste : 9 derniers chiffres via RPC)
  if (PHONE_RE.test(raw)) {
    // 4a. Match robuste (ignore espaces/indicatif) — gère les formats incohérents
    try {
      const { data: rpcId, error: rpcErr } = await supabaseAdmin
        .rpc('resolve_user_id_by_phone', { p_phone: raw });
      if (!rpcErr && rpcId) return rpcId as string;
    } catch { /* RPC pas encore appliquée → repli variantes */ }

    // 4b. Repli : variantes exactes (si la RPC n'est pas disponible)
    const filter = phoneVariants(raw).map((v) => `phone.eq.${v}`).join(',');
    const { data: byPhone } = await supabaseAdmin
      .from('profiles').select('id').or(filter).limit(1).maybeSingle();
    if (byPhone?.id) return byPhone.id;
  }

  // 5. email → profiles.email
  if (raw.includes('@')) {
    const { data: byEmail } = await supabaseAdmin
      .from('profiles').select('id').eq('email', raw.toLowerCase()).maybeSingle();
    if (byEmail?.id) return byEmail.id;
  }

  return null;
}

/**
 * GET /api/v2/taxi/resolve-target?q=...
 * Résout la cible de suivi. status 'active' → le chauffeur peut suivre ;
 * status 'not_found' → compte inexistant ou supprimé (le chauffeur ne le retrouve pas).
 */
router.get('/resolve-target', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const q = extractRaw(String(req.query.q || ''));
    if (!q) {
      res.status(400).json({ success: false, error: 'q requis' });
      return;
    }

    const userId = await findActiveUserId(q);

    if (!userId) {
      res.json({ success: true, status: 'not_found' });
      return;
    }

    // custom_id réel (clé du canal de diffusion du client) + profil
    const [{ data: uid }, { data: prof }, { data: vendor }] = await Promise.all([
      supabaseAdmin.from('user_ids').select('custom_id').eq('user_id', userId).maybeSingle(),
      supabaseAdmin.from('profiles')
        .select('first_name, last_name, full_name, phone, avatar_url, city, country, custom_id, public_id')
        .eq('id', userId).maybeSingle(),
      supabaseAdmin.from('vendors')
        .select('business_name, address, city, neighborhood, phone, logo_url')
        .eq('user_id', userId).maybeSingle(),
    ]);

    const customId = uid?.custom_id || (prof as any)?.custom_id || (prof as any)?.public_id || null;
    const isShop = !!vendor;

    const profile = {
      name: (prof as any)?.full_name
        || `${(prof as any)?.first_name || ''} ${(prof as any)?.last_name || ''}`.trim()
        || 'Client',
      phone: (vendor as any)?.phone || (prof as any)?.phone || undefined,
      address: isShop
        ? [(vendor as any)?.address, (vendor as any)?.neighborhood, (vendor as any)?.city].filter(Boolean).join(', ') || undefined
        : [(prof as any)?.city, (prof as any)?.country].filter(Boolean).join(', ') || undefined,
      photo: (vendor as any)?.logo_url || (prof as any)?.avatar_url || undefined,
      customId: customId || undefined,
      isShop,
      shopName: (vendor as any)?.business_name || undefined,
    };

    // Clé de canal = user_id (UUID). Le client écoute/diffuse aussi sur son canal user_id,
    // et un UUID permet aux requêtes taxi_drivers/profiles côté chauffeur de fonctionner.
    const trackingKey = userId;

    res.json({
      success: true,
      status: 'active',
      userId,
      customId,
      trackingKey,
      profile,
    });
  } catch (error: any) {
    logger.error(`[Taxi] resolve-target error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la résolution de la cible' });
  }
});

/**
 * POST /api/v2/taxi/rate
 * Enregistre l'avis d'un client sur une course + recalcule la moyenne du chauffeur.
 * Service role → contourne la RLS (le client ne peut pas écrire dans taxi_drivers).
 *
 * Body : { ride_id, stars (1-5), comment? }
 */
router.post('/rate', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;
    const { ride_id, stars, comment } = req.body || {};

    const starsNum = Number(stars);
    if (!ride_id || typeof ride_id !== 'string') {
      res.status(400).json({ success: false, error: 'ride_id requis' });
      return;
    }
    if (!Number.isFinite(starsNum) || starsNum < 1 || starsNum > 5) {
      res.status(400).json({ success: false, error: 'stars doit être entre 1 et 5' });
      return;
    }

    // Récupérer la course pour connaître le chauffeur et vérifier que le client en est l'auteur
    const { data: trip, error: tripErr } = await supabaseAdmin
      .from('taxi_trips')
      .select('id, driver_id, customer_id')
      .eq('id', ride_id)
      .maybeSingle();

    if (tripErr) throw tripErr;
    if (!trip || !(trip as any).driver_id) {
      res.status(404).json({ success: false, error: 'Course ou chauffeur introuvable' });
      return;
    }
    const driverId = (trip as any).driver_id;

    // Sécurité : seul le client de la course peut la noter
    if ((trip as any).customer_id && (trip as any).customer_id !== userId) {
      res.status(403).json({ success: false, error: 'Vous ne pouvez noter que vos propres courses' });
      return;
    }

    // Anti-doublon : une note par course/utilisateur
    const { data: existing } = await supabaseAdmin
      .from('taxi_ratings')
      .select('id')
      .eq('ride_id', ride_id)
      .eq('user_id', userId)
      .maybeSingle();

    if (existing) {
      await supabaseAdmin
        .from('taxi_ratings')
        .update({ stars: Math.round(starsNum), comment: comment || null })
        .eq('id', (existing as any).id);
    } else {
      const { error: insErr } = await supabaseAdmin
        .from('taxi_ratings')
        .insert({ ride_id, driver_id: driverId, user_id: userId, stars: Math.round(starsNum), comment: comment || null });
      if (insErr) throw insErr;
    }

    // Recalculer la moyenne du chauffeur et la persister
    const { data: all } = await supabaseAdmin
      .from('taxi_ratings')
      .select('stars')
      .eq('driver_id', driverId);

    let average: number | null = null;
    if (Array.isArray(all) && all.length > 0) {
      average = Math.round((all.reduce((s: number, r: any) => s + (Number(r.stars) || 0), 0) / all.length) * 10) / 10;
      await supabaseAdmin.from('taxi_drivers').update({ rating: average }).eq('user_id', driverId);
    }

    logger.info(`[Taxi] rate: ride=${ride_id}, driver=${driverId}, stars=${Math.round(starsNum)}, avg=${average}`);
    res.json({ success: true, average, total_ratings: Array.isArray(all) ? all.length : 0 });
  } catch (error: any) {
    logger.error(`[Taxi] rate error: ${error.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de l\'enregistrement de l\'avis' });
  }
});

/**
 * POST /api/v2/taxi/rides — créer une course à PRIX SERVEUR.
 * Le prix est recalculé serveur (create_taxi_ride → calculate_taxi_fare) ; un prix/part/commission
 * venu du client est IGNORÉ. p_rider_id = req.user.id (jamais du body).
 */
router.post('/rides', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const riderId = req.user!.id;
    const b = req.body || {};
    const { data, error } = await supabaseAdmin.rpc('create_taxi_ride', {
      p_rider_id: riderId,
      p_pickup_lat: b.pickupLat, p_pickup_lng: b.pickupLng,
      p_dropoff_lat: b.dropoffLat, p_dropoff_lng: b.dropoffLng,
      p_pickup_address: b.pickupAddress || '', p_dropoff_address: b.dropoffAddress || '',
      p_vehicle_type: b.vehicleType || 'moto',
      p_payment_method: b.paymentMethod || 'cash',
      p_client_distance_km: b.clientDistanceKm ?? null,
      p_client_duration_min: b.clientDurationMin ?? null,
      p_metadata: b.phoneNumber ? { orange_money_phone: b.phoneNumber } : {},
    });
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    const r = data as any;
    if (!r?.success) {
      const codeMap: Record<string, number> = {
        INVALID_COORDINATES: 400, INVALID_DISTANCE: 400, RIDE_ALREADY_ACTIVE: 409,
        RIDER_REQUIRED: 400, FARE_CALCULATION_FAILED: 500,
      };
      res.status(codeMap[r?.error] || 400).json({ success: false, error: r?.error || 'RIDE_CREATE_FAILED', error_code: r?.error });
      return;
    }
    res.json({ success: true, data: { ride: r.ride, price_total: r.price_total, distance_km: r.distance_km, duration_min: r.duration_min } });
  } catch (e: any) {
    logger.error(`[Taxi] create ride error: ${e?.message}`);
    res.status(500).json({ success: false, error: 'Erreur lors de la création de la course' });
  }
});

export default router;
