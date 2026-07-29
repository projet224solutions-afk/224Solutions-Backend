-- ============================================================================
-- RÈGLEMENT QR UNIFIÉ — un seul helper de crédit vendeur pour les 3 rails (carte/OM-MoMo/wallet)
-- ----------------------------------------------------------------------------
-- `settle_qr_payment(qr_ref, amount, currency, provider, provider_ref)` = généralisation de
-- `settle_qr_card_payment` : même logique (frais vendeur → PDG, crédit vendeur via la primitive
-- canonique credit_user_wallet_safe IDEMPOTENTE, trace ledger, marquage QR) mais paramétrée par
-- `provider` (source_type = 'qr_'||provider). `settle_qr_card_payment` DÉLÈGUE désormais à ce
-- helper (provider='card') → le chemin carte est INCHANGÉ (source 'qr_card'), mais il n'existe
-- plus qu'UNE logique de règlement, réutilisée par OM/MoMo (Djomy) et le wallet.
-- Crédit UNIQUEMENT après confirmation prestataire vérifiée (appelé par le webhook Node).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.settle_qr_payment(
  p_qr_reference text, p_amount numeric, p_currency text, p_provider text, p_provider_ref text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_qr RECORD; v_owner uuid; v_cfg public.wallet_pay_config;
  v_currency text := upper(nullif(btrim(p_currency), ''));
  v_provider text := lower(nullif(btrim(p_provider), ''));
  v_src text; v_src_fee text;
  v_vendor_fee numeric := 0; v_net numeric; v_pdg bigint; v_credit jsonb;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_provider_ref IS NULL OR btrim(p_provider_ref) = '' THEN RAISE EXCEPTION 'REF_MANQUANTE'; END IF;
  IF v_currency IS NULL THEN RAISE EXCEPTION 'DEVISE_INVALIDE'; END IF;
  IF v_provider IS NULL THEN RAISE EXCEPTION 'PROVIDER_MANQUANT'; END IF;
  v_src := 'qr_' || v_provider;          -- ex: qr_card, qr_djomy
  v_src_fee := 'qr_' || v_provider || '_fee';
  v_cfg := public.wallet_pay_active_config();

  SELECT * INTO v_qr FROM public.vendor_payment_qr WHERE reference = p_qr_reference;
  IF NOT FOUND OR v_qr.status <> 'active' THEN RAISE EXCEPTION 'QR_INVALIDE'; END IF;
  v_owner := COALESCE(v_qr.owner_user_id, (SELECT user_id FROM public.vendors WHERE id = v_qr.vendor_id));
  IF v_owner IS NULL THEN RAISE EXCEPTION 'BENEFICIAIRE_INTROUVABLE'; END IF;

  v_vendor_fee := round(p_amount * v_cfg.qr_wallet_vendor_fee_percent / 100.0, 2);
  v_net := p_amount - v_vendor_fee;
  IF v_net <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;

  -- CRÉDIT VENDEUR — primitive canonique, idempotente sur (v_src, provider_ref) → rejeu webhook = no-op.
  v_credit := public.credit_user_wallet_safe(v_owner, v_net, v_currency, v_src, p_provider_ref);
  IF COALESCE((v_credit->>'skipped')::boolean, false) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'provider_ref', p_provider_ref);
  END IF;

  -- Frais → wallet PDG de la devise (crédit canonique idempotent, source distincte).
  IF v_vendor_fee > 0 THEN
    v_pdg := public.get_pdg_wallet_id(v_currency);
    IF v_pdg IS NULL THEN
      PERFORM public.wallet_pay_alert_missing_pdg(v_currency, NULL, v_vendor_fee);
    ELSE
      PERFORM public.credit_user_wallet_safe(public.get_pdg_user_id(), v_vendor_fee, v_currency, v_src_fee, p_provider_ref);
    END IF;
  END IF;

  INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount, currency)
  VALUES (gen_random_uuid(), 'vendor_credit', NULL, v_qr.vendor_id, v_net, v_currency);

  RETURN jsonb_build_object('success', true, 'credited', v_credit, 'net', v_net,
    'vendor_fee', v_vendor_fee, 'currency', v_currency, 'provider', v_provider, 'provider_ref', p_provider_ref);
END $function$;

REVOKE ALL ON FUNCTION public.settle_qr_payment(text, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.settle_qr_payment(text, numeric, text, text, text) TO service_role;

-- Le chemin carte devient un simple alias (provider='card') → INCHANGÉ (source 'qr_card').
CREATE OR REPLACE FUNCTION public.settle_qr_card_payment(
  p_qr_reference text, p_amount numeric, p_currency text, p_provider_ref text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
BEGIN
  RETURN public.settle_qr_payment(p_qr_reference, p_amount, p_currency, 'card', p_provider_ref);
END $function$;
