-- ============================================================================
-- PHASE 1 (correctif) — BRANCHER commission_rate DES PLANS DANS LE RÈGLEMENT
-- ----------------------------------------------------------------------------
-- commission_rate (resto 15→5%, e-com 10→3%…) était stockée mais JAMAIS lue :
-- gb_settle_to_vendor_internal prélevait 5% en dur. On ajoute un helper réutilisable
-- qui résout le taux depuis le plan d'abonnement ACTIF du vendeur, avec repli sur un
-- défaut (⇒ comportement INCHANGÉ tant que le vendeur n'a pas de plan typé actif).
-- Idempotent.
-- ============================================================================

-- Helper : taux de commission (%) du plan actif d'un user pour un type de service donné.
-- Repli sur p_default si aucun plan actif avec commission_rate défini.
CREATE OR REPLACE FUNCTION public.resolve_service_commission_rate(
  p_user_id uuid, p_service_type_code text, p_default numeric
) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rate numeric;
BEGIN
  SELECT sp.commission_rate INTO v_rate
  FROM public.service_subscriptions ss
  JOIN public.service_plans sp        ON sp.id = ss.plan_id
  JOIN public.professional_services psv ON psv.id = ss.professional_service_id
  JOIN public.service_types st        ON st.id = psv.service_type_id
  WHERE psv.user_id = p_user_id
    AND (p_service_type_code IS NULL OR st.code = p_service_type_code)
    AND ss.status = 'active'
    AND ss.current_period_end > now()
    AND sp.commission_rate IS NOT NULL
  ORDER BY ss.current_period_end DESC
  LIMIT 1;
  RETURN COALESCE(v_rate, p_default);
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_service_commission_rate(uuid, text, numeric) FROM PUBLIC;

-- Patch du règlement achat-groupé : commission = taux du plan e-commerce du vendeur
-- (repli 5% comme avant). Net vendeur + commission PDG, atomiques et idempotents.
CREATE OR REPLACE FUNCTION public.gb_settle_to_vendor_internal(p_group uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE g public.group_buys%ROWTYPE; v_total numeric; v_rate numeric; v_commission numeric; v_pdg uuid;
BEGIN
  SELECT * INTO g FROM public.group_buys WHERE id = p_group;
  SELECT COALESCE(sum(amount),0) INTO v_total FROM public.group_buy_participants WHERE group_buy_id = p_group AND NOT refunded;

  v_rate := public.resolve_service_commission_rate(g.vendor_user_id, 'ecommerce', 5.0);
  v_commission := round(v_total * v_rate / 100.0);

  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  IF g.vendor_user_id IS NOT NULL AND v_total > 0 THEN
    PERFORM public.credit_user_wallet_safe(g.vendor_user_id, v_total - v_commission, 'GNF', 'group_buy_payout', p_group::text);
    IF v_pdg IS NOT NULL AND v_commission > 0 THEN
      PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'group_buy_commission', p_group::text);
    END IF;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.gb_settle_to_vendor_internal(uuid) FROM PUBLIC;

SELECT 'Helper commission_rate posé + règlement achat-groupé branché sur le plan vendeur.' AS status;
