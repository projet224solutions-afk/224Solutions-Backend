-- ============================================================================
-- MOBILITÉ (PHASE 3) — courses VTC & livraisons : dispatch + suivi + paiement
-- wallet atomique (signatures Uber / Glovo). Partagé par VTCModule & DeliveryModule.
-- ----------------------------------------------------------------------------
-- Le prestataire crée une course/livraison (départ→arrivée, prix), la traite
-- (accepté→en route→terminé). Le client paie en wallet (débit→net prestataire +
-- commission PDG) via la page publique, ou le prestataire encaisse en espèces.
-- RPC argent REVOKE FROM PUBLIC. Rejouable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.mobility_jobs (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  customer_user_id        uuid REFERENCES auth.users(id),
  customer_name           text,
  customer_phone          text,
  job_type                text NOT NULL DEFAULT 'course' CHECK (job_type IN ('course','livraison')),
  pickup                  text,
  destination             text,
  vehicle_type            text,
  package_label           text,
  price                   numeric(12,2) NOT NULL DEFAULT 0,
  status                  text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','in_progress','completed','cancelled')),
  payment_method          text NOT NULL DEFAULT 'cash' CHECK (payment_method IN ('cash','wallet')),
  paid                    boolean NOT NULL DEFAULT false,
  created_at              timestamptz DEFAULT now(),
  completed_at            timestamptz
);
CREATE INDEX IF NOT EXISTS idx_mobility_jobs_service ON public.mobility_jobs (professional_service_id, status);
CREATE INDEX IF NOT EXISTS idx_mobility_jobs_customer ON public.mobility_jobs (customer_user_id);

ALTER TABLE public.mobility_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mjobs_owner ON public.mobility_jobs;
CREATE POLICY mjobs_owner ON public.mobility_jobs
  FOR ALL USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS mjobs_customer_read ON public.mobility_jobs;
CREATE POLICY mjobs_customer_read ON public.mobility_jobs
  FOR SELECT TO authenticated USING (customer_user_id = auth.uid());

-- ── RPC : lecture d'une course/livraison partagée (page publique de paiement) ──
CREATE OR REPLACE FUNCTION public.get_shared_mobility_job(p_job_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE j public.mobility_jobs%ROWTYPE; v_biz text;
BEGIN
  SELECT * INTO j FROM public.mobility_jobs WHERE id = p_job_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;
  SELECT business_name INTO v_biz FROM public.professional_services WHERE id = j.professional_service_id;
  RETURN jsonb_build_object('found', true, 'id', j.id, 'job_type', j.job_type, 'pickup', j.pickup,
    'destination', j.destination, 'package_label', j.package_label, 'price', j.price, 'status', j.status,
    'paid', j.paid, 'business_name', v_biz);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.get_shared_mobility_job(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_shared_mobility_job(uuid) TO anon, authenticated, service_role;

-- ── RPC : le client PAIE la course/livraison en wallet (débit → net prestataire) ──
CREATE OR REPLACE FUNCTION public.settle_mobility_job_atomic(p_actor_user_id uuid, p_job_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE j public.mobility_jobs%ROWTYPE; v_provider uuid; v_code text; v_def numeric; v_rate numeric; v_commission numeric; v_pdg uuid;
BEGIN
  SELECT * INTO j FROM public.mobility_jobs WHERE id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'JOB_NOT_FOUND'; END IF;
  IF j.paid THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;
  IF j.status = 'cancelled' THEN RAISE EXCEPTION 'JOB_CANCELLED'; END IF;
  IF COALESCE(j.price,0) <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;

  SELECT ps.user_id, st.code, COALESCE(st.commission_rate, 10)
    INTO v_provider, v_code, v_def
  FROM public.professional_services ps JOIN public.service_types st ON st.id = ps.service_type_id
  WHERE ps.id = j.professional_service_id;
  IF v_provider = p_actor_user_id THEN RAISE EXCEPTION 'OWN_JOB'; END IF;

  PERFORM public.wallet_debit_internal(p_actor_user_id, j.price, 'Paiement ' || j.job_type, 'mobility-' || p_job_id::text);
  v_rate := public.resolve_service_commission_rate(v_provider, v_code, v_def);
  v_commission := round(j.price * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  PERFORM public.credit_user_wallet_safe(v_provider, j.price - v_commission, 'GNF', 'mobility_payment', p_job_id::text);
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'mobility_commission', p_job_id::text);
  END IF;

  UPDATE public.mobility_jobs SET paid = true, payment_method = 'wallet', status = 'completed',
    completed_at = now(), customer_user_id = COALESCE(customer_user_id, p_actor_user_id) WHERE id = p_job_id;
  RETURN jsonb_build_object('success', true);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.settle_mobility_job_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.settle_mobility_job_atomic(uuid, uuid) TO service_role;

SELECT 'Mobilité créée : mobility_jobs (course/livraison) + paiement wallet atomique.' AS status;
