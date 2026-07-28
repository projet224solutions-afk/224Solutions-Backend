-- ============================================================================
-- BLOC 2 — Le chemin QR devient multi-devise (APRÈS le BLOC 1 qui blinde le transfert).
-- ----------------------------------------------------------------------------
-- pay_vendor_via_wallet : suppression des DEUX `currency='GNF'` en dur.
--   • Wallet payeur   = le wallet du CLIENT (sa devise).      Il paie dans SA devise.
--   • Wallet vendeur  = le wallet du PROPRIÉTAIRE du QR (sa devise). Il reçoit dans LA SIENNE.
--   • Devises ≠ → le transfert canonique (BLOC 1) convertit via la santé FX et verrouille le taux.
--   • Frais : prélevés côté payeur/vendeur dans LEUR devise, versés au wallet PDG de CETTE devise
--     (get_pdg_wallet_id(devise)). Wallet PDG de la devise absent → alerte (system_alerts), jamais ignoré.
-- Modèle de montant : le montant est TOUJOURS exprimé dans la devise du client (ce qu'il paie).
--   Statique : montant choisi par le client. Dynamique : prix fixé (devise vendeur) converti en
--   devise client pour le débit ; le vendeur reçoit la conversion retour (dérive sous-centime tolérée).
-- Résolution du bénéficiaire : par vendor_id (owner_user_id arrive au BLOC 3 pour les prestataires).
-- ============================================================================

-- ── Wallet PDG d'une devise arbitraire (sœur paramétrée de get_pdg_gnf_wallet_id) ──
CREATE OR REPLACE FUNCTION public.get_pdg_wallet_id(p_currency text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user uuid := public.get_pdg_user_id();
  v_cur  text := upper(nullif(btrim(p_currency), ''));
  v_wallet bigint;
BEGIN
  IF v_user IS NULL OR v_cur IS NULL THEN RETURN NULL; END IF;
  SELECT id INTO v_wallet FROM public.wallets WHERE user_id = v_user AND currency = v_cur;
  IF v_wallet IS NULL THEN
    INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
    VALUES (v_user, 0, v_cur, 'active')
    ON CONFLICT (user_id, currency) DO NOTHING
    RETURNING id INTO v_wallet;
    IF v_wallet IS NULL THEN
      SELECT id INTO v_wallet FROM public.wallets WHERE user_id = v_user AND currency = v_cur;
    END IF;
  END IF;
  RETURN v_wallet;
END;
$$;
REVOKE ALL ON FUNCTION public.get_pdg_wallet_id(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_pdg_wallet_id(text) TO authenticated, service_role;

-- ── pay_vendor_via_wallet : multi-devise ──
CREATE OR REPLACE FUNCTION public.pay_vendor_via_wallet(
  p_client_user_id uuid, p_qr_reference text, p_amount numeric, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_parent uuid; v_qr RECORD; v_cfg public.wallet_pay_config;
  v_vendor RECORD; v_vendor_user uuid;
  v_client_wallet bigint; v_client_bal numeric; v_client_cur text;
  v_vendor_wallet bigint; v_vendor_bal numeric; v_vendor_cur text;
  v_debit numeric;         -- ce que paie le client, dans SA devise
  v_credit numeric;        -- ce que reçoit le vendeur, dans SA devise
  v_client_fee numeric := 0; v_vendor_fee numeric := 0;
  v_pdg_client bigint; v_pdg_vendor bigint; v_tr jsonb;
BEGIN
  IF p_client_user_id IS NULL THEN RAISE EXCEPTION 'CLIENT_INTROUVABLE'; END IF;
  v_cfg := public.wallet_pay_active_config();

  INSERT INTO public.wallet_pay_operations (idempotency_key, client_user_id, amount)
  VALUES (p_idempotency_key, p_client_user_id, p_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.wallet_pay_operations WHERE idempotency_key = p_idempotency_key);
  END IF;

  SELECT * INTO v_qr FROM public.vendor_payment_qr WHERE reference = p_qr_reference FOR UPDATE;
  IF NOT FOUND OR v_qr.status <> 'active' THEN RAISE EXCEPTION 'QR_INVALIDE'; END IF;
  IF v_qr.expires_at IS NOT NULL AND v_qr.expires_at < now() THEN
    UPDATE public.vendor_payment_qr SET status='expired' WHERE id = v_qr.id;
    RAISE EXCEPTION 'QR_EXPIRE';
  END IF;

  -- Bénéficiaire (BLOC 2 : par vendor_id ; BLOC 3 ajoutera owner_user_id pour les prestataires).
  SELECT id, user_id INTO v_vendor FROM public.vendors WHERE id = v_qr.vendor_id;
  v_vendor_user := v_vendor.user_id;
  IF v_vendor_user IS NULL THEN RAISE EXCEPTION 'VENDEUR_INTROUVABLE'; END IF;

  -- Wallets = wallet PRINCIPAL (le plus ancien) de chacun, dans SA devise. Plus de GNF forcé.
  SELECT id, balance, currency INTO v_client_wallet, v_client_bal, v_client_cur
    FROM public.wallets WHERE user_id = p_client_user_id ORDER BY created_at ASC LIMIT 1;
  SELECT id, balance, currency INTO v_vendor_wallet, v_vendor_bal, v_vendor_cur
    FROM public.wallets WHERE user_id = v_vendor_user ORDER BY created_at ASC LIMIT 1;
  IF v_client_wallet IS NULL OR v_vendor_wallet IS NULL THEN RAISE EXCEPTION 'WALLET_INTROUVABLE'; END IF;

  -- Montant à débiter (devise client). Dynamique : prix fixé (devise vendeur) → équivalent client.
  IF v_qr.kind = 'dynamic' THEN
    IF v_qr.amount IS NULL OR v_qr.amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
    SELECT converted_amount INTO v_debit FROM public.wallet_fx_resolve(v_vendor_cur, v_client_cur, v_qr.amount);
  ELSE
    v_debit := p_amount;
  END IF;
  IF v_debit IS NULL OR v_debit <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;

  -- 1) Paiement principal : transfert CANONIQUE (BLOC 1) — convertit + verrouille si devises ≠.
  v_tr := public.execute_atomic_wallet_transfer(
    p_client_user_id, v_vendor_user, v_debit, 'wallet_pay:' || v_parent::text,
    v_client_wallet, v_vendor_wallet, v_client_bal, v_vendor_bal);
  IF NOT COALESCE((v_tr->>'success')::boolean, false) THEN RAISE EXCEPTION 'TRANSFERT_ECHOUE'; END IF;
  v_credit := COALESCE((v_tr->>'credit_amount')::numeric, v_debit);

  INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount, currency)
  VALUES (v_parent, 'client_debit_vendor', p_client_user_id, v_qr.vendor_id, v_debit,  v_client_cur),
         (v_parent, 'vendor_credit',       p_client_user_id, v_qr.vendor_id, v_credit, v_vendor_cur);

  -- 2) Frais client (0 par défaut) → wallet PDG de la DEVISE CLIENT.
  v_client_fee := round(v_debit * v_cfg.qr_wallet_client_fee_percent / 100.0, 2);
  IF v_client_fee > 0 THEN
    v_pdg_client := public.get_pdg_wallet_id(v_client_cur);
    IF v_pdg_client IS NULL THEN
      PERFORM public.wallet_pay_alert_missing_pdg(v_client_cur, v_parent, v_client_fee);  -- alerte, jamais ignoré
    ELSE
      PERFORM public._acash_debit_wallet(v_client_wallet, v_client_fee, 'SOLDE_INSUFFISANT');
      UPDATE public.wallets SET balance = balance + v_client_fee, updated_at = now() WHERE id = v_pdg_client;
      INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount, currency)
      VALUES (v_parent, 'client_fee_pdg', p_client_user_id, v_qr.vendor_id, v_client_fee, v_client_cur);
    END IF;
  END IF;

  -- 3) Frais vendeur (0 par défaut) → wallet PDG de la DEVISE VENDEUR.
  v_vendor_fee := round(v_credit * v_cfg.qr_wallet_vendor_fee_percent / 100.0, 2);
  IF v_vendor_fee > 0 THEN
    v_pdg_vendor := public.get_pdg_wallet_id(v_vendor_cur);
    IF v_pdg_vendor IS NULL THEN
      PERFORM public.wallet_pay_alert_missing_pdg(v_vendor_cur, v_parent, v_vendor_fee);
    ELSE
      PERFORM public._acash_debit_wallet(v_vendor_wallet, v_vendor_fee, 'SOLDE_INSUFFISANT');
      UPDATE public.wallets SET balance = balance + v_vendor_fee, updated_at = now() WHERE id = v_pdg_vendor;
      INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount, currency)
      VALUES (v_parent, 'vendor_fee_pdg', p_client_user_id, v_qr.vendor_id, v_vendor_fee, v_vendor_cur);
    END IF;
  END IF;

  IF v_qr.kind = 'dynamic' THEN UPDATE public.vendor_payment_qr SET status='used' WHERE id = v_qr.id; END IF;

  UPDATE public.wallet_pay_operations SET vendor_id = v_qr.vendor_id, amount = v_debit, fee = v_client_fee + v_vendor_fee,
    result = jsonb_build_object('success', true, 'parent_tx_id', v_parent,
      'amount', v_debit, 'client_currency', v_client_cur, 'credit_amount', v_credit, 'vendor_currency', v_vendor_cur,
      'client_fee', v_client_fee, 'vendor_fee', v_vendor_fee, 'transaction_id', v_tr->>'transaction_id')
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.wallet_pay_operations WHERE parent_tx_id = v_parent);
END $function$;
REVOKE ALL ON FUNCTION public.pay_vendor_via_wallet(uuid,text,numeric,text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_vendor_via_wallet(uuid,text,numeric,text) TO service_role;

-- ── Alerte « wallet PDG de devise absent » (ne plus ignorer un frais non routable) ──
CREATE OR REPLACE FUNCTION public.wallet_pay_alert_missing_pdg(p_currency text, p_parent uuid, p_fee numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  BEGIN
    INSERT INTO public.system_alerts (severity, module, title, message, metadata)
    VALUES ('high', 'pdg_treasury', 'Wallet PDG de devise absent',
      format('Frais QR %s non routable : aucun wallet PDG en %s (PDG actif introuvable).', p_fee, p_currency),
      jsonb_build_object('currency', p_currency, 'parent_tx_id', p_parent, 'fee', p_fee));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wallet-pay] wallet PDG % absent, frais % non routé (parent %)', p_currency, p_fee, p_parent;
  END;
END;
$$;
REVOKE ALL ON FUNCTION public.wallet_pay_alert_missing_pdg(text, uuid, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wallet_pay_alert_missing_pdg(text, uuid, numeric) TO service_role;
