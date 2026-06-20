/**
 * 🏥 SERVICE PHARMACIE — routes backend (/api/v2/pharmacy).
 *
 * Flux : le client envoie une ordonnance → le pharmacien la VALIDE MANUELLEMENT (saisie des
 * médicaments + devis) ou la refuse → le client paie (RPC atomique process_pharmacy_order) →
 * préparation → livraison/retrait.
 *
 * Sécurité : verifyJWT partout. Le PRIX payé est TOUJOURS le devis du pharmacien (total_quoted),
 * jamais un montant du client. La validation d'ordonnance est une action HUMAINE explicite du
 * pharmacien (aucune automatisation — obligation médicale/légale).
 */
import { Router, Response } from 'express';
import { randomUUID } from 'crypto';
import { verifyJWT } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { logger } from '../config/logger.js';

const router = Router();

/** Le user courant est-il propriétaire de cette pharmacie (professional_services) ? */
async function isPharmacyOwner(pharmacyId: string, userId: string): Promise<boolean> {
  if (!pharmacyId) return false;
  const { data } = await supabaseAdmin.from('professional_services').select('user_id, service_type_id').eq('id', pharmacyId).maybeSingle();
  return !!data && data.user_id === userId;
}

/** POST /api/v2/pharmacy/prescriptions — le client envoie une ordonnance scannée. */
router.post('/prescriptions', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const b = req.body ?? {};
    const pharmacyId = String(b.pharmacy_id || '');
    const rawPhotos = Array.isArray(b.photos) ? b.photos.filter((p: any) => typeof p === 'string' && p).slice(0, 8) : [];
    // Chemins privés : doivent appartenir au dossier de l'utilisateur (<uid>/...). Http = legacy.
    const photos = rawPhotos.filter((p: string) => /^https?:\/\//i.test(p) || p.startsWith(`${req.user!.id}/`));
    if (!pharmacyId || photos.length === 0) { res.status(400).json({ success: false, error: 'pharmacy_id et au moins une photo (chemin valide) requis' }); return; }
    if (photos.length !== rawPhotos.length) { res.status(403).json({ success: false, error: 'Chemin de photo non autorisé' }); return; }
    const deliveryType = b.delivery_type === 'delivery' ? 'delivery' : 'pickup';
    if (deliveryType === 'delivery' && !String(b.delivery_address || '').trim()) {
      res.status(400).json({ success: false, error: 'Adresse de livraison requise' }); return;
    }
    // La pharmacie doit exister et être de type pharmacie.
    const { data: svc } = await supabaseAdmin.from('professional_services').select('id, service_type_id').eq('id', pharmacyId).maybeSingle();
    if (!svc) { res.status(404).json({ success: false, error: 'Pharmacie introuvable' }); return; }

    const { data, error } = await supabaseAdmin.from('prescriptions').insert({
      client_id: req.user!.id, pharmacy_id: pharmacyId, photos, status: 'pending',
      delivery_type: deliveryType, delivery_address: deliveryType === 'delivery' ? String(b.delivery_address).trim() : null,
      customer_name: b.customer_name ? String(b.customer_name).slice(0, 200) : null,
      customer_phone: b.customer_phone ? String(b.customer_phone).slice(0, 20) : null,
    }).select('id, status').single();
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true, data });
  } catch (e: any) { logger.error(`[pharmacy/prescriptions POST] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

/** GET /api/v2/pharmacy/prescriptions — pharmacien (?service_id=, sa file) OU client (les siennes). */
router.get('/prescriptions', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const serviceId = String(req.query.service_id || '');
    let q = supabaseAdmin.from('prescriptions').select('*').order('created_at', { ascending: true });
    if (serviceId) {
      if (!(await isPharmacyOwner(serviceId, req.user!.id))) { res.status(403).json({ success: false, error: 'Pharmacie non autorisée' }); return; }
      q = q.eq('pharmacy_id', serviceId);
    } else {
      q = q.eq('client_id', req.user!.id).order('created_at', { ascending: false });
    }
    const { data, error } = await q;
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true, data: data || [] });
  } catch (e: any) { logger.error(`[pharmacy/prescriptions GET] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

const PRESCRIPTION_BUCKET = 'prescriptions';
const PRESC_SIGNED_TTL = 300; // 5 min

/**
 * GET /api/v2/pharmacy/prescriptions/:id/photos — URLs signées (5 min) des photos d'ordonnance.
 * Donnée médicale : accès réservé au CLIENT propriétaire OU au PHARMACIEN destinataire.
 * Les anciennes entrées (URL publique http) sont renvoyées telles quelles (legacy).
 */
router.get('/prescriptions/:id/photos', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: presc } = await supabaseAdmin.from('prescriptions')
      .select('id, client_id, pharmacy_id, photos').eq('id', req.params.id).maybeSingle();
    if (!presc) { res.status(404).json({ success: false, error: 'Ordonnance introuvable' }); return; }
    const isClient = presc.client_id === req.user!.id;
    const isPharma = await isPharmacyOwner(presc.pharmacy_id, req.user!.id);
    if (!isClient && !isPharma) { res.status(403).json({ success: false, error: 'Accès refusé' }); return; }

    const photos: string[] = Array.isArray(presc.photos) ? presc.photos : [];
    const urls: string[] = [];
    for (const entry of photos) {
      const v = String(entry || '');
      if (!v) continue;
      if (/^https?:\/\//i.test(v)) { urls.push(v); continue; } // legacy (URL publique déjà stockée)
      const { data: s, error: signErr } = await supabaseAdmin.storage.from(PRESCRIPTION_BUCKET).createSignedUrl(v, PRESC_SIGNED_TTL);
      if (signErr || !s?.signedUrl) { logger.warn(`[pharmacy/photos] signature échouée (${v.slice(0, 60)}): ${signErr?.message}`); continue; }
      urls.push(s.signedUrl);
    }
    res.json({ success: true, data: urls, expiresInSeconds: PRESC_SIGNED_TTL });
  } catch (e: any) { logger.error(`[pharmacy/photos] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

/** POST /api/v2/pharmacy/prescriptions/:id/validate — le pharmacien VALIDE (médicaments + devis). MANUEL. */
router.post('/prescriptions/:id/validate', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: presc } = await supabaseAdmin.from('prescriptions').select('id, pharmacy_id, status, delivery_type').eq('id', req.params.id).maybeSingle();
    if (!presc) { res.status(404).json({ success: false, error: 'Ordonnance introuvable' }); return; }
    if (!(await isPharmacyOwner(presc.pharmacy_id, req.user!.id))) { res.status(403).json({ success: false, error: 'Action réservée à la pharmacie' }); return; }
    if (!['pending', 'reviewing', 'quoted'].includes(presc.status)) { res.status(409).json({ success: false, error: 'Ordonnance déjà traitée' }); return; }

    const meds = Array.isArray(req.body?.medications) ? req.body.medications : [];
    if (meds.length === 0) { res.status(400).json({ success: false, error: 'Au moins un médicament requis' }); return; }
    // Total = somme serveur (jamais un total du client) : prix × quantité de chaque ligne validée.
    const total = meds.reduce((s: number, m: any) => s + Math.max(0, Number(m.price) || 0) * Math.max(1, Math.round(Number(m.quantity) || 1)), 0);
    if (total <= 0) { res.status(400).json({ success: false, error: 'Devis invalide (total nul)' }); return; }
    // Frais de livraison chiffrés par le pharmacien (uniquement si livraison à domicile).
    const deliveryFee = presc.delivery_type === 'delivery' ? Math.max(0, Math.round(Number(req.body?.delivery_fee) || 0)) : 0;

    const { error } = await supabaseAdmin.from('prescriptions').update({
      status: 'quoted', medications_validated: meds, total_quoted: total, delivery_fee: deliveryFee,
      pharmacist_notes: req.body?.notes ? String(req.body.notes).slice(0, 1000) : null,
      validated_at: new Date().toISOString(), updated_at: new Date().toISOString(),
    }).eq('id', req.params.id);
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true, total, delivery_fee: deliveryFee });
  } catch (e: any) { logger.error(`[pharmacy/validate] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

/** POST /api/v2/pharmacy/prescriptions/:id/refuse — le pharmacien refuse (motif obligatoire). */
router.post('/prescriptions/:id/refuse', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const reason = String(req.body?.reason || '').trim();
    if (!reason) { res.status(400).json({ success: false, error: 'Motif de refus obligatoire' }); return; }
    const { data: presc } = await supabaseAdmin.from('prescriptions').select('id, pharmacy_id, status').eq('id', req.params.id).maybeSingle();
    if (!presc) { res.status(404).json({ success: false, error: 'Ordonnance introuvable' }); return; }
    if (!(await isPharmacyOwner(presc.pharmacy_id, req.user!.id))) { res.status(403).json({ success: false, error: 'Action réservée à la pharmacie' }); return; }
    const { error } = await supabaseAdmin.from('prescriptions').update({ status: 'refused', refuse_reason: reason.slice(0, 500), updated_at: new Date().toISOString() }).eq('id', req.params.id);
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (e: any) { logger.error(`[pharmacy/refuse] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

/** POST /api/v2/pharmacy/order — le client paie le devis (prix = total_quoted serveur). */
router.post('/order', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const prescriptionId = String(req.body?.prescription_id || '');
    if (!prescriptionId) { res.status(400).json({ success: false, error: 'prescription_id requis' }); return; }
    const { data: presc } = await supabaseAdmin.from('prescriptions')
      .select('id, client_id, pharmacy_id, status, total_quoted, medications_validated, delivery_type, delivery_address, delivery_fee').eq('id', prescriptionId).maybeSingle();
    if (!presc) { res.status(404).json({ success: false, error: 'Ordonnance introuvable' }); return; }
    if (presc.client_id !== req.user!.id) { res.status(403).json({ success: false, error: 'Ordonnance non autorisée' }); return; }
    if (!['validated', 'quoted'].includes(presc.status)) { res.status(409).json({ success: false, error: 'Ordonnance non encore validée par le pharmacien' }); return; }
    if (!presc.total_quoted || Number(presc.total_quoted) <= 0) { res.status(400).json({ success: false, error: 'Devis indisponible' }); return; }

    const idem = String(req.body?.idempotency_key || `pharma:${req.user!.id}:${randomUUID()}`).slice(0, 120);
    const { data, error } = await supabaseAdmin.rpc('process_pharmacy_order', {
      p_client_id: req.user!.id,
      p_pharmacy_id: presc.pharmacy_id,
      p_prescription_id: presc.id,
      p_amount: Number(presc.total_quoted),       // PRIX AUTORITAIRE = devis pharmacien
      p_medications: presc.medications_validated ?? [],
      p_delivery_type: presc.delivery_type || 'pickup',
      p_delivery_address: presc.delivery_address || null,
      p_idempotency_key: idem,
      p_delivery_fee: presc.delivery_type === 'delivery' ? Math.max(0, Number(presc.delivery_fee) || 0) : 0,
      p_delivery_paid_by: 'client',
    });
    if (error) {
      const m = error.message || '';
      const code = /SOLDE_INSUFFISANT/.test(m) ? 402 : /ORDONNANCE_NON_VALIDEE|NON_CONCORDANTE/.test(m) ? 409 : 400;
      res.status(code).json({ success: false, error: m }); return;
    }
    res.json({ success: true, ...(data as object) });
  } catch (e: any) { logger.error(`[pharmacy/order] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

/** GET /api/v2/pharmacy/orders — pharmacien (?service_id=) OU client (les siennes). */
router.get('/orders', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const serviceId = String(req.query.service_id || '');
    let q = supabaseAdmin.from('pharmacy_orders').select('*').order('created_at', { ascending: false });
    if (serviceId) {
      if (!(await isPharmacyOwner(serviceId, req.user!.id))) { res.status(403).json({ success: false, error: 'Pharmacie non autorisée' }); return; }
      q = q.eq('pharmacy_id', serviceId);
    } else {
      q = q.eq('client_id', req.user!.id);
    }
    const { data, error } = await q;
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true, data: data || [] });
  } catch (e: any) { logger.error(`[pharmacy/orders GET] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

/** POST /api/v2/pharmacy/orders/:id/status — le pharmacien fait avancer la commande. */
router.post('/orders/:id/status', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const status = String(req.body?.status || '');
    if (!['ready', 'delivering', 'delivered', 'collected'].includes(status)) { res.status(400).json({ success: false, error: 'Statut invalide' }); return; }
    const { data: order } = await supabaseAdmin.from('pharmacy_orders').select('id, pharmacy_id').eq('id', req.params.id).maybeSingle();
    if (!order) { res.status(404).json({ success: false, error: 'Commande introuvable' }); return; }
    if (!(await isPharmacyOwner(order.pharmacy_id, req.user!.id))) { res.status(403).json({ success: false, error: 'Action réservée à la pharmacie' }); return; }
    const { error } = await supabaseAdmin.from('pharmacy_orders').update({ status, updated_at: new Date().toISOString() }).eq('id', req.params.id);
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (e: any) { logger.error(`[pharmacy/orders status] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

// ============================================================================
// RAPPELS DE PRISE DE MÉDICAMENTS (côté client) — Phase 6.
// Le copilot/pharmacien ne prescrit rien : le client saisit ses propres rappels
// (nom du médicament + heures de prise). Aucun conseil médical.
// ============================================================================

/** Valide un tableau d'heures "HH:MM" → "HH:MM:00" trié, max 6, dédupliqué. */
function normalizeTimes(input: any): string[] {
  const arr = Array.isArray(input) ? input : [];
  const re = /^([01]\d|2[0-3]):([0-5]\d)$/;
  const set = new Set<string>();
  for (const t of arr) {
    const s = String(t).trim();
    if (re.test(s)) set.add(`${s}:00`);
  }
  return [...set].sort().slice(0, 6);
}

/** GET /api/v2/pharmacy/reminders — les rappels du client courant. */
router.get('/reminders', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.from('medication_reminders')
      .select('*').eq('client_id', req.user!.id).order('created_at', { ascending: false });
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true, data: data || [] });
  } catch (e: any) { logger.error(`[pharmacy/reminders GET] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

/** POST /api/v2/pharmacy/reminders — créer un rappel. */
router.post('/reminders', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const b = req.body ?? {};
    const name = String(b.medication_name || '').trim();
    const times = normalizeTimes(b.times);
    if (!name) { res.status(400).json({ success: false, error: 'Nom du médicament requis' }); return; }
    if (times.length === 0) { res.status(400).json({ success: false, error: 'Au moins une heure de prise (HH:MM) requise' }); return; }
    const durationRaw = Number(b.duration_days);
    const duration = Number.isFinite(durationRaw) && durationRaw > 0 ? Math.min(365, Math.round(durationRaw)) : null;
    const { data, error } = await supabaseAdmin.from('medication_reminders').insert({
      client_id: req.user!.id, medication_name: name.slice(0, 200), times,
      frequency: b.frequency ? String(b.frequency).slice(0, 50) : null,
      duration_days: duration, start_date: new Date().toISOString().slice(0, 10), active: true,
    }).select('*').single();
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true, data });
  } catch (e: any) { logger.error(`[pharmacy/reminders POST] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

/** DELETE /api/v2/pharmacy/reminders/:id — supprimer un rappel (scopé au client). */
router.delete('/reminders/:id', verifyJWT, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { error } = await supabaseAdmin.from('medication_reminders')
      .delete().eq('id', req.params.id).eq('client_id', req.user!.id);
    if (error) { res.status(400).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (e: any) { logger.error(`[pharmacy/reminders DELETE] ${e?.message}`); res.status(500).json({ success: false, error: 'Erreur serveur' }); }
});

export default router;
