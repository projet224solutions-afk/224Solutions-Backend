-- ════════════════════════════════════════════════════════════════════════════
-- FIX — check_commission_conservation : profiles.role est un ENUM (user_role),
-- pas du texte → lower(role) échoue. On caste : lower(role::text).
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.check_commission_conservation(p_days int DEFAULT 7)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_agents  numeric;
  v_pdg_out numeric;
  v_ecart   numeric;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND lower(role::text) IN ('pdg', 'ceo', 'admin')
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE');
  END IF;

  SELECT COALESCE(sum(amount), 0) INTO v_agents
  FROM public.agent_commissions_log
  WHERE status = 'validated' AND created_at > now() - (p_days || ' days')::interval;

  SELECT COALESCE(sum(-amount), 0) INTO v_pdg_out
  FROM public.platform_revenue
  WHERE revenue_type = 'agent_commission_payout'
    AND created_at > now() - (p_days || ' days')::interval;

  v_ecart := v_agents - v_pdg_out;
  RETURN jsonb_build_object(
    'success', true,
    'period_days', p_days,
    'total_verse_agents', v_agents,
    'total_debite_pdg', v_pdg_out,
    'ecart', v_ecart,
    'conservation_ok', (abs(v_ecart) < 1)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.check_commission_conservation(int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.check_commission_conservation(int) TO authenticated, service_role;

COMMIT;
