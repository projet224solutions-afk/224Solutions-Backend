-- ============================================================================
-- BLOC 4 — Révocation/régénération atomique (JAMAIS de DELETE : l'historique référence le token).
-- BLOC 5 — Devis avant PIN : montant payeur + équivalent bénéficiaire + frais + total débité,
--          solde insuffisant détecté À LA RÉSOLUTION (pas après le PIN).
-- ============================================================================

-- ── BLOC 4 : régénérer le QR statique d'un propriétaire (expire l'actif + crée le nouveau) ──
-- Transaction unique (atomique), journalisée. L'ancien token devient inerte immédiatement.
CREATE OR REPLACE FUNCTION public.vendor_payment_qr_regenerate(p_owner_user_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_vendor_id uuid; v_ref text;
BEGIN
  IF p_owner_user_id IS NULL THEN RAISE EXCEPTION 'PROPRIETAIRE_INTROUVABLE'; END IF;
  -- Récupère le vendor_id éventuel (pour continuité de la colonne) avant d'expirer.
  SELECT vendor_id INTO v_vendor_id FROM public.vendor_payment_qr
   WHERE owner_user_id = p_owner_user_id AND kind = 'static' AND status = 'active'
   ORDER BY created_at DESC LIMIT 1;
  -- Expire (jamais DELETE) tous les statiques actifs du propriétaire.
  UPDATE public.vendor_payment_qr SET status = 'expired'
   WHERE owner_user_id = p_owner_user_id AND kind = 'static' AND status = 'active';
  -- Nouveau token opaque.
  v_ref := translate(encode(gen_random_bytes(24), 'base64'), '+/=', '-_');
  INSERT INTO public.vendor_payment_qr (owner_user_id, vendor_id, kind, reference)
  VALUES (p_owner_user_id, v_vendor_id, 'static', v_ref);
  RAISE NOTICE '[vendor-qr] régénération owner=% (ancien autocollant inerte)', p_owner_user_id;
  RETURN v_ref;
END;
$$;
REVOKE ALL ON FUNCTION public.vendor_payment_qr_regenerate(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.vendor_payment_qr_regenerate(uuid) TO authenticated, service_role;

-- ── BLOC 5 : devis complet (lecture seule) pour l'écran AVANT PIN ──
-- Renvoie les DEUX montants + frais + total débité + suffisance du solde. Lève FX_INDISPONIBLE si
-- le taux est malsain (le payeur voit un refus propre, jamais un taux douteux).
CREATE OR REPLACE FUNCTION public.wallet_pay_quote(
  p_client_user_id uuid, p_qr_reference text, p_amount numeric)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_qr RECORD; v_cfg public.wallet_pay_config; v_owner uuid;
  v_client_cur text; v_client_bal numeric; v_vendor_cur text; v_vendor_id uuid;
  v_debit numeric; v_equiv numeric; v_rate numeric; v_source text;
  v_client_fee numeric; v_total numeric; v_name text;
BEGIN
  v_cfg := public.wallet_pay_active_config();
  SELECT * INTO v_qr FROM public.vendor_payment_qr WHERE reference = p_qr_reference;
  IF NOT FOUND OR v_qr.status <> 'active' THEN RAISE EXCEPTION 'QR_INVALIDE'; END IF;
  IF v_qr.expires_at IS NOT NULL AND v_qr.expires_at < now() THEN RAISE EXCEPTION 'QR_EXPIRE'; END IF;

  v_owner := COALESCE(v_qr.owner_user_id, (SELECT user_id FROM public.vendors WHERE id = v_qr.vendor_id));
  IF v_owner IS NULL THEN RAISE EXCEPTION 'BENEFICIAIRE_INTROUVABLE'; END IF;

  SELECT balance, currency INTO v_client_bal, v_client_cur FROM public.wallets
    WHERE user_id = p_client_user_id ORDER BY created_at ASC LIMIT 1;
  SELECT currency INTO v_vendor_cur FROM public.wallets
    WHERE user_id = v_owner ORDER BY created_at ASC LIMIT 1;
  IF v_client_cur IS NULL OR v_vendor_cur IS NULL THEN RAISE EXCEPTION 'WALLET_INTROUVABLE'; END IF;

  -- Nom d'affichage : boutique, sinon nom commercial prestataire — JAMAIS le nom civil.
  v_vendor_id := v_qr.vendor_id;
  SELECT business_name INTO v_name FROM public.vendors WHERE id = v_vendor_id;
  IF v_name IS NULL THEN
    SELECT business_name INTO v_name FROM public.professional_services
      WHERE user_id = v_owner AND status = 'active' ORDER BY created_at ASC LIMIT 1;
  END IF;

  -- Montant payeur (devise client). Dynamique : prix fixé (devise vendeur) → équivalent client.
  IF v_qr.kind = 'dynamic' THEN
    SELECT converted_amount INTO v_debit FROM public.wallet_fx_resolve(v_vendor_cur, v_client_cur, v_qr.amount);
  ELSE
    v_debit := p_amount;
  END IF;
  IF v_debit IS NULL OR v_debit <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;

  -- Équivalent bénéficiaire (devise vendeur) au taux sain verrouillable.
  SELECT converted_amount, rate_used, rate_source INTO v_equiv, v_rate, v_source
    FROM public.wallet_fx_resolve(v_client_cur, v_vendor_cur, v_debit);

  v_client_fee := round(v_debit * v_cfg.qr_wallet_client_fee_percent / 100.0, 2);
  v_total := v_debit + v_client_fee;   -- total débité au client, dans SA devise

  RETURN jsonb_build_object(
    'vendor_name', COALESCE(v_name, 'Bénéficiaire'),
    'kind', v_qr.kind,
    'client_currency', v_client_cur,
    'vendor_currency', v_vendor_cur,
    'amount', v_debit,                 -- ce que paie le client (sa devise)
    'equivalent', v_equiv,             -- ce que reçoit le vendeur (sa devise)
    'rate_used', v_rate,
    'rate_source', v_source,
    'is_cross_currency', (v_client_cur <> v_vendor_cur),
    'client_fee', v_client_fee,
    'client_fee_percent', v_cfg.qr_wallet_client_fee_percent,
    'total_debit', v_total,            -- montant + frais
    'client_balance', v_client_bal,
    'sufficient', (v_client_bal >= v_total)   -- solde vérifié sur le TOTAL, dès la résolution
  );
END;
$$;
REVOKE ALL ON FUNCTION public.wallet_pay_quote(uuid, text, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wallet_pay_quote(uuid, text, numeric) TO authenticated, service_role;
