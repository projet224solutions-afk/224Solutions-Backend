-- ═══════════════════════════════════════════════════════════════════════════
-- COMPTABILITÉ — les DEUX seules saisies manuelles autorisées (des SOURCES, pas des lignes
-- comptables directes) : (1) dépenses hors plateforme (vendor_expenses généralisé aux 4 acteurs,
-- ADDITIF) ; (2) courses/recettes cash des chauffeurs/livreurs. Migration NOUVELLE, non-breaking.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── CH2.1 — Généraliser vendor_expenses (additif : owner_user_id + actor_type) ──
ALTER TABLE public.vendor_expenses ALTER COLUMN vendor_id DROP NOT NULL;  -- additif : dépenses hors-vendeur (owner_user_id) autorisées
ALTER TABLE public.vendor_expenses ADD COLUMN IF NOT EXISTS owner_user_id uuid;
ALTER TABLE public.vendor_expenses ADD COLUMN IF NOT EXISTS actor_type text;
ALTER TABLE public.vendor_expenses ADD COLUMN IF NOT EXISTS category_code text;  -- catégorie compta directe (les nouveaux acteurs n'ont pas de category_id vendeur)
ALTER TABLE public.vendor_expenses ADD COLUMN IF NOT EXISTS currency text DEFAULT 'GNF';

-- RLS additive : un acteur non-vendeur gère SES dépenses par owner_user_id (l'existant vendeur
-- via vendor_id reste intact).
DROP POLICY IF EXISTS vexp_owner_manage ON public.vendor_expenses;
CREATE POLICY vexp_owner_manage ON public.vendor_expenses FOR ALL TO authenticated
  USING (owner_user_id = auth.uid()) WITH CHECK (owner_user_id = auth.uid());

-- ── CH2.2 — Recettes/courses CASH des chauffeurs/livreurs (source, pas ligne compta directe) ──
CREATE TABLE IF NOT EXISTS public.driver_cash_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_user_id uuid NOT NULL,
  actor_type text NOT NULL DEFAULT 'taxi_moto' CHECK (actor_type IN ('taxi_moto','vtc','livreur')),
  amount numeric NOT NULL CHECK (amount > 0),
  currency text NOT NULL DEFAULT 'GNF' CHECK (char_length(currency) = 3),
  note text CHECK (note IS NULL OR char_length(note) <= 200),
  entry_date date NOT NULL DEFAULT current_date,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.driver_cash_entries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS dce_owner ON public.driver_cash_entries;
CREATE POLICY dce_owner ON public.driver_cash_entries FOR ALL TO authenticated
  USING (driver_user_id = auth.uid()) WITH CHECK (driver_user_id = auth.uid());

-- ── RPC de saisie : dépense hors plateforme ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.accounting_add_expense(
  p_actor_type text, p_amount numeric, p_currency text, p_category text,
  p_description text, p_expense_date date DEFAULT current_date, p_receipt_url text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'AMOUNT_INVALID'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.accounting_categories WHERE code = p_category AND direction='depense') THEN
    RAISE EXCEPTION 'CATEGORY_INVALID';
  END IF;
  INSERT INTO public.vendor_expenses (owner_user_id, actor_type, category_code, amount, currency,
    description, expense_date, receipt_url, status)
  VALUES (auth.uid(), p_actor_type, p_category, round(p_amount, public._ccy_decimals(p_currency)),
    upper(p_currency), p_description, p_expense_date, p_receipt_url, 'active')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.accounting_add_expense(text, numeric, text, text, text, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accounting_add_expense(text, numeric, text, text, text, date, text) TO authenticated, service_role;

-- ── RPC de saisie : course/recette cash chauffeur ───────────────────────────
CREATE OR REPLACE FUNCTION public.accounting_add_cash_course(
  p_actor_type text, p_amount numeric, p_currency text, p_note text DEFAULT NULL, p_date date DEFAULT current_date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'AMOUNT_INVALID'; END IF;
  INSERT INTO public.driver_cash_entries (driver_user_id, actor_type, amount, currency, note, entry_date)
  VALUES (auth.uid(), COALESCE(p_actor_type,'taxi_moto'), round(p_amount, public._ccy_decimals(p_currency)),
    upper(p_currency), p_note, p_date)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.accounting_add_cash_course(text, numeric, text, text, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accounting_add_cash_course(text, numeric, text, text, date) TO authenticated, service_role;

-- ── Étendre la vue journal : dépenses par owner_user_id + courses cash saisies ──
CREATE OR REPLACE VIEW public.accounting_journal AS
SELECT wt.receiver_user_id AS actor_id, wt.created_at AS entry_at, 'recette' AS direction,
  CASE wt.transaction_type::text
    WHEN 'deposit' THEN 'depots_mobile_money' WHEN 'mobile_money_in' THEN 'depots_mobile_money'
    WHEN 'card_payment' THEN 'depots_carte' WHEN 'bank_transfer' THEN 'depots_mobile_money'
    WHEN 'payment' THEN 'ventes_en_ligne' WHEN 'restaurant_payment' THEN 'ventes_en_ligne'
    WHEN 'transfer_in' THEN 'transferts_recus' WHEN 'transfer' THEN 'transferts_recus'
    WHEN 'international_transfer' THEN 'transferts_recus' WHEN 'escrow_release' THEN 'liberation_escrow'
    ELSE 'autres_recettes' END AS category_code,
  COALESCE(wt.net_amount, wt.amount) AS amount, wt.currency, wt.description AS label,
  'wallet_transactions' AS source_table, wt.id::text AS source_id
FROM public.wallet_transactions wt WHERE wt.receiver_user_id IS NOT NULL AND COALESCE(wt.amount,0) > 0
UNION ALL
SELECT wt.sender_user_id, wt.created_at, 'depense',
  CASE wt.transaction_type::text
    WHEN 'withdrawal' THEN 'retraits_mobile_money' WHEN 'mobile_money_out' THEN 'retraits_mobile_money'
    WHEN 'payment' THEN 'achats_marchandises' WHEN 'restaurant_payment' THEN 'achats_marchandises'
    WHEN 'transfer_out' THEN 'transferts_envoyes' WHEN 'transfer' THEN 'transferts_envoyes'
    WHEN 'international_transfer' THEN 'transferts_envoyes' WHEN 'commission' THEN 'frais_plateforme'
    ELSE 'autres_depenses' END,
  wt.amount, wt.currency, wt.description, 'wallet_transactions', wt.id::text
FROM public.wallet_transactions wt WHERE wt.sender_user_id IS NOT NULL AND COALESCE(wt.amount,0) > 0
UNION ALL
SELECT wt.sender_user_id, wt.created_at, 'depense', 'frais_transfert',
  wt.fee, wt.currency, 'Frais', 'wallet_transactions', wt.id::text || ':fee'
FROM public.wallet_transactions wt WHERE wt.sender_user_id IS NOT NULL AND COALESCE(wt.fee,0) > 0
UNION ALL
SELECT pcs.provider_user_id, pcs.created_at, 'recette', 'ventes_cash_caisse',
  pcs.amount, pcs.currency, pcs.label, 'provider_cash_sales', pcs.id::text
FROM public.provider_cash_sales pcs WHERE pcs.method <> 'wallet'
UNION ALL
SELECT pce.provider_user_id, pce.created_at, 'depense', 'autres_depenses',
  pce.amount, pce.currency, pce.label, 'provider_cash_expenses', pce.id::text
FROM public.provider_cash_expenses pce
UNION ALL
-- Dépenses vendeur (via vendor_id) — inchangé.
SELECT v.user_id, ve.created_at, 'depense', COALESCE(ve.category_code, 'achats_marchandises'),
  ve.amount, COALESCE(ve.currency,'GNF'), ve.description, 'vendor_expenses', ve.id::text
FROM public.vendor_expenses ve JOIN public.vendors v ON v.id = ve.vendor_id
WHERE ve.owner_user_id IS NULL AND COALESCE(ve.status,'active') <> 'cancelled'
UNION ALL
-- Dépenses des NOUVEAUX acteurs (via owner_user_id) — généralisation CH2.
SELECT ve.owner_user_id, ve.created_at, 'depense', COALESCE(ve.category_code, 'autres_depenses'),
  ve.amount, COALESCE(ve.currency,'GNF'), ve.description, 'vendor_expenses', ve.id::text
FROM public.vendor_expenses ve
WHERE ve.owner_user_id IS NOT NULL AND COALESCE(ve.status,'active') <> 'cancelled'
UNION ALL
-- Courses/recettes cash saisies (chauffeurs/livreurs).
SELECT dce.driver_user_id, dce.created_at, 'recette',
  CASE dce.actor_type WHEN 'vtc' THEN 'courses_vtc' WHEN 'livreur' THEN 'livraisons' ELSE 'courses_taxi' END,
  dce.amount, dce.currency, COALESCE(dce.note,'Course espèces'), 'driver_cash_entries', dce.id::text
FROM public.driver_cash_entries dce
UNION ALL
SELECT td.user_id, tt.completed_at, 'recette', 'courses_taxi',
  tt.driver_share, 'GNF', 'Course ' || COALESCE(tt.ride_code,''), 'taxi_trips', tt.id::text
FROM public.taxi_trips tt JOIN public.taxi_drivers td ON td.id = tt.driver_id
WHERE tt.status = 'completed' AND COALESCE(tt.payment_method,'') <> 'wallet' AND COALESCE(tt.driver_share,0) > 0
UNION ALL
SELECT td.user_id, tt.completed_at, 'depense', 'frais_plateforme',
  tt.platform_fee, 'GNF', 'Commission course ' || COALESCE(tt.ride_code,''), 'taxi_trips', tt.id::text || ':fee'
FROM public.taxi_trips tt JOIN public.taxi_drivers td ON td.id = tt.driver_id
WHERE tt.status = 'completed' AND COALESCE(tt.payment_method,'') <> 'wallet' AND COALESCE(tt.platform_fee,0) > 0;
