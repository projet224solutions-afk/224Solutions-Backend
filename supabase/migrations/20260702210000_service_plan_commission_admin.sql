-- ============================================================================
-- ADMIN PDG : régler la commission par PLAN de service (source réelle du taux)
-- ----------------------------------------------------------------------------
-- resolve_service_commission_rate lit service_plans.commission_rate. Il n'existait
-- AUCUN moyen de le régler depuis l'interface. On ajoute :
--   • RPC set_service_plan_commission (role-checké admin/PDG) → écrit commission_rate.
--   • 🔒 FIX SÉCURITÉ : la policy « Authenticated users can manage service plans »
--     autorisait N'IMPORTE QUEL utilisateur authentifié à modifier les plans
--     (commission, prix) via USING(true). On la restreint à admin/PDG (lecture
--     publique conservée par la policy SELECT « viewable by everyone »).
-- ============================================================================

-- 🔒 Restreindre l'écriture des plans à admin/PDG (la lecture publique reste ouverte).
DROP POLICY IF EXISTS "Authenticated users can manage service plans" ON public.service_plans;
CREATE POLICY "Admin/PDG manage service plans" ON public.service_plans
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- RPC : régler la commission d'un plan (admin/PDG uniquement, 0..100).
CREATE OR REPLACE FUNCTION public.set_service_plan_commission(p_plan_id uuid, p_commission_rate numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_rate numeric;
BEGIN
  IF NOT public.is_admin_or_pdg((select auth.uid())) THEN
    RAISE EXCEPTION 'NOT_ADMIN';
  END IF;
  IF p_commission_rate IS NULL OR p_commission_rate < 0 OR p_commission_rate > 100 THEN
    RAISE EXCEPTION 'RATE_INVALIDE (0..100)';
  END IF;
  UPDATE public.service_plans
     SET commission_rate = round(p_commission_rate, 2)
   WHERE id = p_plan_id
   RETURNING id, commission_rate INTO v_id, v_rate;
  IF v_id IS NULL THEN RAISE EXCEPTION 'PLAN_INTROUVABLE'; END IF;
  RETURN jsonb_build_object('success', true, 'id', v_id, 'commission_rate', v_rate);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.set_service_plan_commission(uuid, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_service_plan_commission(uuid, numeric) TO authenticated, service_role;

SELECT 'Commission par plan : RPC admin/PDG set_service_plan_commission + policy écriture restreinte.' AS status;
