-- ============================================================================
-- 🏦 VOLET 7A — reporting revenus du coffre (jour/semaine/mois/année) : entrées ET sorties
-- ----------------------------------------------------------------------------
-- get_pdg_revenue_report(granularité, from, to) : total période, ventilation par
-- source_type, série temporelle, solde actuel du coffre, total redistribué (agents +
-- actionnaires) sur la période. Le PDG voit ce qui ENTRE et ce qui SORT.
-- Migration livrée — NON exécutée.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_pdg_revenue_report(
  p_granularity text DEFAULT 'day',
  p_from timestamptz DEFAULT (now() - interval '30 days'),
  p_to   timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_gran text := CASE WHEN p_granularity IN ('day','week','month','year') THEN p_granularity ELSE 'day' END;
  v_pdg_user_id uuid;
  v_balance numeric := 0;
  v_total numeric := 0;
  v_by_source jsonb;
  v_series jsonb;
  v_redistributed numeric := 0;
BEGIN
  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  SELECT COALESCE(balance,0) INTO v_balance FROM public.wallets WHERE user_id = v_pdg_user_id AND currency = 'GNF';

  SELECT COALESCE(sum(amount),0) INTO v_total FROM public.revenus_pdg
  WHERE created_at >= p_from AND created_at < p_to;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('source_type', s.source_type, 'total', s.total) ORDER BY s.total DESC), '[]'::jsonb)
  INTO v_by_source
  FROM (SELECT source_type, sum(amount) AS total FROM public.revenus_pdg
        WHERE created_at >= p_from AND created_at < p_to GROUP BY source_type) s;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('bucket', b.bucket, 'total', b.total) ORDER BY b.bucket), '[]'::jsonb)
  INTO v_series
  FROM (SELECT date_trunc(v_gran, created_at) AS bucket, sum(amount) AS total FROM public.revenus_pdg
        WHERE created_at >= p_from AND created_at < p_to GROUP BY 1) b;

  -- Total redistribué sur la période = commissions agents (platform_revenue payouts) +
  -- versements actionnaires (débits coffre shareholder_payout).
  SELECT COALESCE(sum(abs(amount)),0) INTO v_redistributed FROM (
    SELECT amount FROM public.platform_revenue
    WHERE revenue_type = 'agent_commission_payout' AND created_at >= p_from AND created_at < p_to
    UNION ALL
    SELECT -net_amount FROM public.wallet_transactions
    WHERE transaction_id LIKE 'shareholder_payout:%' AND created_at >= p_from AND created_at < p_to
  ) r;

  RETURN jsonb_build_object(
    'granularity', v_gran, 'from', p_from, 'to', p_to,
    'total_revenue', v_total, 'by_source', v_by_source, 'series', v_series,
    'treasury_balance', v_balance, 'total_redistributed', v_redistributed,
    'net', v_total - v_redistributed);
END;
$$;

REVOKE ALL ON FUNCTION public.get_pdg_revenue_report(text, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_pdg_revenue_report(text, timestamptz, timestamptz) TO service_role;

SELECT '✅ get_pdg_revenue_report livré (jour/semaine/mois/année, entrées + sorties)' AS status;
