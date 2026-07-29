-- ============================================================================
-- CHANTIER C (carte) — Settlement carte → vendeur, par le CHEMIN ATOMIQUE CANONIQUE.
-- ----------------------------------------------------------------------------
-- Paiement carte SANS compte : Stripe encaisse dans la devise du VENDEUR (pas de conversion côté
-- payeur anonyme). À la confirmation (retrieve PaymentIntent) OU au webhook, on crédite le vendeur
-- via credit_user_wallet_safe — la MÊME primitive atomique/idempotente/AML que les autres crédits,
-- JAMAIS un chemin parallèle. Idempotence sur la référence Stripe (rejeu webhook sûr : zéro double-crédit).
-- Frais vendeur (0 par défaut) prélevés sur la collecte → wallet PDG de la devise ; wallet PDG absent
-- → alerte (jamais ignoré). Le vendeur reçoit le NET.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.settle_qr_card_payment(
  p_qr_reference text, p_amount numeric, p_currency text, p_provider_ref text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_qr RECORD; v_owner uuid; v_cfg public.wallet_pay_config;
  v_currency text := upper(nullif(btrim(p_currency), ''));
  v_vendor_fee numeric := 0; v_net numeric; v_pdg bigint; v_credit jsonb;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_provider_ref IS NULL OR btrim(p_provider_ref) = '' THEN RAISE EXCEPTION 'REF_MANQUANTE'; END IF;
  IF v_currency IS NULL THEN RAISE EXCEPTION 'DEVISE_INVALIDE'; END IF;
  v_cfg := public.wallet_pay_active_config();

  SELECT * INTO v_qr FROM public.vendor_payment_qr WHERE reference = p_qr_reference;
  IF NOT FOUND OR v_qr.status <> 'active' THEN RAISE EXCEPTION 'QR_INVALIDE'; END IF;
  v_owner := COALESCE(v_qr.owner_user_id, (SELECT user_id FROM public.vendors WHERE id = v_qr.vendor_id));
  IF v_owner IS NULL THEN RAISE EXCEPTION 'BENEFICIAIRE_INTROUVABLE'; END IF;

  -- Frais vendeur (0 par défaut) prélevés sur la collecte ; le vendeur reçoit le net.
  v_vendor_fee := round(p_amount * v_cfg.qr_wallet_vendor_fee_percent / 100.0, 2);
  v_net := p_amount - v_vendor_fee;
  IF v_net <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;

  -- CRÉDIT VENDEUR — primitive canonique, idempotente sur (qr_card, provider_ref).
  v_credit := public.credit_user_wallet_safe(v_owner, v_net, v_currency, 'qr_card', p_provider_ref);

  -- Déjà réglé (rejeu webhook) → on ressort sans rien dupliquer.
  IF COALESCE((v_credit->>'skipped')::boolean, false) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'provider_ref', p_provider_ref);
  END IF;

  -- Frais → wallet PDG de la devise (crédit canonique idempotent, source distincte).
  IF v_vendor_fee > 0 THEN
    v_pdg := public.get_pdg_wallet_id(v_currency);
    IF v_pdg IS NULL THEN
      PERFORM public.wallet_pay_alert_missing_pdg(v_currency, NULL, v_vendor_fee);
    ELSE
      PERFORM public.credit_user_wallet_safe(public.get_pdg_user_id(), v_vendor_fee, v_currency, 'qr_card_fee', p_provider_ref);
    END IF;
  END IF;

  -- Trace ledger (une fois : on n'arrive ici que sur un crédit réellement appliqué).
  INSERT INTO public.wallet_pay_ledger (parent_tx_id, leg, client_user_id, vendor_id, amount, currency)
  VALUES (gen_random_uuid(), 'vendor_credit', NULL, v_qr.vendor_id, v_net, v_currency);

  RETURN jsonb_build_object('success', true, 'credited', v_credit, 'net', v_net,
    'vendor_fee', v_vendor_fee, 'currency', v_currency, 'provider_ref', p_provider_ref);
END $$;
REVOKE ALL ON FUNCTION public.settle_qr_card_payment(text, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.settle_qr_card_payment(text, numeric, text, text) TO service_role;
