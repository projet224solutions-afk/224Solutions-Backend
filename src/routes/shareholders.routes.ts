/**
 * SHAREHOLDERS ROUTES — Système de gestion des actionnaires
 *
 * PDG/admin  : création, gestion, calcul des revenus, paiements
 * Actionnaire: dashboard personnel, abonnements de son périmètre
 */

import { Router, Response } from 'express';
import { verifyJWT, requireRole } from '../middlewares/auth.middleware.js';
import type { AuthenticatedRequest } from '../middlewares/auth.middleware.js';
import { supabaseAdmin } from '../config/supabase.js';
import { createAuthUserWithPhone } from '../services/authPhone.service.js';
import { logger } from '../config/logger.js';

const router = Router();

// ─── helpers ──────────────────────────────────────────────────────────────────

const PDG_ROLES = ['pdg', 'admin', 'ceo'];
const ACTIONNAIRE_ROLES = ['actionnaire', 'pdg', 'admin', 'ceo'];

/** COALESCE pays du profil (country ?? detected_country) */
const coalesceCountry = (profile: any): string | null =>
  profile?.country || profile?.detected_country || null;

/**
 * Recalcule les revenus EN ATTENTE (non encore crédités) d'un actionnaire après
 * une modification de son attribution (part d'action %, catégorie, portée, pays).
 *
 * → Chaque revenu `pending` est ré-évalué via `calculate_shareholder_revenue`
 *   pour SA période, avec les NOUVEAUX paramètres de l'attribution. Le reçu PDF
 *   (généré depuis la ligne `shareholder_revenues`) reflète alors la nouvelle part.
 * → Le paiement associé (s'il est encore `pending`) est mis à jour au même montant.
 * → Les revenus déjà versés (`sent_to_wallet` / `withdrawn`) ne sont JAMAIS touchés
 *   (vérité comptable historique au taux de l'époque).
 *
 * La période (period_start/period_end/assignment_id) n'est pas modifiée → le trigger
 * anti-chevauchement n'est pas déclenché.
 */
async function recalcPendingRevenuesForShareholder(
  shareholderId: string,
  actorId: string,
): Promise<{ updated: number }> {
  let updated = 0;

  // Revenus encore en attente de cet actionnaire (jamais crédités au wallet)
  const { data: pendingRevenues, error: revErr } = await supabaseAdmin
    .from('shareholder_revenues')
    .select('id, assignment_id, period_start, period_end')
    .eq('shareholder_id', shareholderId)
    .eq('payment_status', 'pending');

  if (revErr || !pendingRevenues?.length) return { updated };

  for (const rev of pendingRevenues) {
    if (!rev.assignment_id) continue;

    // Ré-évaluation avec les nouveaux paramètres de l'attribution
    const { data: calc, error: calcErr } = await supabaseAdmin.rpc(
      'calculate_shareholder_revenue',
      {
        p_assignment_id: rev.assignment_id,
        p_period_start:  rev.period_start,
        p_period_end:    rev.period_end,
      },
    );

    if (calcErr || !calc || (calc as any).error) {
      logger.warn(`recalcPendingRevenues - skip revenue ${rev.id}: ${calcErr?.message || (calc as any)?.error}`);
      continue;
    }

    const c = calc as any;

    // Mise à jour de l'instantané du revenu (source du reçu PDF)
    const { error: upErr } = await supabaseAdmin
      .from('shareholder_revenues')
      .update({
        category:                 c.category,
        action_scope:             c.action_scope,
        country:                  c.country || null,
        paid_subscriptions_count: c.paid_subscriptions_count || 0,
        free_subscriptions_count: c.free_subscriptions_count || 0,
        total_paid_revenue_brut:  c.total_paid_revenue_brut ?? c.total_paid_revenue ?? 0,
        total_agent_commission:   c.total_agent_commission   ?? 0,
        total_paid_revenue:       c.total_paid_revenue || 0,
        percentage:               c.percentage,
        shareholder_amount:       c.shareholder_amount || 0,
        currency:                 c.currency || 'GNF',
        updated_at:               new Date().toISOString(),
      })
      .eq('id', rev.id)
      .eq('payment_status', 'pending'); // garde-fou : n'écrase pas un revenu crédité entre-temps

    if (upErr) {
      logger.warn(`recalcPendingRevenues - update revenue ${rev.id} failed: ${upErr.message}`);
      continue;
    }

    // Mise à jour du paiement associé s'il est encore en attente
    await supabaseAdmin
      .from('shareholder_payments')
      .update({
        amount:   c.shareholder_amount || 0,
        currency: c.currency || 'GNF',
      })
      .eq('revenue_id', rev.id)
      .eq('status', 'pending');

    updated++;
  }

  if (updated > 0) {
    supabaseAdmin.from('shareholder_audit_logs').insert({
      actor_id:    actorId,
      action:      'recalc_pending_revenues',
      entity_type: 'shareholder',
      entity_id:   shareholderId,
      new_value:   { recalculated_revenues: updated },
    });
    logger.info(`recalcPendingRevenues - ${updated} revenu(s) recalculé(s) pour actionnaire ${shareholderId}`);
  }

  return { updated };
}

// ─── MIDDLEWARE commun ────────────────────────────────────────────────────────
// Toutes les routes actionnaires nécessitent un JWT valide
router.use(verifyJWT);

// =============================================================================
// PDG : GESTION DES ACTIONNAIRES
// =============================================================================

/**
 * POST /api/shareholders
 * Créer un actionnaire (compte auth + profil + fiche + assignment)
 */
router.post('/', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const {
      full_name, email, phone, temp_password,
      category, action_scope, country, percentage, internal_notes,
      residence_country,
      investment_amount, investment_currency, payout_cap_multiple, payout_cap_amount, perpetual,
    } = req.body;

    if (!full_name || !email || !temp_password || !category || !action_scope || !percentage) {
      res.status(400).json({ success: false, error: 'Champs obligatoires manquants' });
      return;
    }

    // PLAFOND DE SORTIE obligatoire (ou perpétuel EXPLICITE) — jamais de perpétuel par défaut.
    const invAmt = investment_amount != null && investment_amount !== '' ? Number(investment_amount) : null;
    const capMult = payout_cap_multiple != null && payout_cap_multiple !== '' ? Number(payout_cap_multiple) : null;
    let capAmount: number | null = payout_cap_amount != null && payout_cap_amount !== '' ? Number(payout_cap_amount) : null;
    if (capAmount == null && invAmt != null && capMult != null && capMult > 0) {
      capAmount = Math.round(invAmt * capMult);
    }
    if (perpetual !== true && (capAmount == null || capAmount <= 0)) {
      res.status(400).json({
        success: false,
        error: 'Plafond de sortie obligatoire : fournissez un montant investi + multiple (ex. 3.0), ou cochez explicitement « sans plafond ».',
        error_code: 'PAYOUT_CAP_REQUIRED',
      });
      return;
    }

    const nameParts  = String(full_name).trim().split(' ');
    const first_name = nameParts[0] || full_name;
    const last_name  = nameParts.slice(1).join(' ') || '';

    // 1. Créer le compte auth (service_role bypass RLS) — téléphone = identifiant (login
    //    email OU téléphone). residence_country = code pays ISO (get_currency_for_country).
    //    Dégrade en email-only si le numéro est déjà pris.
    const authCreate = await createAuthUserWithPhone({
      email: email.toLowerCase(),
      password: temp_password,
      phone: phone || null,
      countryCode: residence_country,
      user_metadata: { full_name, first_name, last_name, role: 'actionnaire', phone: phone || null },
    });

    if (authCreate.error || !authCreate.user) {
      logger.error('shareholders.create - auth error:', authCreate.error?.message);
      res.status(400).json({ success: false, error: authCreate.error?.message || 'Erreur création compte' });
      return;
    }

    const userId = authCreate.user.id;
    const phoneLoginAvailable = authCreate.phoneLoginAvailable;

    // 2. Upsert profil (service_role bypass "Only system can create profiles" RLS)
    // residence_country → country + detected_currency sur le profil (détermine la devise du wallet)
    const profileData: Record<string, any> = {
      id: userId,
      email: email.toLowerCase(),
      first_name,
      last_name,
      role: 'actionnaire',
      phone: phone || null,
      is_active: true,
    };
    if (residence_country) {
      profileData.country            = residence_country;
      profileData.detected_country   = residence_country;
      // Récupérer la devise via la fonction DB get_currency_for_country
      const { data: currencyData } = await supabaseAdmin
        .rpc('get_currency_for_country', { p_country_code: residence_country });
      if (currencyData) {
        profileData.detected_currency = currencyData;
      }
    }
    const { error: profileErr } = await supabaseAdmin
      .from('profiles')
      .upsert(profileData, { onConflict: 'id' });

    if (profileErr) {
      logger.warn('shareholders.create - profile upsert warning:', profileErr.message);
    }

    // 3. Créer la fiche actionnaire
    const { data: sh, error: shErr } = await supabaseAdmin
      .from('shareholders')
      .insert({
        user_id:        userId,
        full_name:      String(full_name).trim(),
        email:          email.toLowerCase(),
        phone:          phone || null,
        status:         'active',
        created_by:     req.user!.id,
        internal_notes: internal_notes || null,
      })
      .select('id')
      .single();

    if (shErr || !sh) {
      logger.error('shareholders.create - shareholder insert error:', shErr?.message);
      res.status(500).json({ success: false, error: shErr?.message || 'Erreur création fiche actionnaire' });
      return;
    }

    // 4. Créer l'assignment
    const { error: assignErr } = await supabaseAdmin
      .from('shareholder_assignments')
      .insert({
        shareholder_id: sh.id,
        category,
        action_scope,
        country: action_scope === 'country' ? (country || null) : null,
        percentage: Number(percentage),
        status: 'active',
        investment_amount: invAmt,
        investment_currency: investment_currency || null,
        payout_cap_multiple: perpetual === true ? null : capMult,
        payout_cap_amount: perpetual === true ? null : capAmount,
      });

    if (assignErr) {
      logger.error('shareholders.create - assignment error:', assignErr.message);
      // Le trigger BEFORE (check_shareholder_percent_sum) refuse si la somme des parts > 100 %.
      if (/> 100 %|check_violation/i.test(assignErr.message) || (assignErr as any).code === '23514') {
        res.status(400).json({ success: false, error: 'La somme des parts actionnaires dépasserait 100 % pour cette catégorie/portée.', error_code: 'SHAREHOLDER_PERCENT_OVERFLOW' });
        return;
      }
      res.status(500).json({ success: false, error: assignErr.message });
      return;
    }

    // 5. Audit log (non bloquant)
    supabaseAdmin.from('shareholder_audit_logs').insert({
      actor_id:    req.user!.id,
      action:      'create_shareholder',
      entity_type: 'shareholder',
      entity_id:   sh.id,
      new_value:   { full_name, email, category, action_scope, country, percentage },
    });

    logger.info(`shareholders.create - success: ${sh.id} by ${req.user!.id} (phone_login=${phoneLoginAvailable})`);
    res.json({
      success: true,
      shareholder_id: sh.id,
      phone_login_available: phoneLoginAvailable,
      ...(phoneLoginAvailable ? {} : { message: 'Ce numéro est déjà lié à un autre compte — connexion par email uniquement.' }),
    });
  } catch (err: any) {
    logger.error('shareholders.create - unhandled:', err.message);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/shareholders
 * Lister tous les actionnaires (PDG)
 */
router.get('/', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('shareholders')
      .select('*, assignment:shareholder_assignments(*)')
      .order('created_at', { ascending: false });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    const shareholders = (data || []).map((d: any) => ({
      ...d,
      assignment: Array.isArray(d.assignment) ? d.assignment[0] : d.assignment,
    }));

    res.json({ success: true, data: shareholders });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/shareholders/stats
 * Statistiques globales PDG
 */
router.get('/stats', requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('shareholder_pdg_stats')
      .select('*')
      .single();

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    res.json({ success: true, data });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/shareholders/percentages
 * Résumé des pourcentages attribués par catégorie/portée
 */
router.get('/percentages', requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('shareholder_percentage_summary')
      .select('*');

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    res.json({ success: true, data: data || [] });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/shareholders/validate-percentage
 * Vérifier si un pourcentage est disponible
 */
router.post('/validate-percentage', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { category, scope, new_percentage, country, exclude_id } = req.body;

    const { data, error } = await supabaseAdmin.rpc('validate_shareholder_percentage', {
      p_category:        category,
      p_scope:           scope,
      p_new_percentage:  Number(new_percentage),
      p_country:         country || null,
      p_exclude_id:      exclude_id || null,
    });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    res.json({ success: true, data });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * PUT /api/shareholders/:id
 * Mettre à jour un actionnaire (PDG)
 */
router.put('/:id', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id } = req.params;
    const { full_name, email, phone, status, internal_notes, category, action_scope, country, percentage } = req.body;

    // Mise à jour de la fiche actionnaire
    const shUpdate: any = {};
    if (full_name)       shUpdate.full_name       = String(full_name).trim();
    if (email)           shUpdate.email           = email.toLowerCase();
    if (phone !== undefined) shUpdate.phone       = phone || null;
    if (status)          shUpdate.status          = status;
    if (internal_notes !== undefined) shUpdate.internal_notes = internal_notes;

    if (Object.keys(shUpdate).length > 0) {
      const { error } = await supabaseAdmin
        .from('shareholders')
        .update(shUpdate)
        .eq('id', id);

      if (error) {
        res.status(500).json({ success: false, error: error.message });
        return;
      }
    }

    // Mise à jour de l'assignment si nécessaire
    const assignmentChanged =
      Boolean(category) || Boolean(action_scope) || percentage !== undefined || country !== undefined;

    if (assignmentChanged) {
      const aUpdate: any = {};
      if (category)              aUpdate.category      = category;
      if (action_scope)          aUpdate.action_scope  = action_scope;
      if (country !== undefined) aUpdate.country       = country || null;
      if (percentage !== undefined) aUpdate.percentage = Number(percentage);

      const { error: aErr } = await supabaseAdmin
        .from('shareholder_assignments')
        .update(aUpdate)
        .eq('shareholder_id', id);

      if (aErr) {
        res.status(500).json({ success: false, error: aErr.message });
        return;
      }
    }

    // Si la part d'action (ou la catégorie/portée/pays) a changé, on recalcule les
    // revenus EN ATTENTE → leurs reçus PDF reflètent la nouvelle part. Les revenus
    // déjà crédités au wallet restent figés (vérité comptable historique).
    let recalculatedRevenues = 0;
    if (assignmentChanged) {
      try {
        const { updated } = await recalcPendingRevenuesForShareholder(id, req.user!.id);
        recalculatedRevenues = updated;
      } catch (recalcErr: any) {
        // Non bloquant : la mise à jour de l'attribution a réussi
        logger.warn(`shareholders.update - recalc revenus échoué pour ${id}: ${recalcErr?.message}`);
      }
    }

    // Audit log
    supabaseAdmin.from('shareholder_audit_logs').insert({
      actor_id:    req.user!.id,
      action:      'update_shareholder',
      entity_type: 'shareholder',
      entity_id:   id,
      new_value:   req.body,
    });

    res.json({ success: true, recalculated_revenues: recalculatedRevenues });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/shareholders/:id/transfer
 * Transférer la part d'action d'un actionnaire vers un autre (PDG)
 * - Archive l'actionnaire source
 * - Réassigne l'assignment au nouvel actionnaire
 */
router.post('/:id/transfer', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id: fromId } = req.params;
    const { to_shareholder_id, reason } = req.body;

    if (!to_shareholder_id) {
      res.status(400).json({ success: false, error: 'to_shareholder_id est requis' });
      return;
    }
    if (fromId === to_shareholder_id) {
      res.status(400).json({ success: false, error: 'Source et destination identiques' });
      return;
    }

    // 1. Vérifier que l'actionnaire source existe et a un assignment
    const { data: source, error: srcErr } = await supabaseAdmin
      .from('shareholders')
      .select('id, full_name, status')
      .eq('id', fromId)
      .single();

    if (srcErr || !source) {
      res.status(404).json({ success: false, error: 'Actionnaire source introuvable' });
      return;
    }

    const { data: assignment, error: aErr } = await supabaseAdmin
      .from('shareholder_assignments')
      .select('id, category, action_scope, country, percentage')
      .eq('shareholder_id', fromId)
      .single();

    if (aErr || !assignment) {
      res.status(404).json({ success: false, error: 'Aucun assignment à transférer' });
      return;
    }

    // 2. Vérifier que la destination existe
    const { data: target, error: tgtErr } = await supabaseAdmin
      .from('shareholders')
      .select('id, full_name')
      .eq('id', to_shareholder_id)
      .single();

    if (tgtErr || !target) {
      res.status(404).json({ success: false, error: 'Actionnaire destination introuvable' });
      return;
    }

    // 3. Archiver l'assignment source (changer shareholder_id vers destination)
    const { error: transferErr } = await supabaseAdmin
      .from('shareholder_assignments')
      .update({ shareholder_id: to_shareholder_id })
      .eq('id', assignment.id);

    if (transferErr) {
      res.status(500).json({ success: false, error: transferErr.message });
      return;
    }

    // 4. Archiver l'actionnaire source
    await supabaseAdmin
      .from('shareholders')
      .update({ status: 'archived', internal_notes: `Transfert vers ${target.full_name}. ${reason || ''}`.trim() })
      .eq('id', fromId);

    // 5. Réactiver la destination si elle était suspendue/archivée
    await supabaseAdmin
      .from('shareholders')
      .update({ status: 'active' })
      .eq('id', to_shareholder_id);

    // 6. Audit log
    supabaseAdmin.from('shareholder_audit_logs').insert({
      actor_id:    req.user!.id,
      action:      'transfer_share',
      entity_type: 'shareholder_assignment',
      entity_id:   assignment.id,
      old_value:   { shareholder_id: fromId, shareholder_name: source.full_name },
      new_value:   { shareholder_id: to_shareholder_id, shareholder_name: target.full_name, reason },
    });

    logger.info(`shareholders.transfer - assignment ${assignment.id}: ${fromId} -> ${to_shareholder_id} by ${req.user!.id}`);
    res.json({ success: true, transferred_to: target.full_name });
  } catch (err: any) {
    logger.error('shareholders.transfer - unhandled:', err.message);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// PLAFOND DE SORTIE + CYCLE DE VIE (par ATTRIBUTION = « l'accord »)
// ─────────────────────────────────────────────────────────────────────────────

/** Trace un événement de cycle de vie dans l'audit (non bloquant). */
function logLifecycle(actorId: string, action: string, assignmentId: string, value: Record<string, any>): void {
  supabaseAdmin.from('shareholder_audit_logs').insert({
    actor_id: actorId, action, entity_type: 'shareholder_assignment', entity_id: assignmentId, new_value: value,
  });
}

/**
 * POST /api/shareholders/assignments/:assignmentId/cap
 * Saisie (ou saisie RÉTROACTIVE) du plafond : montant investi + multiple → plafond.
 * `perpetual:true` = sans plafond EXPLICITE. Ne modifie JAMAIS total_paid_to_date (maintenu par trigger).
 */
router.post('/assignments/:assignmentId/cap', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { assignmentId } = req.params;
    const { investment_amount, investment_currency, payout_cap_multiple, payout_cap_amount, perpetual } = req.body;
    const invAmt = investment_amount != null && investment_amount !== '' ? Number(investment_amount) : null;
    const capMult = payout_cap_multiple != null && payout_cap_multiple !== '' ? Number(payout_cap_multiple) : null;
    let capAmount: number | null = payout_cap_amount != null && payout_cap_amount !== '' ? Number(payout_cap_amount) : null;
    if (capAmount == null && invAmt != null && capMult != null && capMult > 0) capAmount = Math.round(invAmt * capMult);
    if (perpetual !== true && (capAmount == null || capAmount <= 0)) {
      res.status(400).json({ success: false, error: 'Plafond obligatoire : montant investi + multiple, ou « sans plafond » explicite.', error_code: 'PAYOUT_CAP_REQUIRED' });
      return;
    }
    const { error } = await supabaseAdmin.from('shareholder_assignments').update({
      investment_amount: invAmt,
      investment_currency: investment_currency || null,
      payout_cap_multiple: perpetual === true ? null : capMult,
      payout_cap_amount: perpetual === true ? null : capAmount,
      updated_at: new Date().toISOString(),
    }).eq('id', assignmentId);
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    logLifecycle(req.user!.id, 'set_payout_cap', assignmentId, { invAmt, capMult, capAmount, perpetual: perpetual === true });
    const { data: status } = await supabaseAdmin.rpc('shareholder_cap_status', { p_assignment_id: assignmentId });
    res.json({ success: true, cap_status: status });
  } catch (err: any) {
    logger.error('shareholders.cap - unhandled:', err.message);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** GET /api/shareholders/assignments/:assignmentId/cap-status — investi/plafond/versé/reste/progression. */
router.get('/assignments/:assignmentId/cap-status', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.rpc('shareholder_cap_status', { p_assignment_id: req.params.assignmentId });
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    res.json({ success: true, cap_status: data });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** POST /assignments/:assignmentId/beneficiary — SUCCESSION : bénéficiaire désigné. */
router.post('/assignments/:assignmentId/beneficiary', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { beneficiary } = req.body;
    if (!beneficiary || !String(beneficiary).trim()) { res.status(400).json({ success: false, error: 'Bénéficiaire requis' }); return; }
    const { error } = await supabaseAdmin.from('shareholder_assignments')
      .update({ beneficiary: String(beneficiary).trim(), updated_at: new Date().toISOString() }).eq('id', req.params.assignmentId);
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    logLifecycle(req.user!.id, 'set_beneficiary', req.params.assignmentId, { beneficiary });
    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /assignments/:assignmentId/buyout — RACHAT ANTICIPÉ : la société solde l'accord.
 * Enregistre le montant de rachat + statut `bought_out`. Le VERSEMENT effectif passe par le flux
 * de paiement standard (débit coffre PDG) — cet endpoint ne déplace pas d'argent en douce.
 */
router.post('/assignments/:assignmentId/buyout', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { buyout_amount, note } = req.body;
    const { data: a, error: aErr } = await supabaseAdmin.from('shareholder_assignments')
      .select('payout_cap_amount, total_paid_to_date').eq('id', req.params.assignmentId).single();
    if (aErr || !a) { res.status(404).json({ success: false, error: 'Attribution introuvable' }); return; }
    const remaining = a.payout_cap_amount != null ? Math.max(0, Number(a.payout_cap_amount) - Number(a.total_paid_to_date || 0)) : null;
    const amount = buyout_amount != null && buyout_amount !== '' ? Number(buyout_amount) : remaining;
    const { error } = await supabaseAdmin.from('shareholder_assignments').update({
      status: 'bought_out', buyout_amount: amount, bought_out_at: new Date().toISOString(),
      lifecycle_note: note || null, updated_at: new Date().toISOString(),
    }).eq('id', req.params.assignmentId);
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    logLifecycle(req.user!.id, 'buyout', req.params.assignmentId, { amount, remaining });
    res.json({ success: true, buyout_amount: amount, remaining_before: remaining });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** POST /assignments/:assignmentId/suspend — SUSPENSION/LITIGE : gèle les versements, motif obligatoire. */
router.post('/assignments/:assignmentId/suspend', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { reason } = req.body;
    if (!reason || !String(reason).trim()) { res.status(400).json({ success: false, error: 'Motif de suspension obligatoire', error_code: 'REASON_REQUIRED' }); return; }
    const { error } = await supabaseAdmin.from('shareholder_assignments')
      .update({ status: 'suspended', suspension_reason: String(reason).trim(), updated_at: new Date().toISOString() }).eq('id', req.params.assignmentId);
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    logLifecycle(req.user!.id, 'suspend_assignment', req.params.assignmentId, { reason });
    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** POST /assignments/:assignmentId/resume — lève la suspension (retour `active`). */
router.post('/assignments/:assignmentId/resume', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { error } = await supabaseAdmin.from('shareholder_assignments')
      .update({ status: 'active', suspension_reason: null, updated_at: new Date().toISOString() })
      .eq('id', req.params.assignmentId).eq('status', 'suspended');
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    logLifecycle(req.user!.id, 'resume_assignment', req.params.assignmentId, {});
    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /assignments/:assignmentId/lifecycle — note de cycle de vie (arrêt service/pays)
 * + clause de cession de la société (le droit se poursuit chez l'acquéreur, ou est soldé).
 */
router.post('/assignments/:assignmentId/lifecycle', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { lifecycle_note, company_sale_clause } = req.body;
    const patch: Record<string, any> = { updated_at: new Date().toISOString() };
    if (lifecycle_note !== undefined) patch.lifecycle_note = lifecycle_note || null;
    if (company_sale_clause !== undefined) patch.company_sale_clause = company_sale_clause || null;
    const { error } = await supabaseAdmin.from('shareholder_assignments').update(patch).eq('id', req.params.assignmentId);
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    logLifecycle(req.user!.id, 'lifecycle_note', req.params.assignmentId, patch);
    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** GET /api/shareholders/config — mention juridique + portée des votes (lecture PDG & partenaire). */
router.get('/config', requireRole(ACTIONNAIRE_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin.from('shareholder_config')
      .select('legal_mention, votes_advisory, default_cap_multiple').eq('id', 1).maybeSingle();
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    res.json({ success: true, config: data });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/** PUT /api/shareholders/config — le PDG édite la mention juridique (validée par son juriste). */
router.put('/config', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { legal_mention, votes_advisory, default_cap_multiple } = req.body;
    const patch: Record<string, any> = { updated_at: new Date().toISOString(), updated_by: req.user!.id };
    if (typeof legal_mention === 'string' && legal_mention.trim()) patch.legal_mention = legal_mention.trim();
    if (typeof votes_advisory === 'boolean') patch.votes_advisory = votes_advisory;
    if (default_cap_multiple != null && Number(default_cap_multiple) > 0) patch.default_cap_multiple = Number(default_cap_multiple);
    const { error } = await supabaseAdmin.from('shareholder_config').update(patch).eq('id', 1);
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * DELETE /api/shareholders/:id
 * Supprimer un actionnaire (PDG) — soft delete (archived) + désactivation auth
 * Bloqué si des paiements sont en attente
 */
router.delete('/:id', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id } = req.params;

    // 1. Vérifier que l'actionnaire existe
    const { data: sh, error: shErr } = await supabaseAdmin
      .from('shareholders')
      .select('id, full_name, user_id, status')
      .eq('id', id)
      .single();

    if (shErr || !sh) {
      res.status(404).json({ success: false, error: 'Actionnaire introuvable' });
      return;
    }

    // 2. Bloquer si paiements en attente
    const { data: pending } = await supabaseAdmin
      .from('shareholder_payments')
      .select('id')
      .eq('shareholder_id', id)
      .in('status', ['pending', 'approved'])
      .limit(1);

    if (pending && pending.length > 0) {
      res.status(409).json({
        success: false,
        error: 'Impossible de supprimer : des paiements sont en attente ou approuvés. Traitez-les d\'abord.',
      });
      return;
    }

    // 3. Archiver l'assignment
    await supabaseAdmin
      .from('shareholder_assignments')
      .update({ status: 'archived' })
      .eq('shareholder_id', id);

    // 4. Archiver la fiche actionnaire
    const { error: archiveErr } = await supabaseAdmin
      .from('shareholders')
      .update({ status: 'archived' })
      .eq('id', id);

    if (archiveErr) {
      res.status(500).json({ success: false, error: archiveErr.message });
      return;
    }

    // 5. Désactiver le compte auth (non bloquant — on archive quoi qu'il arrive)
    if (sh.user_id) {
      await supabaseAdmin.auth.admin.updateUserById(sh.user_id, { ban_duration: '876600h' }).catch(() => {});
    }

    // 6. Audit log
    supabaseAdmin.from('shareholder_audit_logs').insert({
      actor_id:    req.user!.id,
      action:      'delete_shareholder',
      entity_type: 'shareholder',
      entity_id:   id,
      old_value:   { full_name: sh.full_name, status: sh.status },
      new_value:   { status: 'archived' },
    });

    logger.info(`shareholders.delete - archived: ${id} (${sh.full_name}) by ${req.user!.id}`);
    res.json({ success: true });
  } catch (err: any) {
    logger.error('shareholders.delete - unhandled:', err.message);
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

// =============================================================================
// PDG : REVENUS
// =============================================================================

/**
 * GET /api/shareholders/revenues
 * Lister tous les revenus calculés (PDG)
 */
router.get('/revenues', requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('shareholder_revenues')
      .select('*, shareholder:shareholders(full_name)')
      .order('created_at', { ascending: false });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    const revenues = (data || []).map((r: any) => ({
      ...r,
      shareholder_name: r.shareholder?.full_name,
    }));

    res.json({ success: true, data: revenues });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/shareholders/revenues/calculate
 * Calculer les revenus d'un assignment pour une période
 */
router.post('/revenues/calculate', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { assignment_id, period_start, period_end } = req.body;

    if (!assignment_id || !period_start || !period_end) {
      res.status(400).json({ success: false, error: 'assignment_id, period_start et period_end requis' });
      return;
    }

    const { data, error } = await supabaseAdmin.rpc('calculate_shareholder_revenue', {
      p_assignment_id: assignment_id,
      p_period_start:  period_start,
      p_period_end:    period_end,
    });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    if (data?.error) {
      res.status(400).json({ success: false, error: data.error });
      return;
    }

    res.json({ success: true, data });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/shareholders/revenues/save
 * Enregistrer un revenu calculé
 */
router.post('/revenues/save', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const result = req.body;

    const { data, error } = await supabaseAdmin
      .from('shareholder_revenues')
      .insert({
        shareholder_id:           result.shareholder_id,
        assignment_id:            result.assignment_id,
        category:                 result.category,
        period_start:             result.period_start,
        period_end:               result.period_end,
        action_scope:             result.action_scope,
        country:                  result.country || null,
        paid_subscriptions_count: result.paid_subscriptions_count || 0,
        free_subscriptions_count: result.free_subscriptions_count || 0,
        total_paid_revenue_brut:  result.total_paid_revenue_brut  || result.total_paid_revenue || 0,
        total_agent_commission:   result.total_agent_commission   || 0,
        total_paid_revenue:       result.total_paid_revenue || 0,
        percentage:               result.percentage,
        shareholder_amount:       result.shareholder_amount || 0,
        currency:                 result.currency || 'GNF',
        payment_status:           'pending',
        notes:                    `Calculé par ${req.user!.id}`,
      })
      .select('id')
      .single();

    if (error) {
      // Doublon (période identique) OU chevauchement de période (trigger anti-double-comptage)
      if (error.code === '23505') {
        const isOverlap = /overlapping_revenue_period/i.test(error.message || '');
        res.status(409).json({
          success: false,
          error: isOverlap
            ? 'Cette période chevauche une période de revenu déjà enregistrée pour cet actionnaire. Utilisez des périodes disjointes (évite le double comptage).'
            : 'Revenus déjà calculés pour cette période et cet actionnaire.',
          error_code: 'DUPLICATE_REVENUE',
        });
        return;
      }
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    // Créer le paiement associé
    if (data?.id && result.shareholder_amount > 0) {
      await supabaseAdmin.from('shareholder_payments').insert({
        shareholder_id: result.shareholder_id,
        revenue_id:     data.id,
        amount:         result.shareholder_amount,
        currency:       result.currency || 'GNF',
        status:         'pending',
      });
    }

    res.json({ success: true, revenue_id: data?.id });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

// =============================================================================
// PDG : PAIEMENTS
// =============================================================================

/**
 * GET /api/shareholders/payments
 * Lister tous les paiements (PDG)
 */
router.get('/payments', requireRole(PDG_ROLES), async (_req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('shareholder_payments')
      .select('*, shareholder:shareholders(full_name)')
      .order('created_at', { ascending: false });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    res.json({ success: true, data: data || [] });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/shareholders/payments/:id/approve
 * Approuver un paiement et créditer directement le wallet de l'actionnaire
 */
router.post('/payments/:id/approve', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id } = req.params;

    // Étape 1 : marquer comme approuvé
    const { error: approveError } = await supabaseAdmin
      .from('shareholder_payments')
      .update({
        status:      'approved',
        approved_by: req.user!.id,
        approved_at: new Date().toISOString(),
      })
      .eq('id', id)
      .eq('status', 'pending');

    if (approveError) {
      res.status(500).json({ success: false, error: approveError.message });
      return;
    }

    // Étape 2 : créditer le wallet immédiatement
    const { data: walletData, error: walletError } = await supabaseAdmin.rpc(
      'send_shareholder_payment_to_wallet',
      { p_payment_id: id, p_actor_id: req.user!.id },
    );

    if (walletError) {
      // Paiement approuvé mais wallet échoué — on retourne l'erreur pour que le PDG puisse réessayer
      res.json({
        success:        true,
        sent_to_wallet: false,
        wallet_error:   walletError.message,
      });
      return;
    }

    if (walletData && !walletData.success) {
      res.json({
        success:        true,
        sent_to_wallet: false,
        wallet_error:   walletData.error || 'Erreur envoi wallet',
      });
      return;
    }

    res.json({
      success:          true,
      sent_to_wallet:   true,
      credited_amount:  walletData?.credited_amount,
      wallet_currency:  walletData?.wallet_currency,
    });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/shareholders/payments/:id/send-wallet
 * Envoyer un paiement approuvé dans le wallet de l'actionnaire
 */
router.post('/payments/:id/send-wallet', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id } = req.params;

    const { data, error } = await supabaseAdmin.rpc('send_shareholder_payment_to_wallet', {
      p_payment_id: id,
      p_actor_id:   req.user!.id,
    });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    if (data && !data.success) {
      res.status(400).json({ success: false, error: data.error || 'Échec envoi wallet' });
      return;
    }

    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

// =============================================================================
// ACTIONNAIRE : DASHBOARD PERSONNEL
// =============================================================================

/**
 * GET /api/shareholders/dashboard
 * Dashboard de l'actionnaire connecté
 */
router.get('/dashboard', requireRole(ACTIONNAIRE_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user!.id;

    const { data, error } = await supabaseAdmin.rpc('get_shareholder_dashboard', {
      p_user_id: userId,
    });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    const status = data?.shareholder?.status;
    if (status === 'suspended' || status === 'archived') {
      res.status(403).json({
        success:    false,
        error_code: 'ACCOUNT_SUSPENDED',
        error:      "Votre compte actionnaire est suspendu. Contactez l'administration 224 Solutions.",
      });
      return;
    }

    res.json({ success: true, data });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/shareholders/revenues/me
 * Revenus de l'actionnaire connecté
 */
router.get('/revenues/me', requireRole(ACTIONNAIRE_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: sh } = await supabaseAdmin
      .from('shareholders')
      .select('id')
      .eq('user_id', req.user!.id)
      .single();

    if (!sh) {
      res.json({ success: true, data: [] });
      return;
    }

    const { data, error } = await supabaseAdmin
      .from('shareholder_revenues')
      .select('*')
      .eq('shareholder_id', sh.id)
      .order('period_start', { ascending: false });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    res.json({ success: true, data: data || [] });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/shareholders/payments/me
 * Paiements de l'actionnaire connecté
 */
router.get('/payments/me', requireRole(ACTIONNAIRE_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: sh } = await supabaseAdmin
      .from('shareholders')
      .select('id')
      .eq('user_id', req.user!.id)
      .single();

    if (!sh) {
      res.json({ success: true, data: [] });
      return;
    }

    const { data, error } = await supabaseAdmin
      .from('shareholder_payments')
      .select('*')
      .eq('shareholder_id', sh.id)
      .order('created_at', { ascending: false });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    res.json({ success: true, data: data || [] });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/shareholders/documents
 * Documents visibles par l'actionnaire
 */
router.get('/documents', requireRole(ACTIONNAIRE_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: sh } = await supabaseAdmin
      .from('shareholders')
      .select('id, assignment:shareholder_assignments(category, country, action_scope)')
      .eq('user_id', req.user!.id)
      .single();

    if (!sh) {
      res.json({ success: true, data: [] });
      return;
    }

    const { data, error } = await supabaseAdmin
      .from('shareholder_documents')
      .select('*')
      .or(`visibility.eq.all,shareholder_id.eq.${sh.id}`)
      .order('created_at', { ascending: false });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    res.json({ success: true, data: data || [] });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/shareholders/votes
 * Votes accessibles à l'actionnaire
 */
router.get('/votes', requireRole(ACTIONNAIRE_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: sh } = await supabaseAdmin
      .from('shareholders')
      .select('id')
      .eq('user_id', req.user!.id)
      .single();

    if (!sh) {
      res.json({ success: true, data: [] });
      return;
    }

    const { data: votes, error } = await supabaseAdmin
      .from('shareholder_votes')
      .select('*')
      .in('status', ['open', 'closed'])
      .order('start_date', { ascending: false });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    const voteIds = (votes || []).map((v: any) => v.id);

    // Réponse de l'actionnaire
    const { data: myResponses } = await supabaseAdmin
      .from('shareholder_vote_responses')
      .select('vote_id, choice')
      .eq('shareholder_id', sh.id);

    const responseMap = new Map((myResponses || []).map((r: any) => [r.vote_id, r.choice]));

    // Totaux pour tous les votes
    const { data: allResponses } = voteIds.length > 0
      ? await supabaseAdmin
          .from('shareholder_vote_responses')
          .select('vote_id, choice')
          .in('vote_id', voteIds)
      : { data: [] as any[] };

    const totalsByVote = new Map<string, { yes: number; no: number; abstain: number }>();
    for (const r of (allResponses || []) as any[]) {
      if (!totalsByVote.has(r.vote_id)) totalsByVote.set(r.vote_id, { yes: 0, no: 0, abstain: 0 });
      const t = totalsByVote.get(r.vote_id)!;
      if (r.choice === 'yes') t.yes++;
      else if (r.choice === 'no') t.no++;
      else if (r.choice === 'abstain') t.abstain++;
    }

    const enrichedVotes = (votes || []).map((v: any) => {
      const t = totalsByVote.get(v.id) ?? { yes: 0, no: 0, abstain: 0 };
      return {
        ...v,
        my_response:   responseMap.get(v.id) || null,
        total_yes:     t.yes,
        total_no:      t.no,
        total_abstain: t.abstain,
        total_votes:   t.yes + t.no + t.abstain,
      };
    });

    res.json({ success: true, data: enrichedVotes });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/shareholders/votes/:id/respond
 * Soumettre un vote
 */
router.post('/votes/:id/respond', requireRole(ACTIONNAIRE_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id: voteId } = req.params;
    const { choice } = req.body;

    if (!['yes', 'no', 'abstain'].includes(choice)) {
      res.status(400).json({ success: false, error: 'choice doit être yes, no ou abstain' });
      return;
    }

    const { data: sh } = await supabaseAdmin
      .from('shareholders')
      .select('id')
      .eq('user_id', req.user!.id)
      .single();

    if (!sh) {
      res.status(403).json({ success: false, error: 'Actionnaire non trouvé' });
      return;
    }

    const { error } = await supabaseAdmin
      .from('shareholder_vote_responses')
      .upsert({
        vote_id:        voteId,
        shareholder_id: sh.id,
        choice,
        vote_weight:    1,
      }, { onConflict: 'vote_id,shareholder_id' });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

// =============================================================================
// PDG : GESTION DES VOTES
// =============================================================================

/**
 * GET /api/shareholders/votes/all
 * Lister tous les votes avec résultats (PDG)
 */
router.get('/votes/all', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: votes, error } = await supabaseAdmin
      .from('shareholder_votes')
      .select('*')
      .order('created_at', { ascending: false });

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    const voteIds = (votes || []).map((v: any) => v.id);
    const { data: allResponses } = voteIds.length > 0
      ? await supabaseAdmin
          .from('shareholder_vote_responses')
          .select('vote_id, choice')
          .in('vote_id', voteIds)
      : { data: [] as any[] };

    const totalsByVote = new Map<string, { yes: number; no: number; abstain: number }>();
    for (const r of (allResponses || []) as any[]) {
      if (!totalsByVote.has(r.vote_id)) totalsByVote.set(r.vote_id, { yes: 0, no: 0, abstain: 0 });
      const t = totalsByVote.get(r.vote_id)!;
      if (r.choice === 'yes') t.yes++;
      else if (r.choice === 'no') t.no++;
      else if (r.choice === 'abstain') t.abstain++;
    }

    const enriched = (votes || []).map((v: any) => {
      const t = totalsByVote.get(v.id) ?? { yes: 0, no: 0, abstain: 0 };
      return { ...v, total_yes: t.yes, total_no: t.no, total_abstain: t.abstain, total_votes: t.yes + t.no + t.abstain };
    });

    res.json({ success: true, data: enriched });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/shareholders/votes
 * Créer un vote (PDG)
 */
router.post('/votes', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { title, description, start_date, end_date, vote_type, target_type, category, country, shareholder_id } = req.body;

    if (!title || !start_date || !end_date || !vote_type || !target_type) {
      res.status(400).json({ success: false, error: 'Champs requis : title, start_date, end_date, vote_type, target_type' });
      return;
    }

    const { data, error } = await supabaseAdmin
      .from('shareholder_votes')
      .insert({
        title,
        description:    description || null,
        start_date,
        end_date,
        vote_type,
        target_type,
        category:       category || null,
        country:        country || null,
        shareholder_id: shareholder_id || null,
        status:         'draft',
        created_by:     req.user!.id,
      })
      .select('id')
      .single();

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    res.json({ success: true, vote_id: data.id });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * PUT /api/shareholders/votes/:voteId
 * Modifier un vote en brouillon (PDG)
 */
router.put('/votes/:voteId', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { voteId } = req.params;

    const { data: existing } = await supabaseAdmin
      .from('shareholder_votes').select('status').eq('id', voteId).single();

    if (!existing) { res.status(404).json({ success: false, error: 'Vote introuvable' }); return; }
    if (existing.status !== 'draft') {
      res.status(409).json({ success: false, error: 'Seuls les brouillons peuvent être modifiés' });
      return;
    }

    const { title, description, start_date, end_date, vote_type, target_type, category, country, shareholder_id } = req.body;

    const { error } = await supabaseAdmin
      .from('shareholder_votes')
      .update({
        title, description: description || null, start_date, end_date,
        vote_type, target_type, category: category || null,
        country: country || null, shareholder_id: shareholder_id || null,
        updated_at: new Date().toISOString(),
      })
      .eq('id', voteId);

    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/shareholders/votes/:voteId/publish
 * Publier un brouillon (draft → open) (PDG)
 */
router.post('/votes/:voteId/publish', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { voteId } = req.params;
    const { data: v } = await supabaseAdmin.from('shareholder_votes').select('status').eq('id', voteId).single();
    if (!v) { res.status(404).json({ success: false, error: 'Vote introuvable' }); return; }
    if (v.status !== 'draft') { res.status(409).json({ success: false, error: 'Seuls les brouillons peuvent être publiés' }); return; }

    const { error } = await supabaseAdmin
      .from('shareholder_votes')
      .update({ status: 'open', updated_at: new Date().toISOString() })
      .eq('id', voteId);

    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/shareholders/votes/:voteId/close
 * Clôturer un vote ouvert (open → closed) (PDG)
 */
router.post('/votes/:voteId/close', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { voteId } = req.params;
    const { data: v } = await supabaseAdmin.from('shareholder_votes').select('status').eq('id', voteId).single();
    if (!v) { res.status(404).json({ success: false, error: 'Vote introuvable' }); return; }
    if (v.status !== 'open') { res.status(409).json({ success: false, error: 'Seuls les votes ouverts peuvent être clôturés' }); return; }

    const { error } = await supabaseAdmin
      .from('shareholder_votes')
      .update({ status: 'closed', updated_at: new Date().toISOString() })
      .eq('id', voteId);

    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * POST /api/shareholders/votes/:voteId/cancel
 * Annuler un vote (PDG)
 */
router.post('/votes/:voteId/cancel', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { voteId } = req.params;
    const { data: v } = await supabaseAdmin.from('shareholder_votes').select('status').eq('id', voteId).single();
    if (!v) { res.status(404).json({ success: false, error: 'Vote introuvable' }); return; }
    if (v.status === 'closed') { res.status(409).json({ success: false, error: 'Un vote clôturé ne peut pas être annulé' }); return; }

    const { error } = await supabaseAdmin
      .from('shareholder_votes')
      .update({ status: 'cancelled', updated_at: new Date().toISOString() })
      .eq('id', voteId);

    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * DELETE /api/shareholders/votes/:voteId
 * Supprimer un brouillon (PDG)
 */
router.delete('/votes/:voteId', requireRole(PDG_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { voteId } = req.params;
    const { data: v } = await supabaseAdmin.from('shareholder_votes').select('status').eq('id', voteId).single();
    if (!v) { res.status(404).json({ success: false, error: 'Vote introuvable' }); return; }
    if (v.status !== 'draft') { res.status(409).json({ success: false, error: 'Seuls les brouillons peuvent être supprimés' }); return; }

    const { error } = await supabaseAdmin.from('shareholder_votes').delete().eq('id', voteId);
    if (error) { res.status(500).json({ success: false, error: error.message }); return; }
    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/shareholders/notifications
 * Notifications de l'actionnaire
 */
router.get('/notifications', requireRole(ACTIONNAIRE_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabaseAdmin
      .from('notifications')
      .select('*')
      .eq('user_id', req.user!.id)
      .order('created_at', { ascending: false })
      .limit(50);

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    res.json({ success: true, data: data || [] });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * PUT /api/shareholders/notifications/:id/read
 * Marquer une notification comme lue
 */
router.put('/notifications/:id/read', requireRole(ACTIONNAIRE_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id } = req.params;

    const { error } = await supabaseAdmin
      .from('notifications')
      .update({ read: true })
      .eq('id', id)
      .eq('user_id', req.user!.id);

    if (error) {
      res.status(500).json({ success: false, error: error.message });
      return;
    }

    res.json({ success: true });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

/**
 * GET /api/shareholders/subscriptions
 * Abonnements/achats dans le périmètre de l'actionnaire
 */
router.get('/subscriptions', requireRole(ACTIONNAIRE_ROLES), async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data: sh } = await supabaseAdmin
      .from('shareholders')
      .select('id, assignment:shareholder_assignments(*)')
      .eq('user_id', req.user!.id)
      .single();

    if (!sh) {
      res.json({ success: true, data: [] });
      return;
    }

    const assignment: any = Array.isArray(sh.assignment) ? sh.assignment[0] : sh.assignment;
    if (!assignment) {
      res.json({ success: true, data: [] });
      return;
    }

    const { category, action_scope: scope, country } = assignment;
    const subs = await fetchSubscriptions(category, scope, country);

    res.json({ success: true, data: subs });
  } catch (err: any) {
    res.status(500).json({ success: false, error: 'Erreur interne' });
  }
});

// =============================================================================
// HELPER : Charger les abonnements par catégorie + portée
// =============================================================================

async function fetchSubscriptions(
  category: string,
  scope: string,
  country: string | null,
): Promise<any[]> {
  try {
    if (category === 'taxi' || category === 'delivery_driver') {
      const driverType = category === 'taxi' ? 'taxi' : 'livreur';

      const { data } = await supabaseAdmin
        .from('driver_subscriptions')
        .select(`
          id, user_id, type, price, status, payment_method,
          offered_by_ceo, payment_status, start_date, end_date, created_at,
          profile:profiles!user_id(first_name, last_name, email, country, detected_country)
        `)
        .eq('type', driverType)
        .order('start_date', { ascending: false });

      return ((data || []) as any[])
        .filter(s =>
          scope === 'global' ||
          coalesceCountry(s.profile) === country,
        )
        .map(s => ({
          id:                 s.id,
          user_id:            s.user_id,
          category,
          amount:             s.price,
          currency:           'GNF',
          status:             s.status,
          is_paid:            !s.offered_by_ceo && s.payment_status !== 'pending',
          start_date:         s.start_date,
          type:               s.type,
          subscriber_name:    `${s.profile?.first_name || ''} ${s.profile?.last_name || ''}`.trim() || 'Inconnu',
          subscriber_country: coalesceCountry(s.profile),
        }));
    }

    if (category === 'service') {
      const { data } = await supabaseAdmin
        .from('service_subscriptions')
        .select(`
          id, user_id, status, price_paid_gnf, billing_cycle,
          offered_by_ceo, started_at, current_period_end,
          ps:professional_services!professional_service_id(
            user_id, business_name,
            profile:profiles!user_id(first_name, last_name, country, detected_country)
          )
        `)
        .order('started_at', { ascending: false });

      return ((data || []) as any[])
        .filter(s =>
          scope === 'global' ||
          coalesceCountry(s.ps?.profile) === country,
        )
        .map(s => ({
          id:                 s.id,
          user_id:            s.ps?.user_id,
          category:           'service',
          amount:             s.price_paid_gnf,
          currency:           'GNF',
          status:             s.status,
          is_paid:            !s.offered_by_ceo && s.price_paid_gnf > 0,
          start_date:         s.started_at,
          subscriber_name:    s.ps?.business_name || 'Prestataire',
          subscriber_country: coalesceCountry(s.ps?.profile),
        }));
    }

    if (category === 'seller') {
      // Noms de pays par code (pour le fallback sur vendors.country)
      const COUNTRY_NAME_BY_CODE: Record<string, string> = {
        GN: 'Guinée', SN: 'Sénégal', ML: 'Mali', CI: "Côte d'Ivoire",
        BF: 'Burkina Faso', NE: 'Niger', TG: 'Togo', BJ: 'Bénin',
        CM: 'Cameroun', CD: 'Congo', CG: 'Congo', GA: 'Gabon',
        FR: 'France', BE: 'Belgique',
      };

      // 1. Vendors avec seller_country_code correct (tous is_active)
      // On exclut business_type='digital' : les vendeurs numériques ont leur propre catégorie
      let vendorQuery = supabaseAdmin
        .from('vendors')
        .select('user_id, business_name, seller_country_code, is_active')
        .neq('business_type', 'digital');

      if (scope === 'country' && country) {
        vendorQuery = vendorQuery.eq('seller_country_code', country) as typeof vendorQuery;
      }

      const { data: primaryData } = await vendorQuery;

      // 2. Fallback : vendors avec seller_country_code null mais country name correspondant
      // (exclure aussi les digitaux)
      let fallbackVendors: any[] = [];
      if (scope === 'country' && country) {
        const countryName = COUNTRY_NAME_BY_CODE[country] ?? country;
        const { data: fallback } = await supabaseAdmin
          .from('vendors')
          .select('user_id, business_name, seller_country_code, is_active')
          .is('seller_country_code', null)
          .ilike('country', `%${countryName.split(' ')[0]}%`)
          .neq('business_type', 'digital');
        fallbackVendors = (fallback || []) as any[];
      }

      // Fusionner sans doublons
      const seen = new Set((primaryData || []).map((v: any) => v.user_id));
      const vendors = [
        ...(primaryData || []),
        ...fallbackVendors.filter(v => !seen.has(v.user_id)).map(v => ({
          ...v,
          seller_country_code: country,
        })),
      ] as any[];
      if (vendors.length === 0) return [];

      const vendorMap  = new Map(vendors.map(v => [v.user_id, v]));
      const vendorIds  = vendors.map(v => v.user_id as string);

      // Récupérer les abonnements de ces boutiques vendeurs
      const { data: subsData } = await supabaseAdmin
        .from('subscriptions')
        .select('id, user_id, price_paid_gnf, billing_cycle, status, started_at, payment_method, created_at')
        .in('user_id', vendorIds)
        .order('created_at', { ascending: false });

      const subRows = ((subsData || []) as any[]).map(s => {
        const vendor = vendorMap.get(s.user_id);
        return {
          id:                 s.id,
          user_id:            s.user_id,
          category:           'seller',
          amount:             s.price_paid_gnf ?? 0,
          currency:           'GNF',
          status:             s.status,
          is_paid:            (s.price_paid_gnf ?? 0) > 0,
          payment_method:     s.payment_method ?? null,
          billing_cycle:      s.billing_cycle ?? null,
          is_active_vendor:   vendor?.is_active ?? true,
          start_date:         s.started_at || s.created_at,
          subscriber_name:    vendor?.business_name || 'Boutique',
          subscriber_country: vendor?.seller_country_code ?? country,
        };
      });

      // Ajouter les vendors qui n'ont AUCUN abonnement (status: 'none')
      const vendorsWithSub = new Set((subsData || []).map((s: any) => s.user_id));
      const noSubEntries = vendors
        .filter(v => !vendorsWithSub.has(v.user_id))
        .map(v => ({
          id:                 `no_sub_${v.user_id}`,
          user_id:            v.user_id,
          category:           'seller',
          amount:             0,
          currency:           'GNF',
          status:             'none',
          is_paid:            false,
          is_active_vendor:   v.is_active ?? true,
          start_date:         null,
          subscriber_name:    v.business_name || 'Boutique',
          subscriber_country: v.seller_country_code ?? country,
        }));

      return [...subRows, ...noSubEntries];
    }

    if (category === 'digital_vendor') {
      const { data: purchases } = await supabaseAdmin
        .from('digital_product_purchases')
        .select('id, merchant_id, amount, payment_status, created_at, product:digital_products!product_id(title)')
        .eq('payment_status', 'completed')
        .order('created_at', { ascending: false });

      const rows = (purchases || []) as any[];
      const merchantIds = [...new Set(rows.map(p => p.merchant_id as string))];

      const { data: profilesData } = merchantIds.length > 0
        ? await supabaseAdmin
            .from('profiles')
            .select('id, first_name, last_name, country, detected_country')
            .in('id', merchantIds)
        : { data: [] as any[] };

      const profileMap = new Map(((profilesData || []) as any[]).map(p => [p.id, p]));

      return rows
        .filter(s => {
          const prof = profileMap.get(s.merchant_id);
          return scope === 'global' || coalesceCountry(prof) === country;
        })
        .map(s => {
          const prof = profileMap.get(s.merchant_id);
          return {
            id:                 s.id,
            user_id:            s.merchant_id,
            category:           'digital_vendor',
            amount:             s.amount,
            currency:           'GNF',
            status:             s.payment_status,
            is_paid:            s.amount > 0,
            start_date:         s.created_at,
            type:               s.product?.title ?? 'Produit numérique',
            subscriber_name:    prof
              ? `${prof.first_name || ''} ${prof.last_name || ''}`.trim() || 'Vendeur'
              : 'Vendeur',
            subscriber_country: coalesceCountry(prof),
          };
        });
    }

    return [];
  } catch (err: any) {
    logger.error('shareholders.fetchSubscriptions:', err.message);
    return [];
  }
}

export default router;
