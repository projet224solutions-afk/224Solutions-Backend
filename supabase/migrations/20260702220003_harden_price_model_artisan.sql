-- ============================================================================
-- DURCISSEMENT ATOMIQUE — ARTISAN : garde de crédit (ROLLBACK si non crédité)
-- ----------------------------------------------------------------------------
-- Déjà idempotent par phase (source_txn_id = p_idempotency_key, fix bcb8522).
-- On ajoute la GARDE : le crédit artisan DOIT avoir eu lieu (ni skip fantôme ni 0)
-- sinon EXCEPTION → ROLLBACK total → on ne met jamais amount_paid à jour sans que
-- l'artisan soit crédité. Le débit client + les crédits sont dans la MÊME
-- transaction (tout-ou-rien). Commission agent (créateur) inchangée, non bloquante.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.artisan_settle_payment_internal(
  p_intervention_id uuid, p_client uuid, p_artisan uuid, p_service_type text,
  p_amount numeric, p_idempotency_key text, p_label text
) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rate numeric; v_commission numeric; v_pdg uuid; v_res jsonb; v_got numeric;
BEGIN
  IF COALESCE(p_amount,0) <= 0 THEN RETURN 0; END IF;

  SELECT COALESCE(commission_rate, 5) INTO v_rate FROM public.service_types WHERE code = p_service_type;
  v_commission := round(p_amount * COALESCE(v_rate,5) / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  -- 1) Débit client = montant + COMMISSION (idempotence forte par p_idempotency_key).
  PERFORM public.wallet_debit_internal(p_client, p_amount + v_commission, p_label, p_idempotency_key);
  -- 2) Crédit artisan du montant COMPLET (idempotence par phase + garde ROLLBACK).
  v_res := public.credit_user_wallet_safe(p_artisan, p_amount, 'GNF', 'artisan_payment', p_idempotency_key);
  v_got := COALESCE((v_res->>'credited')::numeric,0) + COALESCE((v_res->>'quarantined')::numeric,0);
  IF NOT COALESCE((v_res->>'skipped')::boolean, false) AND v_got <= 0 THEN RAISE EXCEPTION 'CREDIT_ARTISAN_ECHOUE (%)', COALESCE(v_res->>'error','?'); END IF;
  -- 3) Commission plateforme au PDG.
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'artisan_commission', p_idempotency_key);
    -- Commission AGENT au créateur (= l'artisan), débitée du PDG, NON bloquante.
    BEGIN
      PERFORM public.credit_agent_commission(p_artisan, v_commission, 'artisan', md5(p_idempotency_key)::uuid,
        jsonb_build_object('currency', 'GNF', 'flow', 'artisan', 'intervention_id', p_intervention_id, 'phase', p_idempotency_key));
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'commission agent artisan non appliquée (% / %): %', p_intervention_id, p_idempotency_key, SQLERRM;
    END;
  END IF;

  UPDATE public.artisan_interventions
    SET amount_paid = amount_paid + p_amount, commission_total = commission_total + v_commission
    WHERE id = p_intervention_id;

  RETURN v_commission;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.artisan_settle_payment_internal(uuid, uuid, uuid, text, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.artisan_settle_payment_internal(uuid, uuid, uuid, text, numeric, text, text) TO service_role;

SELECT 'Artisan durci : garde de crédit artisan (ROLLBACK si non crédité), idempotence par phase conservée.' AS status;
