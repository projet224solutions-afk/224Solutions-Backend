-- ============================================================================
-- ⚠️ PROPOSITION — NON APPLIQUÉE — À VALIDER PAR THIERNO (change le MODÈLE de revenu)
-- ============================================================================
-- Prérequis à l'automatisation mensuelle du partage de revenus actionnaires.
--
-- DÉFAUT constaté (calcul par période) : les branches `seller`, `taxi/delivery`
-- et `service` de `calculate_shareholder_revenue` bornent par CHEVAUCHEMENT de la
-- fenêtre d'abonnement :
--     started_at <= period_end AND (current_period_end IS NULL OR current_period_end >= period_start)
-- → un abonnement multi-mois (ex. annuel) CHEVAUCHE chaque mois de sa durée, donc
--   son `price_paid_gnf` COMPLET serait recompté à CHAQUE calcul mensuel (jusqu'à ×12).
--   Inoffensif pour un calcul unique sur une large période (chaque abo compté 1×),
--   mais FAUX dès qu'on calcule mois après mois → surversement du coffre PDG.
-- Seule la branche `digital_vendor` borne correctement (dpp.created_at DANS la période).
--
-- CORRECTION proposée : borne CAISSE (« payé dans la période ») alignée sur la branche
-- digital — on compte un abonnement dans le mois où sa période PAYÉE a COMMENCÉ :
--     started_at/start_date DANS [period_start, period_end]
-- Chaque paiement est ainsi compté exactement une fois, dans son mois.
--
-- ⚠️ CE QUI CHANGE / À VALIDER AVANT APPLICATION :
--   1. Le MODÈLE passe de « actif pendant la période » à « payé pendant la période »
--      (base caisse). C'est une décision métier — la revue OHADA/PDG doit la confirmer.
--   2. Hypothèse à confirmer : un RENOUVELLEMENT crée une NOUVELLE ligne (nouveau
--      started_at) OU met à jour started_at. Si le renouvellement ne change PAS
--      started_at, les renouvellements ne seraient pas comptés → il faudrait alors
--      borner sur la vraie date de paiement (colonne dédiée) plutôt que started_at.
--   3. Recalculer l'unique revenu historique existant n'est PAS nécessaire (large
--      période, déjà versé) — cette correction ne vise que le calcul MENSUEL à venir.
--
-- Tant que ceci n'est pas validé+appliqué, le job mensuel NE DOIT PAS être activé.
-- (Interdit : « Ne pas activer le job si la borne temporelle n'est pas confirmée. »)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.calculate_shareholder_revenue(
  p_assignment_id UUID,
  p_period_start  DATE,
  p_period_end    DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_assignment    RECORD;
  v_paid_count    INTEGER := 0;
  v_free_count    INTEGER := 0;
  v_total_revenue NUMERIC := 0;
  v_brut_revenue  NUMERIC := 0;
  v_commission_deducted NUMERIC := 0;
  v_sh_amount     NUMERIC := 0;
  v_currency      TEXT    := 'GNF';
BEGIN
  SELECT sa.*, s.user_id AS shareholder_user_id
  INTO v_assignment
  FROM public.shareholder_assignments sa
  JOIN public.shareholders s ON s.id = sa.shareholder_id
  WHERE sa.id = p_assignment_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Assignment introuvable');
  END IF;

  -- ── TAXI / LIVREUR ─────────────────────────────────────────────────────────
  IF v_assignment.category IN ('taxi', 'delivery_driver') THEN
    DECLARE
      v_driver_type TEXT := CASE
        WHEN v_assignment.category = 'taxi' THEN 'taxi'
        ELSE 'livreur'
      END;
    BEGIN
      SELECT
        COUNT(*),
        COALESCE(SUM(ds.price), 0),
        COALESCE(SUM(COALESCE(acl.total_agent_commission, 0)), 0)
      INTO v_paid_count, v_brut_revenue, v_commission_deducted
      FROM public.driver_subscriptions ds
      JOIN public.profiles p ON p.id = ds.user_id
      LEFT JOIN (
        SELECT transaction_id, SUM(amount) AS total_agent_commission
        FROM public.agent_commissions_log
        WHERE source_type = 'abonnement'
        GROUP BY transaction_id
      ) acl ON acl.transaction_id = ds.id
      WHERE ds.type = v_driver_type
        AND ds.status IN ('active', 'expired')
        AND COALESCE(ds.offered_by_ceo, false) = false
        AND COALESCE(ds.payment_status, 'paid') = 'paid'
        AND ds.price > 0
        AND ds.start_date::date >= p_period_start          -- ⇐ borne caisse (au lieu du chevauchement)
        AND ds.start_date::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           COALESCE(p.country_code, p.country, p.detected_country) = v_assignment.country)
        );

      v_total_revenue := GREATEST(0, v_brut_revenue - v_commission_deducted);

      SELECT COUNT(*)
      INTO v_free_count
      FROM public.driver_subscriptions ds
      JOIN public.profiles p ON p.id = ds.user_id
      WHERE ds.type = v_driver_type
        AND ds.status IN ('active', 'expired')
        AND COALESCE(ds.offered_by_ceo, false) = true
        AND ds.start_date::date >= p_period_start
        AND ds.start_date::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           COALESCE(p.country_code, p.country, p.detected_country) = v_assignment.country)
        );
    END;

  -- ── SERVICES ───────────────────────────────────────────────────────────────
  ELSIF v_assignment.category = 'service' THEN
    SELECT
      COUNT(*),
      COALESCE(SUM(ss.price_paid_gnf), 0),
      COALESCE(SUM(COALESCE(acl.total_agent_commission, 0)), 0)
    INTO v_paid_count, v_brut_revenue, v_commission_deducted
    FROM public.service_subscriptions ss
    JOIN public.professional_services ps ON ps.id = ss.professional_service_id
    JOIN public.profiles p ON p.id = ps.user_id
    LEFT JOIN (
      SELECT transaction_id, SUM(amount) AS total_agent_commission
      FROM public.agent_commissions_log
      WHERE source_type = 'abonnement'
      GROUP BY transaction_id
    ) acl ON acl.transaction_id = ss.id
    WHERE ss.status IN ('active', 'expired', 'past_due')
      AND COALESCE(ss.offered_by_ceo, false) = false
      AND ss.price_paid_gnf > 0
      AND ss.started_at::date >= p_period_start            -- ⇐ borne caisse
      AND ss.started_at::date <= p_period_end
      AND (
        v_assignment.action_scope = 'global' OR
        (v_assignment.action_scope = 'country' AND
         COALESCE(p.country_code, p.country, p.detected_country) = v_assignment.country)
      );

    v_total_revenue := GREATEST(0, v_brut_revenue - v_commission_deducted);

    SELECT COUNT(*)
    INTO v_free_count
    FROM public.service_subscriptions ss
    JOIN public.professional_services ps ON ps.id = ss.professional_service_id
    JOIN public.profiles p ON p.id = ps.user_id
    WHERE ss.status IN ('active', 'expired', 'past_due')
      AND COALESCE(ss.offered_by_ceo, false) = true
      AND ss.started_at::date >= p_period_start
      AND ss.started_at::date <= p_period_end
      AND (
        v_assignment.action_scope = 'global' OR
        (v_assignment.action_scope = 'country' AND
         COALESCE(p.country_code, p.country, p.detected_country) = v_assignment.country)
      );

  -- ── VENDEURS PHYSIQUES / HYBRIDES ──────────────────────────────────────────
  ELSIF v_assignment.category = 'seller' THEN
    DECLARE
    BEGIN
      SELECT
        COUNT(*),
        COALESCE(SUM(s.price_paid_gnf), 0),
        COALESCE(SUM(
          COALESCE(
            (s.metadata -> 'agent_commission' ->> 'total_commissions')::numeric,
            0
          )
        ), 0)
      INTO v_paid_count, v_brut_revenue, v_commission_deducted
      FROM public.subscriptions s
      JOIN public.vendors ven ON ven.user_id = s.user_id
      WHERE s.status IN ('active', 'expired')
        AND s.price_paid_gnf > 0
        AND COALESCE(s.payment_method, '') NOT IN ('free_gift', 'free', 'admin')
        AND COALESCE(s.billing_cycle, '')  NOT IN ('lifetime', 'custom')
        AND ven.business_type != 'digital'
        AND s.started_at::date >= p_period_start           -- ⇐ borne caisse
        AND s.started_at::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           ven.seller_country_code = v_assignment.country)
        );

      v_total_revenue := GREATEST(0, v_brut_revenue - v_commission_deducted);

      SELECT COUNT(*)
      INTO v_free_count
      FROM public.subscriptions s
      JOIN public.vendors ven ON ven.user_id = s.user_id
      WHERE s.status IN ('active', 'expired')
        AND (s.payment_method = 'free_gift' OR s.billing_cycle = 'custom')
        AND ven.business_type != 'digital'
        AND s.started_at::date >= p_period_start
        AND s.started_at::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           ven.seller_country_code = v_assignment.country)
        );
    END;

  -- ── VENDEURS NUMÉRIQUES (déjà borné correctement — INCHANGÉ) ────────────────
  ELSIF v_assignment.category = 'digital_vendor' THEN
    DECLARE
      v_dpp_currency TEXT := CASE
        WHEN v_assignment.action_scope = 'country' AND v_assignment.country IS NOT NULL
        THEN get_currency_for_country(v_assignment.country)
        ELSE 'GNF'
      END;
    BEGIN
      v_currency := v_dpp_currency;

      SELECT
        COUNT(*),
        COALESCE(SUM(dpp.commission_amount), 0),
        0
      INTO v_paid_count, v_brut_revenue, v_commission_deducted
      FROM public.digital_product_purchases dpp
      JOIN public.profiles p ON p.id = dpp.merchant_id
      LEFT JOIN public.vendors ven ON ven.user_id = dpp.merchant_id
      WHERE dpp.payment_status = 'completed'
        AND dpp.amount > 0
        AND (
          dpp.currency = v_dpp_currency
          OR (dpp.currency IS NULL AND v_dpp_currency = 'GNF')
        )
        AND dpp.created_at::date >= p_period_start
        AND dpp.created_at::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           COALESCE(ven.seller_country_code, p.country_code, p.country, p.detected_country) = v_assignment.country)
        );

      v_total_revenue := v_brut_revenue;

      SELECT COUNT(*)
      INTO v_free_count
      FROM public.digital_product_purchases dpp
      JOIN public.profiles p ON p.id = dpp.merchant_id
      LEFT JOIN public.vendors ven ON ven.user_id = dpp.merchant_id
      WHERE dpp.payment_status = 'completed'
        AND dpp.amount = 0
        AND dpp.created_at::date >= p_period_start
        AND dpp.created_at::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           COALESCE(ven.seller_country_code, p.country_code, p.country, p.detected_country) = v_assignment.country)
        );
    END;
  END IF;

  v_sh_amount := v_total_revenue * (v_assignment.percentage / 100.0);

  RETURN jsonb_build_object(
    'assignment_id',              p_assignment_id,
    'shareholder_id',             v_assignment.shareholder_id,
    'category',                   v_assignment.category,
    'action_scope',               v_assignment.action_scope,
    'country',                    v_assignment.country,
    'paid_subscriptions_count',   v_paid_count,
    'free_subscriptions_count',   v_free_count,
    'total_paid_revenue_brut',    ROUND(v_brut_revenue, 0),
    'total_agent_commission',     ROUND(v_commission_deducted, 0),
    'total_paid_revenue',         ROUND(v_total_revenue, 0),
    'percentage',                 v_assignment.percentage,
    'shareholder_amount',         ROUND(v_sh_amount, 0),
    'currency',                   v_currency,
    'period_start',               p_period_start,
    'period_end',                 p_period_end
  );
END;
$$;
