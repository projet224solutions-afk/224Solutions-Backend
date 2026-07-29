-- ============================================================================
-- FX AU RÈGLEMENT (RÈGLE 2) — la conversion passe par le FX INTERNE santé-vérifié, taux gelé
-- ----------------------------------------------------------------------------
-- Le prestataire encaisse dans SA devise de zone. Si devise encaissée ≠ devise du wallet
-- bénéficiaire, `settle_qr_payment` convertit via `wallet_fx_resolve` (présent + frais
-- fx_stale_hours + bornes fx_pair_bounds), **taux gelé** dans le ledger + metadata.
-- Taux indisponible/périmé/hors bornes → `wallet_fx_resolve` lève `FX_INDISPONIBLE` → l'exception
-- remonte, le règlement N'ÉCRIT RIEN (rollback), et le webhook marque la transaction `pending_fx`
-- (fonds chez le prestataire, tracés) + alerte PDG + relance par le job de réconciliation.
-- AUCUN taux prestataire n'est jamais utilisé. Chemin même-devise (dont carte Stripe) : INCHANGÉ.
-- ============================================================================

-- 1) Autoriser le statut `pending_fx` (attente de conversion) sur le ledger de dépôts/règlements.
DO $$
DECLARE v_con text;
BEGIN
  SELECT conname INTO v_con FROM pg_constraint
   WHERE conrelid = 'public.payment_transactions'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) ILIKE '%status%';
  IF v_con IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.payment_transactions DROP CONSTRAINT %I', v_con);
  END IF;
  ALTER TABLE public.payment_transactions
    ADD CONSTRAINT payment_transactions_status_check
    CHECK (status IN ('pending','processing','completed','failed','pending_fx'));
END $$;

-- 2) settle_qr_payment v2 : conversion FX interne au règlement (taux gelé) ou FX_INDISPONIBLE.
CREATE OR REPLACE FUNCTION public.settle_qr_payment(
  p_qr_reference text, p_amount numeric, p_currency text, p_provider text, p_provider_ref text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_qr RECORD; v_owner uuid; v_cfg public.wallet_pay_config;
  v_enc_cur  text := upper(nullif(btrim(p_currency), ''));   -- devise ENCAISSÉE (zone prestataire)
  v_provider text := lower(nullif(btrim(p_provider), ''));
  v_src text; v_src_fee text;
  v_wallet_cur text;                                          -- devise du wallet BÉNÉFICIAIRE
  v_settle_cur text; v_gross numeric;
  v_rate numeric := 1; v_rsrc text := 'identity'; v_rat timestamptz := now();
  v_fx jsonb;
  v_vendor_fee numeric := 0; v_net numeric; v_pdg bigint; v_credit jsonb;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_provider_ref IS NULL OR btrim(p_provider_ref) = '' THEN RAISE EXCEPTION 'REF_MANQUANTE'; END IF;
  IF v_enc_cur IS NULL THEN RAISE EXCEPTION 'DEVISE_INVALIDE'; END IF;
  IF v_provider IS NULL THEN RAISE EXCEPTION 'PROVIDER_MANQUANT'; END IF;
  v_src := 'qr_' || v_provider; v_src_fee := 'qr_' || v_provider || '_fee';
  v_cfg := public.wallet_pay_active_config();

  SELECT * INTO v_qr FROM public.vendor_payment_qr WHERE reference = p_qr_reference;
  IF NOT FOUND OR v_qr.status <> 'active' THEN RAISE EXCEPTION 'QR_INVALIDE'; END IF;
  v_owner := COALESCE(v_qr.owner_user_id, (SELECT user_id FROM public.vendors WHERE id = v_qr.vendor_id));
  IF v_owner IS NULL THEN RAISE EXCEPTION 'BENEFICIAIRE_INTROUVABLE'; END IF;

  -- Devise du wallet cible du bénéficiaire (même sélection que credit_user_wallet_safe).
  SELECT currency INTO v_wallet_cur FROM public.wallets
    WHERE user_id = v_owner ORDER BY (currency = v_enc_cur) DESC, id ASC LIMIT 1;
  v_wallet_cur := COALESCE(v_wallet_cur, v_enc_cur);

  IF v_enc_cur = v_wallet_cur THEN
    -- Pas de conversion : on règle dans la devise encaissée (= devise wallet).
    v_settle_cur := v_enc_cur; v_gross := p_amount;
    v_fx := jsonb_build_object('converted', false, 'currency', v_enc_cur);
  ELSE
    -- Conversion par le FX INTERNE santé-vérifié (lève FX_INDISPONIBLE si indispo/périmé/hors bornes).
    SELECT converted_amount, rate_used, rate_source, rate_fetched_at
      INTO v_gross, v_rate, v_rsrc, v_rat
      FROM public.wallet_fx_resolve(v_enc_cur, v_wallet_cur, p_amount);
    v_settle_cur := v_wallet_cur;
    v_fx := jsonb_build_object('converted', true, 'from_currency', v_enc_cur, 'to_currency', v_wallet_cur,
      'rate', v_rate, 'source', v_rsrc, 'locked_at', now(), 'rate_fetched_at', v_rat,
      'amount_source', p_amount, 'amount_converted', v_gross);
  END IF;

  -- Frais + net dans la devise de règlement (= devise wallet).
  v_vendor_fee := round(v_gross * v_cfg.qr_wallet_vendor_fee_percent / 100.0, 2);
  v_net := v_gross - v_vendor_fee;
  IF v_net <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;

  -- CRÉDIT VENDEUR — dans v_settle_cur (p_from_currency = v_settle_cur → credit_user_wallet_safe
  -- ne re-convertit pas). Idempotent sur (v_src, provider_ref).
  v_credit := public.credit_user_wallet_safe(v_owner, v_net, v_settle_cur, v_src, p_provider_ref);
  IF COALESCE((v_credit->>'skipped')::boolean, false) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'provider_ref', p_provider_ref);
  END IF;

  -- Frais → wallet PDG de la devise de règlement.
  IF v_vendor_fee > 0 THEN
    v_pdg := public.get_pdg_wallet_id(v_settle_cur);
    IF v_pdg IS NULL THEN
      PERFORM public.wallet_pay_alert_missing_pdg(v_settle_cur, NULL, v_vendor_fee);
    ELSE
      PERFORM public.credit_user_wallet_safe(public.get_pdg_user_id(), v_vendor_fee, v_settle_cur, v_src_fee, p_provider_ref);
    END IF;
  END IF;

  INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount, currency)
  VALUES (gen_random_uuid(), 'vendor_credit', NULL, v_qr.vendor_id, v_net, v_settle_cur);

  RETURN jsonb_build_object('success', true, 'credited', v_credit, 'net', v_net, 'vendor_fee', v_vendor_fee,
    'currency', v_settle_cur, 'provider', v_provider, 'provider_ref', p_provider_ref, 'fx', v_fx);
END $function$;
