-- ═══════════════════════════════════════════════════════════════════════════
-- COMPTA — saisie PDG POUR LE COMPTE d'un acteur (traçée created_by = PDG). Migration NOUVELLE.
-- L'acteur garde la saisie POUR LUI-MÊME (écriture seule). Le PDG, dans la console (vue acteur),
-- peut saisir/corriger pour un acteur cible → owner = acteur, created_by = PDG (qui a écrit quoi).
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.vendor_expenses ADD COLUMN IF NOT EXISTS created_by uuid;
ALTER TABLE public.driver_cash_entries ADD COLUMN IF NOT EXISTS created_by uuid;

-- Dépense : +p_on_behalf_of (NULL = pour soi ; renseigné = pour un acteur, PDG UNIQUEMENT).
CREATE OR REPLACE FUNCTION public.accounting_add_expense(
  p_actor_type text, p_amount numeric, p_currency text, p_category text,
  p_description text, p_expense_date date DEFAULT current_date, p_receipt_url text DEFAULT NULL,
  p_on_behalf_of uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_owner uuid;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'AMOUNT_INVALID'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.accounting_categories WHERE code = p_category AND direction='depense') THEN
    RAISE EXCEPTION 'CATEGORY_INVALID';
  END IF;
  -- Saisie POUR UN AUTRE acteur → réservée au PDG (créé pour le compte de, tracé created_by).
  IF p_on_behalf_of IS NOT NULL AND p_on_behalf_of <> auth.uid() THEN
    IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
    v_owner := p_on_behalf_of;
  ELSE
    v_owner := auth.uid();
  END IF;
  INSERT INTO public.vendor_expenses (owner_user_id, actor_type, category_code, amount, currency,
    description, expense_date, receipt_url, status, created_by)
  VALUES (v_owner, p_actor_type, p_category, round(p_amount, public._ccy_decimals(p_currency)),
    upper(p_currency), p_description, p_expense_date, p_receipt_url, 'active', auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.accounting_add_expense(text, numeric, text, text, text, date, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accounting_add_expense(text, numeric, text, text, text, date, text, uuid) TO authenticated, service_role;

-- Course cash : idem +p_on_behalf_of (PDG only pour autrui).
CREATE OR REPLACE FUNCTION public.accounting_add_cash_course(
  p_actor_type text, p_amount numeric, p_currency text, p_note text DEFAULT NULL, p_date date DEFAULT current_date,
  p_on_behalf_of uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_owner uuid;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'AMOUNT_INVALID'; END IF;
  IF p_on_behalf_of IS NOT NULL AND p_on_behalf_of <> auth.uid() THEN
    IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
    v_owner := p_on_behalf_of;
  ELSE
    v_owner := auth.uid();
  END IF;
  INSERT INTO public.driver_cash_entries (driver_user_id, actor_type, amount, currency, note, entry_date, created_by)
  VALUES (v_owner, COALESCE(p_actor_type,'taxi_moto'), round(p_amount, public._ccy_decimals(p_currency)),
    upper(p_currency), p_note, p_date, auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.accounting_add_cash_course(text, numeric, text, text, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accounting_add_cash_course(text, numeric, text, text, date, uuid) TO authenticated, service_role;
