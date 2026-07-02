-- ============================================================================
-- DURCISSEMENT ATOMIQUE — LOYER : idempotence par paiement (fin du bug "payé 1x")
-- ----------------------------------------------------------------------------
-- 🔴 BUG CORRIGÉ : credit_user_wallet_safe est idempotent par (source_type,
-- source_txn_id). Les crédits bailleur/PDG utilisaient source_txn_id = lease_id
-- (pay_rent, IDENTIQUE chaque mois) et = property_id (start, IDENTIQUE à chaque
-- re-location) → à partir du 2e mois / de la 2e location, le crédit était
-- SILENCIEUSEMENT "skipped" (le bailleur n'était plus payé, le PDG plus crédité).
-- FIX : source_txn_id UNIQUE par paiement :
--   • pay_rent  : lease_id || '-' || period   (1 crédit par mois)
--   • start     : lease_id (généré) → le bail INSERT est déplacé AVANT les crédits.
-- + garde : on vérifie que le crédit bailleur a bien eu lieu (ni skip ni 0) → sinon
--   EXCEPTION → ROLLBACK total (atomique). Idempotence des retries préservée :
--   pay_rent par la garde de période (rent_payments), start par le statut du bien.
-- ============================================================================

-- ── start_rental_lease_atomic : bail créé AVANT les crédits (source_txn_id = lease_id) ──
CREATE OR REPLACE FUNCTION public.start_rental_lease_atomic(
  p_actor_user_id uuid, p_property_id uuid, p_deposit_months numeric DEFAULT 1,
  p_tenant_name text DEFAULT NULL, p_tenant_phone text DEFAULT NULL,
  p_start_date date DEFAULT NULL, p_end_date date DEFAULT NULL, p_terms text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pr public.properties%ROWTYPE; v_owner uuid; v_psid uuid; v_rent numeric; v_deposit numeric;
        v_rate numeric; v_commission numeric; v_pdg uuid; v_lease uuid; v_period text; v_receipt text;
        v_res jsonb; v_got numeric;
BEGIN
  SELECT * INTO pr FROM public.properties WHERE id = p_property_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROPERTY_NOT_FOUND'; END IF;
  IF pr.offer_type <> 'location' THEN RAISE EXCEPTION 'NOT_FOR_RENT'; END IF;
  IF pr.status NOT IN ('disponible','sous_option') THEN RAISE EXCEPTION 'NOT_AVAILABLE'; END IF;

  v_psid := pr.professional_service_id; v_owner := pr.owner_id;
  v_rent := pr.price; v_deposit := round(v_rent * COALESCE(p_deposit_months,1));
  IF v_owner = p_actor_user_id THEN RAISE EXCEPTION 'OWN_PROPERTY'; END IF;
  IF v_rent <= 0 THEN RAISE EXCEPTION 'BAD_RENT'; END IF;

  v_rate := public.resolve_service_commission_rate(v_owner, 'location', 0);
  v_commission := round(v_rent * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  -- Débit locataire : caution (→ escrow) + 1er loyer + commission (solde vérifié sur le TOTAL).
  PERFORM public.wallet_debit_internal(p_actor_user_id, v_deposit + v_rent + v_commission, 'Location : caution + 1er loyer + commission', 'rent-start-' || p_property_id::text || '-' || p_actor_user_id::text);

  -- Bail créé AVANT les crédits → lease_id sert de clé d'idempotence UNIQUE par location.
  INSERT INTO public.rental_leases (property_id, professional_service_id, tenant_user_id, tenant_name, tenant_phone,
    monthly_rent, deposit_amount, deposit_status, start_date, end_date, lease_terms, status)
  VALUES (p_property_id, v_psid, p_actor_user_id, p_tenant_name, p_tenant_phone,
    v_rent, v_deposit, 'held', COALESCE(p_start_date, current_date), p_end_date, p_terms, 'active')
  RETURNING id INTO v_lease;

  -- Crédit bailleur du 1er loyer COMPLET (garde : doit être crédité, sinon ROLLBACK).
  v_res := public.credit_user_wallet_safe(v_owner, v_rent, 'GNF', 'rent_payment', v_lease::text);
  v_got := COALESCE((v_res->>'credited')::numeric,0) + COALESCE((v_res->>'quarantined')::numeric,0);
  IF NOT COALESCE((v_res->>'skipped')::boolean, false) AND v_got <= 0 THEN RAISE EXCEPTION 'CREDIT_BAILLEUR_ECHOUE (%)', COALESCE(v_res->>'error','?'); END IF;

  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'rent_commission', v_lease::text);
    BEGIN
      PERFORM public.credit_agent_commission(v_owner, v_commission, 'rent', md5('rent-start-'||v_lease::text)::uuid,
        jsonb_build_object('currency','GNF','flow','rent','lease_id',v_lease,'phase','start'));
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'commission agent loyer(start) non appliquée (%): %', v_lease, SQLERRM; END;
  END IF;

  v_period := to_char(COALESCE(p_start_date, current_date), 'YYYY-MM');
  v_receipt := 'QUIT-' || v_period || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  INSERT INTO public.rent_payments (lease_id, period_label, amount, receipt_code)
  VALUES (v_lease, v_period, v_rent, v_receipt);

  UPDATE public.properties SET status = 'loue', updated_at = now() WHERE id = p_property_id;
  RETURN jsonb_build_object('success', true, 'lease_id', v_lease, 'deposit', v_deposit, 'receipt', v_receipt);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.start_rental_lease_atomic(uuid, uuid, numeric, text, text, date, date, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.start_rental_lease_atomic(uuid, uuid, numeric, text, text, date, date, text) TO service_role;

-- ── pay_rent_atomic : idempotence par (lease_id + période) ──────────────────
CREATE OR REPLACE FUNCTION public.pay_rent_atomic(p_actor_user_id uuid, p_lease_id uuid, p_period text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE l public.rental_leases%ROWTYPE; v_owner uuid; v_rate numeric; v_commission numeric; v_pdg uuid;
        v_receipt text; v_exists uuid; v_key text; v_res jsonb; v_got numeric;
BEGIN
  SELECT * INTO l FROM public.rental_leases WHERE id = p_lease_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LEASE_NOT_FOUND'; END IF;
  IF l.tenant_user_id <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_TENANT'; END IF;
  IF l.status <> 'active' THEN RAISE EXCEPTION 'LEASE_NOT_ACTIVE'; END IF;

  -- Garde de rejeu : une période déjà réglée ne se re-débite pas.
  SELECT id INTO v_exists FROM public.rent_payments WHERE lease_id = p_lease_id AND period_label = p_period;
  IF v_exists IS NOT NULL THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;

  SELECT owner_id INTO v_owner FROM public.properties WHERE id = l.property_id;
  v_rate := public.resolve_service_commission_rate(v_owner, 'location', 0);
  v_commission := round(l.monthly_rent * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  v_key := p_lease_id::text || '-' || p_period;   -- clé d'idempotence UNIQUE par mois

  PERFORM public.wallet_debit_internal(p_actor_user_id, l.monthly_rent + v_commission, 'Loyer ' || p_period || ' + commission', 'rent-' || v_key);

  -- Crédit bailleur du loyer COMPLET (garde : doit être crédité, sinon ROLLBACK).
  v_res := public.credit_user_wallet_safe(v_owner, l.monthly_rent, 'GNF', 'rent_payment', v_key);
  v_got := COALESCE((v_res->>'credited')::numeric,0) + COALESCE((v_res->>'quarantined')::numeric,0);
  IF NOT COALESCE((v_res->>'skipped')::boolean, false) AND v_got <= 0 THEN RAISE EXCEPTION 'CREDIT_BAILLEUR_ECHOUE (%)', COALESCE(v_res->>'error','?'); END IF;

  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'rent_commission', v_key);
    BEGIN
      PERFORM public.credit_agent_commission(v_owner, v_commission, 'rent', md5('rent-'||v_key)::uuid,
        jsonb_build_object('currency','GNF','flow','rent','lease_id',p_lease_id,'period',p_period));
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'commission agent loyer non appliquée (%): %', p_lease_id, SQLERRM; END;
  END IF;

  v_receipt := 'QUIT-' || p_period || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  INSERT INTO public.rent_payments (lease_id, period_label, amount, receipt_code)
  VALUES (p_lease_id, p_period, l.monthly_rent, v_receipt);
  RETURN jsonb_build_object('success', true, 'receipt', v_receipt);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.pay_rent_atomic(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_rent_atomic(uuid, uuid, text) TO service_role;

SELECT 'Loyer durci : idempotence par paiement (mois/bail) → bailleur payé chaque mois, garde crédit + ROLLBACK atomique.' AS status;
