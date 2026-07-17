-- 💸 Rattrapage GLOBAL des versements d'affiliation différés (seuil non atteint
-- au moment de la confirmation) : parcourt tous les affiliés ayant du solde
-- confirmé-non-payé et rejoue process_affiliate_payout (qui ne verse QUE si le
-- seuil est atteint — sinon le cumul continue). Appelé par le job quotidien
-- affiliate.payouts-retry et par le bouton PDG.
CREATE OR REPLACE FUNCTION public.process_affiliate_payouts_all()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_aff uuid;
  v_res jsonb;
  v_affiliates int := 0;
  v_paid int := 0;
BEGIN
  FOR v_aff IN
    SELECT DISTINCT affiliate_user_id FROM public.affiliate_commissions
    WHERE status = 'confirmed' AND paid_at IS NULL
  LOOP
    v_affiliates := v_affiliates + 1;
    v_res := public.process_affiliate_payout(v_aff);
    v_paid := v_paid + COALESCE((v_res->>'paid')::int, 0);
  END LOOP;
  RETURN jsonb_build_object('success', true, 'affiliates_scanned', v_affiliates, 'commissions_paid', v_paid);
END;
$$;
REVOKE ALL ON FUNCTION public.process_affiliate_payouts_all() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_affiliate_payouts_all() TO service_role;
