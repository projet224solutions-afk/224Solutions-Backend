-- ============================================================================
-- 🧾 FIABILISATION des registres OFFLINE (échelonné + ventes à crédit).
--
-- Ces modules sont des registres CASH hors-ligne (client = texte libre, paiements
-- 'cash') : volontairement SANS wallet plateforme. On corrige les VRAIS bugs :
--   • lost-update : remaining_amount/paid_amount étaient recalculés depuis l'état
--     React puis réécrits → un double-clic / 2 onglets corrompait le solde.
--   • credit_sale_payments n'était JAMAIS alimentée (aucun historique de tranches).
--
-- Approche : RPC atomiques (verrou FOR UPDATE) qui RECALCULENT le solde depuis la
-- source (SUM des paiements) → auto-réparant, idempotent, anti-course. Propriété
-- vérifiée via auth.uid() (parité avec la RLS « vendor owner »).
-- ============================================================================

-- ──────────────────────────────────────────────────────────────────────────
-- 1) ÉCHELONNÉ : régler une échéance
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.pay_installment_atomic(p_installment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_plan      public.installment_plans%ROWTYPE;
  v_inst      public.installment_payments%ROWTYPE;
  v_paid_sum  numeric;
  v_remaining numeric;
  v_status    text;
BEGIN
  SELECT * INTO v_inst FROM public.installment_payments WHERE id = p_installment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INSTALLMENT_NOT_FOUND'; END IF;

  -- Verrou du plan (sérialise les règlements concurrents du même plan)
  SELECT * INTO v_plan FROM public.installment_plans WHERE id = v_inst.plan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PLAN_NOT_FOUND'; END IF;

  IF auth.uid() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.vendors v WHERE v.id = v_plan.vendor_id AND v.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'NOT_OWNER';
  END IF;

  -- Idempotent : déjà réglée → on ne rejoue pas
  IF v_inst.status = 'paid' THEN
    RETURN jsonb_build_object('success', true, 'already_paid', true, 'remaining_amount', v_plan.remaining_amount);
  END IF;

  UPDATE public.installment_payments
     SET status = 'paid', amount_paid = amount_due, payment_date = current_date
   WHERE id = p_installment_id;

  -- Recalcul AUTORITAIRE depuis la source (pas depuis le client) → auto-réparant
  SELECT COALESCE(SUM(amount_paid), 0) INTO v_paid_sum
  FROM public.installment_payments WHERE plan_id = v_plan.id AND status = 'paid';

  v_remaining := GREATEST(0, v_plan.total_amount - v_paid_sum);
  v_status := CASE WHEN v_remaining <= 0 THEN 'completed' ELSE 'active' END;

  UPDATE public.installment_plans
     SET remaining_amount = v_remaining, status = v_status, updated_at = now()
   WHERE id = v_plan.id;

  RETURN jsonb_build_object('success', true, 'remaining_amount', v_remaining, 'status', v_status);
END;
$$;

-- ──────────────────────────────────────────────────────────────────────────
-- 2) VENTE À CRÉDIT : encaisser une tranche (+ historique credit_sale_payments)
-- ──────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_credit_sale_payment_atomic(
  p_credit_sale_id uuid,
  p_amount         numeric,
  p_method         text DEFAULT 'cash',
  p_account        text DEFAULT NULL,
  p_notes          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sale      public.vendor_credit_sales%ROWTYPE;
  v_paid_sum  numeric;
  v_remaining numeric;
  v_status    text;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;

  -- Verrou de la vente (sérialise les encaissements concurrents)
  SELECT * INTO v_sale FROM public.vendor_credit_sales WHERE id = p_credit_sale_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CREDIT_SALE_NOT_FOUND'; END IF;

  IF auth.uid() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.vendors v WHERE v.id = v_sale.vendor_id AND v.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'NOT_OWNER';
  END IF;

  -- Anti-dépassement (sous verrou, valeur DB faisant foi)
  IF p_amount > v_sale.remaining_amount + 0.01 THEN RAISE EXCEPTION 'AMOUNT_EXCEEDS_REMAINING'; END IF;

  -- Historique (était JAMAIS alimenté avant)
  INSERT INTO public.credit_sale_payments (credit_sale_id, amount, payment_method, payment_account, notes)
  VALUES (p_credit_sale_id, p_amount, COALESCE(NULLIF(trim(p_method), ''), 'cash'), p_account, p_notes);

  -- Recalcul AUTORITAIRE depuis la somme des paiements → auto-réparant, anti lost-update
  SELECT COALESCE(SUM(amount), 0) INTO v_paid_sum
  FROM public.credit_sale_payments WHERE credit_sale_id = p_credit_sale_id;

  v_remaining := GREATEST(0, v_sale.total - v_paid_sum);
  v_status := CASE WHEN v_remaining <= 0 THEN 'paid'
                   WHEN v_paid_sum > 0 THEN 'partial'
                   ELSE 'pending' END;

  UPDATE public.vendor_credit_sales
     SET paid_amount = v_paid_sum, remaining_amount = v_remaining, status = v_status, updated_at = now()
   WHERE id = p_credit_sale_id;

  RETURN jsonb_build_object('success', true, 'paid_amount', v_paid_sum, 'remaining_amount', v_remaining, 'status', v_status);
END;
$$;

-- Accès : vendeur authentifié (parité RLS) + backend. Jamais anon/public.
REVOKE ALL ON FUNCTION public.pay_installment_atomic(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_credit_sale_payment_atomic(uuid, numeric, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pay_installment_atomic(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_credit_sale_payment_atomic(uuid, numeric, text, text, text) TO authenticated, service_role;

SELECT 'RPC pay_installment_atomic + record_credit_sale_payment_atomic créés (registres offline fiabilisés, sans wallet).' AS status;
