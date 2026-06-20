-- ============================================================================
-- 🧾 GESTION DETTES FOURNISSEUR / ACHATS À CRÉDIT (vendeur).
-- ----------------------------------------------------------------------------
-- Avant : tout achat validé = dépense « payée cash » ; la table supplier_debts n'existait
-- pas (composant Dettes = code mort). Ici on construit le vrai flux crédit :
--   1) stock_purchases gagne payment_mode/supplier_id/due_date/minimum_installment.
--   2) supplier_debts : la dette par (achat, fournisseur), remaining auto-calculé.
--   3) validate_stock_purchase (MÊME signature → zéro drift) : si payment_mode='credit',
--      crée une DETTE (au lieu d'une dépense payée). Stock/cost/price toujours mis à jour.
--   4) pay_supplier_debt : règlement atomique d'une tranche (débit wallet + maj dette + statut).
-- Atomique, idempotent, REVOKE FROM PUBLIC.
-- ============================================================================

-- 1) ── Colonnes mode de paiement sur stock_purchases ────────────────────────
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS payment_mode text NOT NULL DEFAULT 'cash';
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS supplier_id uuid;
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS due_date date;
ALTER TABLE public.stock_purchases ADD COLUMN IF NOT EXISTS minimum_installment numeric;
DO $$ BEGIN
  ALTER TABLE public.stock_purchases ADD CONSTRAINT stock_purchases_payment_mode_chk CHECK (payment_mode IN ('cash','credit'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 2) ── Table des dettes fournisseur ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.supplier_debts (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id           uuid NOT NULL,                         -- vendors.id
  supplier_id         uuid REFERENCES public.vendor_suppliers(id) ON DELETE SET NULL,
  purchase_id         uuid REFERENCES public.stock_purchases(id) ON DELETE SET NULL,
  total_amount        numeric NOT NULL CHECK (total_amount >= 0),
  paid_amount         numeric NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
  remaining_amount    numeric GENERATED ALWAYS AS (GREATEST(total_amount - paid_amount, 0)) STORED,
  minimum_installment numeric NOT NULL DEFAULT 0,
  due_date            date,
  currency            text NOT NULL DEFAULT 'GNF',
  status              text NOT NULL DEFAULT 'in_progress' CHECK (status IN ('in_progress','paid','overdue','cancelled')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_supplier_debts_vendor ON public.supplier_debts (vendor_id, status);

ALTER TABLE public.supplier_debts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS supplier_debts_owner ON public.supplier_debts;
CREATE POLICY supplier_debts_owner ON public.supplier_debts FOR SELECT TO authenticated
  USING (vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()) OR public.is_admin_or_pdg());
-- écriture = backend (service_role, BYPASS RLS) uniquement.

-- 3) ── validate_stock_purchase : branche CRÉDIT (même signature) ────────────
CREATE OR REPLACE FUNCTION public.validate_stock_purchase(
  p_purchase_id uuid, p_vendor_id uuid, p_items jsonb, p_purchase_number text, p_total_amount numeric
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_user_id uuid; v_expense_id uuid; v_item jsonb;
  v_supplier_ids uuid[]; v_supplier_names text; v_desc text; v_purchase record;
  v_debt_supplier uuid; v_debt_id uuid;
BEGIN
  IF p_purchase_id IS NULL OR p_vendor_id IS NULL OR p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Paramètres manquants');
  END IF;

  SELECT user_id INTO v_user_id FROM public.vendors WHERE id = p_vendor_id;
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Vendor non trouvé'); END IF;

  SELECT id, status, is_locked, expense_id, payment_mode, supplier_id, due_date, minimum_installment
  INTO v_purchase FROM public.stock_purchases WHERE id = p_purchase_id AND vendor_id = p_vendor_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Achat introuvable pour ce vendeur'); END IF;
  IF v_purchase.status = 'validated' OR COALESCE(v_purchase.is_locked, false) = true THEN
    RETURN jsonb_build_object('success', true, 'already_validated', true, 'expense_id', v_purchase.expense_id, 'message', 'Achat déjà validé');
  END IF;

  SELECT array_agg(DISTINCT (e->>'supplier_id')::uuid) INTO v_supplier_ids
  FROM jsonb_array_elements(p_items) e WHERE NULLIF(e->>'supplier_id', '') IS NOT NULL;

  v_desc := 'Achat de stock - ' || p_purchase_number;
  IF v_supplier_ids IS NOT NULL AND array_length(v_supplier_ids, 1) > 0 THEN
    SELECT string_agg(name, ', ') INTO v_supplier_names FROM public.vendor_suppliers WHERE id = ANY(v_supplier_ids);
    IF v_supplier_names IS NOT NULL THEN v_desc := v_desc || ' - Fournisseur(s): ' || v_supplier_names; END IF;
  END IF;

  -- ── 1) Dépense / Dette selon le mode de paiement ──
  IF COALESCE(v_purchase.payment_mode, 'cash') = 'credit' THEN
    -- ACHAT À CRÉDIT → crée une DETTE (pas de dépense payée). Fournisseur = celui de l'achat,
    -- sinon le 1er fournisseur des lignes.
    v_debt_supplier := COALESCE(v_purchase.supplier_id, v_supplier_ids[1]);
    INSERT INTO public.supplier_debts (vendor_id, supplier_id, purchase_id, total_amount, paid_amount,
      minimum_installment, due_date, status)
    VALUES (p_vendor_id, v_debt_supplier, p_purchase_id, p_total_amount, 0,
      COALESCE(v_purchase.minimum_installment, 0), v_purchase.due_date, 'in_progress')
    RETURNING id INTO v_debt_id;
    -- Dépense « non payée » pour la traçabilité comptable.
    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date, payment_method, status, is_locked, purchase_reference)
    VALUES (v_user_id, v_desc || ' (à crédit)', p_total_amount, CURRENT_DATE, 'credit', 'pending', true, p_purchase_number)
    RETURNING id INTO v_expense_id;
  ELSE
    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date, payment_method, status, is_locked, purchase_reference)
    VALUES (v_user_id, v_desc, p_total_amount, CURRENT_DATE, 'cash', 'paid', true, p_purchase_number)
    RETURNING id INTO v_expense_id;
  END IF;

  -- ── 2) stock + cost_price + price (scopé vendeur) ──
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF NULLIF(v_item->>'product_id', '') IS NOT NULL THEN
      UPDATE public.products SET
        stock_quantity = COALESCE(stock_quantity, 0) + COALESCE((v_item->>'quantity')::numeric, 0),
        cost_price = COALESCE(NULLIF(v_item->>'purchase_price', '')::numeric, cost_price),
        price = COALESCE(NULLIF(v_item->>'selling_price', '')::numeric, price)
      WHERE id = (v_item->>'product_id')::uuid AND vendor_id = p_vendor_id;
    END IF;
  END LOOP;

  -- ── 3) fournisseurs marqués validés ──
  IF v_supplier_ids IS NOT NULL AND array_length(v_supplier_ids, 1) > 0 THEN
    UPDATE public.vendor_suppliers SET has_validated_purchases = true WHERE id = ANY(v_supplier_ids) AND vendor_id = p_vendor_id;
  END IF;

  -- ── 4) valider + verrouiller l'achat ──
  UPDATE public.stock_purchases SET status = 'validated', validated_at = NOW(), expense_id = v_expense_id, is_locked = true
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object('success', true, 'expense_id', v_expense_id, 'debt_id', v_debt_id,
    'mode', COALESCE(v_purchase.payment_mode,'cash'),
    'message', 'Achat ' || p_purchase_number || ' validé' || CASE WHEN v_debt_id IS NOT NULL THEN ' (dette créée)' ELSE '' END);
END;
$$;
REVOKE ALL ON FUNCTION public.validate_stock_purchase(uuid, uuid, jsonb, text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_stock_purchase(uuid, uuid, jsonb, text, numeric) TO service_role;

-- 4) ── pay_supplier_debt : règlement atomique d'une tranche ─────────────────
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

  RETURN jsonb_build_object('success', true, 'debt_id', p_debt_id, 'paid_amount', v_new_paid,
    'remaining', GREATEST(v_debt.total_amount - v_new_paid, 0), 'status', v_new_status, 'new_balance', v_bal);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
REVOKE ALL ON FUNCTION public.pay_supplier_debt(uuid, uuid, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pay_supplier_debt(uuid, uuid, numeric, text) TO service_role;

SELECT 'Dettes fournisseur / achats à crédit posés : supplier_debts + validate_stock_purchase (branche crédit) + pay_supplier_debt (règlement atomique).' AS status;
