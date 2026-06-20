-- ============================================================================
-- 🔗 Cohérence dettes ↔ dépenses : régler une dette fournisseur bascule la
-- dépense « à crédit » liée en 'paid'.
--
-- Avant : un achat à crédit créait une dépense status='pending' (non comptée dans
-- les totaux/stats = approved+paid). Régler la dette mettait `supplier_debts` à 'paid'
-- + débitait le wallet, MAIS laissait la dépense en 'pending' → une dette payée
-- restait invisible dans les dépenses. On corrige : à solde complet, la dépense liée
-- (via stock_purchases.expense_id) passe 'paid'. Même signature, atomique.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pay_supplier_debt(
  p_debt_id uuid, p_vendor_id uuid, p_amount numeric, p_idempotency_key text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_debt record; v_user_id uuid; v_new_paid numeric; v_new_status text; v_bal numeric;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;

  SELECT user_id INTO v_user_id FROM public.vendors WHERE id = p_vendor_id;
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'VENDOR_NOT_FOUND'; END IF;

  SELECT * INTO v_debt FROM public.supplier_debts WHERE id = p_debt_id AND vendor_id = p_vendor_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEBT_NOT_FOUND'; END IF;
  IF v_debt.status NOT IN ('in_progress','overdue') THEN
    RETURN jsonb_build_object('success', true, 'skipped', true, 'status', v_debt.status);
  END IF;
  IF p_amount > v_debt.remaining_amount + 0.01 THEN RAISE EXCEPTION 'AMOUNT_EXCEEDS_REMAINING'; END IF;

  -- Débit wallet vendeur (atomique, idempotent via wallet_debit_internal).
  v_bal := public.wallet_debit_internal(v_user_id, p_amount,
    'Règlement dette fournisseur', COALESCE(p_idempotency_key, 'debt_pay:' || p_debt_id::text || ':' || gen_random_uuid()::text));

  v_new_paid := v_debt.paid_amount + p_amount;
  v_new_status := CASE WHEN v_new_paid >= v_debt.total_amount THEN 'paid' ELSE v_debt.status END;

  UPDATE public.supplier_debts SET paid_amount = v_new_paid, status = v_new_status, updated_at = now()
  WHERE id = p_debt_id;

  -- 🔗 Dette soldée → la dépense « à crédit » liée devient 'paid' (cohérence dépenses).
  IF v_new_status = 'paid' AND v_debt.purchase_id IS NOT NULL THEN
    UPDATE public.vendor_expenses e
       SET status = 'paid', payment_method = 'cash', updated_at = now()
      FROM public.stock_purchases sp
     WHERE sp.id = v_debt.purchase_id
       AND e.id = sp.expense_id
       AND e.status <> 'paid';
  END IF;

  RETURN jsonb_build_object('success', true, 'debt_id', p_debt_id, 'paid_amount', v_new_paid,
    'remaining', GREATEST(v_debt.total_amount - v_new_paid, 0), 'status', v_new_status, 'new_balance', v_bal);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.pay_supplier_debt(uuid, uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pay_supplier_debt(uuid, uuid, numeric, text) TO service_role;

SELECT 'pay_supplier_debt : la dépense à crédit liée passe ''paid'' quand la dette est soldée.' AS status;
