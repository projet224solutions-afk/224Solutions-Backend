-- ============================================================
-- 🧾 CERTIFICATION ESPACE VENDEUR — 2 RPC manquantes/atomiques
-- 1) get_review_author_names : le composant Avis l'appelait mais elle
--    N'EXISTAIT PAS (noms retombaient toujours sur « Client »).
-- 2) record_collection_tx : la MAJ de solde des comptes d'encaissement
--    était NON-ATOMIQUE côté client (lecture puis update → lost-update).
-- ============================================================

-- 1) Noms d'auteurs des avis — UNIQUEMENT sur les produits du vendeur APPELANT.
CREATE OR REPLACE FUNCTION public.get_review_author_names(p_review_ids uuid[])
RETURNS TABLE (review_id uuid, author_name text, author_country text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT r.id,
         coalesce(nullif(trim(pr.first_name || ' ' || coalesce(pr.last_name, '')), ''), pr.full_name, 'Client'),
         pr.country
    FROM public.product_reviews r
    JOIN public.products p ON p.id = r.product_id
    JOIN public.vendors v ON v.id = p.vendor_id AND v.user_id = auth.uid()
    LEFT JOIN public.profiles pr ON pr.id = r.user_id
   WHERE r.id = ANY(p_review_ids);
$$;
REVOKE ALL ON FUNCTION public.get_review_author_names(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_review_author_names(uuid[]) TO authenticated, service_role;

-- 2) Transaction de compte d'encaissement ATOMIQUE (verrou + solde avant/après).
CREATE OR REPLACE FUNCTION public.record_collection_tx(
  p_account_id uuid,
  p_type text,
  p_amount numeric,
  p_description text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_vendor uuid;
  v_balance numeric;
  v_new numeric;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'amount_invalid');
  END IF;
  IF p_type NOT IN ('deposit', 'withdrawal', 'in', 'out') THEN
    RETURN jsonb_build_object('success', false, 'error', 'type_invalid');
  END IF;

  SELECT v.id INTO v_vendor FROM public.vendors v WHERE v.user_id = auth.uid() LIMIT 1;
  IF v_vendor IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'not_vendor'); END IF;

  SELECT balance INTO v_balance FROM public.vendor_collection_accounts
   WHERE id = p_account_id AND vendor_id = v_vendor
   FOR UPDATE;
  IF v_balance IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_owner');
  END IF;

  IF p_type IN ('withdrawal', 'out') AND v_balance < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'insufficient_balance', 'balance', v_balance);
  END IF;

  v_new := CASE WHEN p_type IN ('deposit', 'in') THEN v_balance + p_amount ELSE v_balance - p_amount END;

  UPDATE public.vendor_collection_accounts
     SET balance = v_new, updated_at = now()
   WHERE id = p_account_id;

  INSERT INTO public.vendor_account_transactions
    (account_id, transaction_type, amount, balance_before, balance_after, description)
  VALUES
    (p_account_id, CASE WHEN p_type IN ('deposit', 'in') THEN 'deposit' ELSE 'withdrawal' END,
     p_amount, v_balance, v_new, p_description);

  RETURN jsonb_build_object('success', true, 'balance', v_new);
END $$;
REVOKE ALL ON FUNCTION public.record_collection_tx(uuid, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_collection_tx(uuid, text, numeric, text) TO authenticated, service_role;
