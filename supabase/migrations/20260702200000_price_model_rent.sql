-- ============================================================================
-- MODÈLE DE PRIX UNIFORME — LOYER (le bailleur reçoit TOUJOURS son loyer complet)
-- ----------------------------------------------------------------------------
-- Avant : le bailleur était crédité de `loyer − commission` (amputé). Après (modèle
-- marketplace) : le LOCATAIRE paie `loyer + commission`, le BAILLEUR reçoit le loyer
-- COMPLET, le PDG reçoit la commission. Invariant : débit == crédit bailleur + PDG.
-- On corrige les DEUX flux qui créditaient le bailleur : pay_rent_atomic (loyer
-- mensuel) ET start_rental_lease_atomic (1er loyer au démarrage du bail).
-- Seuls les MONTANTS changent + la commission est calculée AVANT le débit (pour
-- débiter le total). Idempotence, escrow caution, quittances : inchangés.
-- ============================================================================

-- ── start_rental_lease_atomic : caution (escrow) + 1er loyer COMPLET au bailleur ──
CREATE OR REPLACE FUNCTION public.start_rental_lease_atomic(
  p_actor_user_id uuid, p_property_id uuid, p_deposit_months numeric DEFAULT 1,
  p_tenant_name text DEFAULT NULL, p_tenant_phone text DEFAULT NULL,
  p_start_date date DEFAULT NULL, p_end_date date DEFAULT NULL, p_terms text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pr public.properties%ROWTYPE; v_owner uuid; v_psid uuid; v_rent numeric; v_deposit numeric;
        v_rate numeric; v_commission numeric; v_pdg uuid; v_lease uuid; v_period text; v_receipt text;
BEGIN
  SELECT * INTO pr FROM public.properties WHERE id = p_property_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROPERTY_NOT_FOUND'; END IF;
  IF pr.offer_type <> 'location' THEN RAISE EXCEPTION 'NOT_FOR_RENT'; END IF;
  IF pr.status NOT IN ('disponible','sous_option') THEN RAISE EXCEPTION 'NOT_AVAILABLE'; END IF;

  v_psid := pr.professional_service_id; v_owner := pr.owner_id;
  v_rent := pr.price; v_deposit := round(v_rent * COALESCE(p_deposit_months,1));
  IF v_owner = p_actor_user_id THEN RAISE EXCEPTION 'OWN_PROPERTY'; END IF;

  -- Commission calculée AVANT le débit (payée par le locataire EN PLUS du loyer).
  v_rate := public.resolve_service_commission_rate(v_owner, 'location', 0);
  v_commission := round(v_rent * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  -- Débit locataire : caution (→ escrow) + 1er loyer + commission plateforme.
  -- wallet_debit_internal vérifie le solde sur ce TOTAL et rejette si insuffisant.
  PERFORM public.wallet_debit_internal(p_actor_user_id, v_deposit + v_rent + v_commission, 'Location : caution + 1er loyer + commission', 'rent-start-' || p_property_id::text || '-' || p_actor_user_id::text);

  -- Crédit bailleur du 1er loyer COMPLET (la caution RESTE en escrow).
  PERFORM public.credit_user_wallet_safe(v_owner, v_rent, 'GNF', 'rent_payment', p_property_id::text);
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'rent_commission', p_property_id::text);
    -- Commission AGENT au créateur du service (= le bailleur), débitée du PDG. Non bloquante.
    BEGIN
      PERFORM public.credit_agent_commission(v_owner, v_commission, 'rent', md5('rent-start-'||p_property_id::text||'-'||p_actor_user_id::text)::uuid,
        jsonb_build_object('currency','GNF','flow','rent','property_id',p_property_id,'phase','start'));
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'commission agent loyer(start) non appliquée (%): %', p_property_id, SQLERRM; END;
  END IF;

  INSERT INTO public.rental_leases (property_id, professional_service_id, tenant_user_id, tenant_name, tenant_phone,
    monthly_rent, deposit_amount, deposit_status, start_date, end_date, lease_terms, status)
  VALUES (p_property_id, v_psid, p_actor_user_id, p_tenant_name, p_tenant_phone,
    v_rent, v_deposit, 'held', COALESCE(p_start_date, current_date), p_end_date, p_terms, 'active')
  RETURNING id INTO v_lease;

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

-- ── pay_rent_atomic : loyer mensuel COMPLET au bailleur ─────────────────────
CREATE OR REPLACE FUNCTION public.pay_rent_atomic(p_actor_user_id uuid, p_lease_id uuid, p_period text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE l public.rental_leases%ROWTYPE; v_owner uuid; v_rate numeric; v_commission numeric; v_pdg uuid; v_receipt text; v_exists uuid;
BEGIN
  SELECT * INTO l FROM public.rental_leases WHERE id = p_lease_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LEASE_NOT_FOUND'; END IF;
  IF l.tenant_user_id <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_TENANT'; END IF;
  IF l.status <> 'active' THEN RAISE EXCEPTION 'LEASE_NOT_ACTIVE'; END IF;

  SELECT id INTO v_exists FROM public.rent_payments WHERE lease_id = p_lease_id AND period_label = p_period;
  IF v_exists IS NOT NULL THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;

  SELECT owner_id INTO v_owner FROM public.properties WHERE id = l.property_id;
  -- Commission calculée AVANT le débit (payée par le locataire EN PLUS du loyer).
  v_rate := public.resolve_service_commission_rate(v_owner, 'location', 0);
  v_commission := round(l.monthly_rent * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  -- Débit locataire : loyer + commission (vérif de solde sur le total via wallet_debit_internal).
  PERFORM public.wallet_debit_internal(p_actor_user_id, l.monthly_rent + v_commission, 'Loyer ' || p_period || ' + commission', 'rent-' || p_lease_id::text || '-' || p_period);
  -- Crédit bailleur du loyer COMPLET.
  PERFORM public.credit_user_wallet_safe(v_owner, l.monthly_rent, 'GNF', 'rent_payment', p_lease_id::text);
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'rent_commission', p_lease_id::text);
    -- Commission AGENT au créateur du service (= le bailleur), débitée du PDG. Non bloquante.
    BEGIN
      PERFORM public.credit_agent_commission(v_owner, v_commission, 'rent', md5('rent-'||p_lease_id::text||'-'||p_period)::uuid,
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

SELECT 'Modèle prix loyer : bailleur reçoit le loyer complet, commission payée par le locataire.' AS status;
