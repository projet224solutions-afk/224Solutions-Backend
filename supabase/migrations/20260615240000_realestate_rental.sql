-- ============================================================================
-- IMMOBILIER / LOCATION (PHASE 3) — cycle locatif : bail digital + CAUTION en
-- ESCROW + quittances de loyer (signatures Beike / location longue durée).
-- ----------------------------------------------------------------------------
-- L'annonce (properties), les visites et le CRM existent déjà. On ajoute le flux
-- ARGENT atomique : le locataire démarre un bail (paie caution → escrow + 1er loyer),
-- paie ses loyers (quittance auto), et le bailleur libère/rembourse la caution à la fin.
-- Commission via resolve_service_commission_rate('location', défaut 0%). REVOKE PUBLIC.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.rental_leases (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id             uuid NOT NULL REFERENCES public.properties(id) ON DELETE CASCADE,
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  tenant_user_id          uuid REFERENCES auth.users(id),
  tenant_name             text,
  tenant_phone            text,
  monthly_rent            numeric(12,2) NOT NULL DEFAULT 0,
  deposit_amount          numeric(12,2) NOT NULL DEFAULT 0,
  deposit_status          text NOT NULL DEFAULT 'none' CHECK (deposit_status IN ('none','held','released','refunded')),
  start_date              date,
  end_date                date,
  lease_terms             text,
  status                  text NOT NULL DEFAULT 'active' CHECK (status IN ('active','ended','cancelled')),
  signed_at               timestamptz DEFAULT now(),
  created_at              timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_rental_leases_service ON public.rental_leases (professional_service_id, status);
CREATE INDEX IF NOT EXISTS idx_rental_leases_tenant ON public.rental_leases (tenant_user_id);
CREATE INDEX IF NOT EXISTS idx_rental_leases_property ON public.rental_leases (property_id);

CREATE TABLE IF NOT EXISTS public.rent_payments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lease_id      uuid NOT NULL REFERENCES public.rental_leases(id) ON DELETE CASCADE,
  period_label  text NOT NULL,                 -- ex: '2026-06'
  amount        numeric(12,2) NOT NULL DEFAULT 0,
  receipt_code  text UNIQUE,
  paid_at       timestamptz DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_rent_payment_period ON public.rent_payments (lease_id, period_label);

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.rental_leases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rent_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS leases_owner ON public.rental_leases;
CREATE POLICY leases_owner ON public.rental_leases
  FOR ALL USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS leases_tenant_read ON public.rental_leases;
CREATE POLICY leases_tenant_read ON public.rental_leases
  FOR SELECT TO authenticated USING (tenant_user_id = auth.uid());

DROP POLICY IF EXISTS rentpay_read ON public.rent_payments;
CREATE POLICY rentpay_read ON public.rent_payments FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.rental_leases l WHERE l.id = lease_id AND (
    l.tenant_user_id = auth.uid() OR public.check_service_owner(l.professional_service_id)))
);

-- ── RPC : le locataire DÉMARRE un bail (caution → escrow + 1er loyer → bailleur) ──
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

  -- Débit locataire : caution (escrow) + 1er loyer
  PERFORM public.wallet_debit_internal(p_actor_user_id, v_deposit + v_rent, 'Location : caution + 1er loyer', 'rent-start-' || p_property_id::text || '-' || p_actor_user_id::text);

  -- Crédit bailleur du 1er loyer net commission (la caution RESTE en escrow)
  v_rate := public.resolve_service_commission_rate(v_owner, 'location', 0);
  v_commission := round(v_rent * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  PERFORM public.credit_user_wallet_safe(v_owner, v_rent - v_commission, 'GNF', 'rent_payment', p_property_id::text);
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'rent_commission', p_property_id::text);
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

-- ── RPC : le locataire PAIE un loyer mensuel (quittance auto) ────────────────
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
  PERFORM public.wallet_debit_internal(p_actor_user_id, l.monthly_rent, 'Loyer ' || p_period, 'rent-' || p_lease_id::text || '-' || p_period);
  v_rate := public.resolve_service_commission_rate(v_owner, 'location', 0);
  v_commission := round(l.monthly_rent * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  PERFORM public.credit_user_wallet_safe(v_owner, l.monthly_rent - v_commission, 'GNF', 'rent_payment', p_lease_id::text);
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'rent_commission', p_lease_id::text);
  END IF;

  v_receipt := 'QUIT-' || p_period || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  INSERT INTO public.rent_payments (lease_id, period_label, amount, receipt_code)
  VALUES (p_lease_id, p_period, l.monthly_rent, v_receipt);
  RETURN jsonb_build_object('success', true, 'receipt', v_receipt);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.pay_rent_atomic(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_rent_atomic(uuid, uuid, text) TO service_role;

-- ── RPC : le BAILLEUR clôture le bail et libère la caution (rembourse ou retient) ──
CREATE OR REPLACE FUNCTION public.release_deposit_atomic(p_actor_user_id uuid, p_lease_id uuid, p_refund boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE l public.rental_leases%ROWTYPE; v_owner uuid;
BEGIN
  SELECT * INTO l FROM public.rental_leases WHERE id = p_lease_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LEASE_NOT_FOUND'; END IF;
  SELECT owner_id INTO v_owner FROM public.properties WHERE id = l.property_id;
  IF v_owner <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_OWNER'; END IF;
  IF l.deposit_status <> 'held' THEN RETURN jsonb_build_object('success', true, 'already', true, 'status', l.deposit_status); END IF;

  IF p_refund THEN
    PERFORM public.credit_user_wallet_safe(l.tenant_user_id, l.deposit_amount, 'GNF', 'deposit_refund', p_lease_id::text);
    UPDATE public.rental_leases SET deposit_status = 'refunded', status = 'ended' WHERE id = p_lease_id;
  ELSE
    PERFORM public.credit_user_wallet_safe(v_owner, l.deposit_amount, 'GNF', 'deposit_kept', p_lease_id::text);
    UPDATE public.rental_leases SET deposit_status = 'released', status = 'ended' WHERE id = p_lease_id;
  END IF;
  UPDATE public.properties SET status = 'disponible', updated_at = now() WHERE id = l.property_id;
  RETURN jsonb_build_object('success', true, 'refunded', p_refund);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.release_deposit_atomic(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.release_deposit_atomic(uuid, uuid, boolean) TO service_role;

SELECT 'Immobilier locatif créé : baux + caution escrow + quittances + RPC atomiques.' AS status;
