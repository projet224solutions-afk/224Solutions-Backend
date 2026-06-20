-- ============================================================================
-- MIGRATION: Fix calculate_shareholder_revenue — catégorie seller
--
-- PROBLÈME :
--   1. La branche 'seller' interrogeait vendor_subscriptions (table vide).
--      Les vendeurs physiques/hybrides s'abonnent via la table subscriptions.
--   2. Le calcul utilisait le montant BRUT (price_paid_gnf) sans déduire
--      la commission de l'agent qui a créé le vendeur.
--
-- CORRECTION :
--   • Interroger subscriptions + JOIN vendors (pour pays + type)
--   • Déduire la commission agent stockée dans subscriptions.metadata :
--       net = price_paid_gnf - COALESCE(metadata->'agent_commission'->>'total_commissions', 0)
--   • GREATEST(0, net) : sécurité contre valeurs négatives
--
-- DONNÉES DISPONIBLES :
--   subscriptions.metadata->'agent_commission'->'total_commissions'
--   → somme agent principal + sous-agent (si applicable)
--   → 0 si aucun agent affilié au vendeur
--
-- EXEMPLES :
--   100 000 GNF (brut) - 20 000 (commission 20%) = 80 000 GNF (net)
--   Actionnaire 5% : 80 000 × 5% = 4 000 GNF  (correct)
--   Avant fix      : 100 000 × 5% = 5 000 GNF  (trop élevé)
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
  v_total_revenue NUMERIC := 0;   -- montant NET (après déduction commissions)
  v_brut_revenue  NUMERIC := 0;   -- montant brut (pour info dans le retour)
  v_commission_deducted NUMERIC := 0;
  v_sh_amount     NUMERIC := 0;
  v_currency      TEXT    := 'GNF';
BEGIN
  -- Récupérer l'assignment
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
      -- Abonnements PAYANTS — montant net = prix - commission agent si applicable
      SELECT
        COUNT(*),
        COALESCE(SUM(ds.price), 0),
        COALESCE(SUM(
          COALESCE(acl.total_agent_commission, 0)
        ), 0)
      INTO v_paid_count, v_brut_revenue, v_commission_deducted
      FROM public.driver_subscriptions ds
      JOIN public.profiles p ON p.id = ds.user_id
      -- Commission agent enregistrée dans agent_commissions_log (transaction_id = ds.id)
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
        AND ds.start_date::date >= p_period_start
        AND ds.start_date::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           COALESCE(p.country, p.detected_country) = v_assignment.country)
        );

      v_total_revenue := GREATEST(0, v_brut_revenue - v_commission_deducted);

      -- Abonnements OFFERTS (comptage uniquement)
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
           COALESCE(p.country, p.detected_country) = v_assignment.country)
        );
    END;

  -- ── SERVICES ───────────────────────────────────────────────────────────────
  ELSIF v_assignment.category = 'service' THEN
    SELECT
      COUNT(*),
      COALESCE(SUM(ss.price_paid_gnf), 0),
      COALESCE(SUM(
        COALESCE(acl.total_agent_commission, 0)
      ), 0)
    INTO v_paid_count, v_brut_revenue, v_commission_deducted
    FROM public.service_subscriptions ss
    JOIN public.professional_services ps ON ps.id = ss.professional_service_id
    JOIN public.profiles p ON p.id = ps.user_id
    -- Commission agent via agent_commissions_log (transaction_id = ss.id)
    LEFT JOIN (
      SELECT transaction_id, SUM(amount) AS total_agent_commission
      FROM public.agent_commissions_log
      WHERE source_type = 'abonnement'
      GROUP BY transaction_id
    ) acl ON acl.transaction_id = ss.id
    WHERE ss.status IN ('active', 'expired', 'past_due')
      AND COALESCE(ss.offered_by_ceo, false) = false
      AND ss.price_paid_gnf > 0
      AND ss.started_at::date >= p_period_start
      AND ss.started_at::date <= p_period_end
      AND (
        v_assignment.action_scope = 'global' OR
        (v_assignment.action_scope = 'country' AND
         COALESCE(p.country, p.detected_country) = v_assignment.country)
      );

    v_total_revenue := GREATEST(0, v_brut_revenue - v_commission_deducted);

    -- Offerts service
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
         COALESCE(p.country, p.detected_country) = v_assignment.country)
      );

  -- ── VENDEURS PHYSIQUES / HYBRIDES ──────────────────────────────────────────
  -- Source : table subscriptions (l'ancienne table, alimentée par subscribe_user())
  -- Commission agent stockée dans subscriptions.metadata->'agent_commission'->'total_commissions'
  ELSIF v_assignment.category = 'seller' THEN
    DECLARE
      -- Montant brut et commission extraits en une seule passe
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
        -- Abonnements payants uniquement
        AND s.price_paid_gnf > 0
        -- Exclure les cadeaux PDG et les plans gratuits créés automatiquement
        AND COALESCE(s.payment_method, '') NOT IN ('free_gift', 'free', 'admin')
        AND COALESCE(s.billing_cycle, '')  NOT IN ('lifetime', 'custom')
        -- Exclure les vendeurs numériques (catégorie distincte)
        AND ven.business_type != 'digital'
        -- Filtre période
        AND s.started_at::date >= p_period_start
        AND s.started_at::date <= p_period_end
        -- Filtre périmètre géographique (seller_country_code = code ISO pays)
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           ven.seller_country_code = v_assignment.country)
        );

      -- Montant NET = brut - commissions agents (jamais négatif)
      v_total_revenue := GREATEST(0, v_brut_revenue - v_commission_deducted);

      -- Offerts PDG : payment_method='free_gift' OU billing_cycle='custom'
      SELECT COUNT(*)
      INTO v_free_count
      FROM public.subscriptions s
      JOIN public.vendors ven ON ven.user_id = s.user_id
      WHERE s.status IN ('active', 'expired')
        AND (
          s.payment_method = 'free_gift' OR
          s.billing_cycle  = 'custom'
        )
        AND ven.business_type != 'digital'
        AND s.started_at::date >= p_period_start
        AND s.started_at::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           ven.seller_country_code = v_assignment.country)
        );
    END;

  -- ── VENDEURS NUMÉRIQUES ────────────────────────────────────────────────────
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
        COALESCE(SUM(dpp.amount), 0),
        0  -- pas de commission agent sur les achats de produits numériques
      INTO v_paid_count, v_brut_revenue, v_commission_deducted
      FROM public.digital_product_purchases dpp
      JOIN public.profiles p ON p.id = dpp.merchant_id
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
           COALESCE(p.country, p.detected_country) = v_assignment.country)
        );

      v_total_revenue := v_brut_revenue;  -- pas de déduction pour digital

      SELECT COUNT(*)
      INTO v_free_count
      FROM public.digital_product_purchases dpp
      JOIN public.profiles p ON p.id = dpp.merchant_id
      WHERE dpp.payment_status = 'completed'
        AND dpp.amount = 0
        AND dpp.created_at::date >= p_period_start
        AND dpp.created_at::date <= p_period_end
        AND (
          v_assignment.action_scope = 'global' OR
          (v_assignment.action_scope = 'country' AND
           COALESCE(p.country, p.detected_country) = v_assignment.country)
        );
    END;
  END IF;

  -- ── Calculer la part de l'actionnaire sur le montant NET ──────────────────
  v_sh_amount := v_total_revenue * (v_assignment.percentage / 100.0);

  RETURN jsonb_build_object(
    'assignment_id',              p_assignment_id,
    'shareholder_id',             v_assignment.shareholder_id,
    'category',                   v_assignment.category,
    'action_scope',               v_assignment.action_scope,
    'country',                    v_assignment.country,
    'paid_subscriptions_count',   v_paid_count,
    'free_subscriptions_count',   v_free_count,
    -- Montants détaillés pour transparence
    'total_paid_revenue_brut',    v_brut_revenue,
    'total_agent_commission',     v_commission_deducted,
    'total_paid_revenue',         v_total_revenue,   -- NET (base de calcul actionnaire)
    'percentage',                 v_assignment.percentage,
    'shareholder_amount',         v_sh_amount,
    'currency',                   v_currency,
    'period_start',               p_period_start,
    'period_end',                 p_period_end
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_shareholder_revenue(UUID, DATE, DATE)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.calculate_shareholder_revenue IS
  'Calcule le revenu d''un actionnaire sur une période.
   Pour chaque catégorie, déduit les commissions agents du montant brut
   avant d''appliquer le pourcentage de l''actionnaire.
   Seller : base = subscriptions.price_paid_gnf - metadata->agent_commission->total_commissions
   Taxi/Service : base = prix - SUM(agent_commissions_log.amount) pour le même transaction_id';
