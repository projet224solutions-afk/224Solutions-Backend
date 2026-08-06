-- ═══════════════════════════════════════════════════════════════════════════
-- FIX BALAYAGE V1 — 3 régressions (migrations NOUVELLES, on n'édite pas l'ancien balayage).
-- FIX 2 : get_pdg/platform_revenue_stats — contrôle de rôle INTERNE (le GRANT authenticated
--          reste, mais la fonction refuse un non-PDG → plus de fuite du CA plateforme).
-- FIX 3 : product_variants — policy corrigée (products.vendor_id → vendors, join sur v.user_id).
-- FIX 1.4 : gardien commission_revenue_gap ÉTENDU aux commandes NON-wallet (carte/mobile money).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── FIX 2 — contrôle de rôle DANS les fonctions de stats de revenu ──────────
CREATE OR REPLACE FUNCTION public.get_pdg_revenue_stats(
  p_start_date timestamptz DEFAULT NULL, p_end_date timestamptz DEFAULT NULL)
RETURNS TABLE(total_revenue numeric, wallet_fees_revenue numeric, purchase_fees_revenue numeric,
  transaction_count bigint, wallet_transaction_count bigint, purchase_transaction_count bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public.is_admin_or_pdg() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  RETURN QUERY
  SELECT
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN source_type = 'frais_transaction_wallet' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN source_type = 'frais_achat_commande' THEN amount ELSE 0 END), 0),
    COUNT(*),
    COUNT(*) FILTER (WHERE source_type = 'frais_transaction_wallet'),
    COUNT(*) FILTER (WHERE source_type = 'frais_achat_commande')
  FROM public.revenus_pdg
  WHERE (p_start_date IS NULL OR created_at >= p_start_date)
    AND (p_end_date IS NULL OR created_at <= p_end_date);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_platform_revenue_stats(
  p_start_date timestamptz DEFAULT NULL, p_end_date timestamptz DEFAULT NULL)
RETURNS TABLE(revenue_type text, total_amount numeric, transaction_count bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  IF NOT public.is_admin_or_pdg() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  RETURN QUERY
  SELECT pr.revenue_type, COALESCE(SUM(pr.amount), 0), COUNT(*)::bigint
  FROM platform_revenue pr
  WHERE (p_start_date IS NULL OR pr.created_at >= p_start_date)
    AND (p_end_date IS NULL OR pr.created_at <= p_end_date)
  GROUP BY pr.revenue_type ORDER BY 2 DESC;
END;
$function$;

-- ── FIX 3 — product_variants : join CORRECT products→vendors→user_id ─────────
-- L'ancienne policy comparait products.vendor_id (= vendors.id) à auth.uid() → ne matchait
-- JAMAIS (tout vendeur bloqué le jour où une UI écrit). On passe par vendors.user_id.
DROP POLICY IF EXISTS product_variants_owner_manage ON public.product_variants;
CREATE POLICY product_variants_owner_manage ON public.product_variants FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.products p
    JOIN public.vendors v ON v.id = p.vendor_id
    WHERE p.id = product_variants.product_id AND v.user_id = auth.uid()))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.products p
    JOIN public.vendors v ON v.id = p.vendor_id
    WHERE p.id = product_variants.product_id AND v.user_id = auth.uid()));

-- ── FIX 1.4 — commission_monitor_report : + gardien commissions NON-wallet ──
-- L'ancien commission_revenue_gap ne regarde que wallet_transactions (wallet only). On AJOUTE
-- un check des commandes NON-wallet PAYÉES (carte/mobile money) sans ligne revenus_pdg
-- 'frais_achat_commande' — gaté par purchase_fee_percent > 0 (sinon commissions désactivées =
-- pas de gap) et excluant les commandes couvertes par le flux Stripe Connect ('frais_achat_marketplace').
CREATE OR REPLACE FUNCTION public.commission_monitor_report()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_gap int; v_badrate int; v_nonpos int; v_gap_nonwallet int; v_fee_pct numeric;
BEGIN
  -- (1) wallet : commission prélevée (wallet_transactions) mais absente de revenus_pdg.
  SELECT count(*) INTO v_gap FROM public.wallet_transactions wt
  WHERE wt.transaction_type = 'commission'
    AND wt.metadata->>'source' = 'buyer_commission'
    AND wt.created_at > now() - interval '7 days'
    AND wt.metadata->>'order_id' IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r WHERE r.metadata->>'order_id' = wt.metadata->>'order_id');

  -- (1bis) NON-wallet : commandes carte/mobile money PAYÉES sans revenu 'frais_achat_commande'.
  SELECT COALESCE((SELECT setting_value::numeric FROM public.system_settings WHERE setting_key = 'purchase_fee_percent'), 0)
    INTO v_fee_pct;
  IF v_fee_pct > 0 THEN
    SELECT count(*) INTO v_gap_nonwallet FROM public.orders o
    WHERE o.payment_status = 'paid'
      AND o.payment_method::text IN ('card', 'mobile_money')  -- carte (Stripe inclus) + mobile money
      AND o.created_at > now() - interval '7 days'
      AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r
        WHERE r.source_type = 'frais_achat_commande' AND r.metadata->>'order_id' = o.id::text)
      AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r
        WHERE r.source_type = 'frais_achat_marketplace' AND r.metadata->>'order_id' = o.id::text);
  ELSE
    v_gap_nonwallet := 0;
  END IF;

  SELECT count(*) INTO v_badrate FROM public.agents_management
  WHERE is_active = true AND (
       COALESCE(commission_rate, 0) < 0 OR COALESCE(commission_rate, 0) > 100
    OR COALESCE(commission_agent_principal, 0) < 0 OR COALESCE(commission_agent_principal, 0) > 100
    OR COALESCE(commission_sous_agent, 0) < 0 OR COALESCE(commission_sous_agent, 0) > 100);

  SELECT count(*) INTO v_nonpos FROM public.revenus_pdg
  WHERE COALESCE(amount, 0) <= 0 AND created_at > now() - interval '7 days';

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','commission_revenue_gap','label','Commission acheteur (wallet) prélevée mais non enregistrée (revenus PDG)','severity','high','count',v_gap,'observed',v_gap),
    jsonb_build_object('key','commission_revenue_gap_nonwallet','label','Commande carte/mobile money payée sans revenu commission (revenus PDG)','severity','high','count',v_gap_nonwallet,'observed',v_gap_nonwallet),
    jsonb_build_object('key','agent_bad_rate','label','Taux de commission agent hors limites (0–100%)','severity','medium','count',v_badrate,'observed',v_badrate),
    jsonb_build_object('key','revenue_nonpositive','label','Revenu PDG nul ou négatif','severity','medium','count',v_nonpos,'observed',v_nonpos)
  ));
END;
$$;
REVOKE ALL ON FUNCTION public.commission_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.commission_monitor_report() TO service_role;
