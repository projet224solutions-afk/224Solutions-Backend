-- ============================================================================
-- BEAUTÉ (PHASE 3) — réservation client + no-show (Fresha/StyleSeat).
-- ----------------------------------------------------------------------------
-- Schéma LIVE : beauty_appointments utilise professional_service_id / duration_minutes
-- / total_price. On ajoute le lien client + la pénalité no-show, la lecture publique des
-- services, la RLS client, et la RPC atomique de pénalité. Rejouable.
-- ============================================================================

-- ── Colonnes pour la réservation en ligne + no-show ─────────────────────────
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS customer_user_id uuid REFERENCES auth.users(id);
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS no_show_fee numeric(10,2) NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_beauty_appt_service_date ON public.beauty_appointments (professional_service_id, appointment_date);
CREATE INDEX IF NOT EXISTS idx_beauty_appt_customer ON public.beauty_appointments (customer_user_id);

-- ── Lecture publique des services (le client doit voir le menu pour réserver) ─
ALTER TABLE public.beauty_services ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS beauty_services_public_read ON public.beauty_services;
CREATE POLICY beauty_services_public_read ON public.beauty_services
  FOR SELECT USING (is_active = true);

-- ── RLS client sur les rendez-vous (créer/voir les siens) ───────────────────
ALTER TABLE public.beauty_appointments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS beauty_appt_client_insert ON public.beauty_appointments;
CREATE POLICY beauty_appt_client_insert ON public.beauty_appointments
  FOR INSERT TO authenticated WITH CHECK (customer_user_id = auth.uid());
DROP POLICY IF EXISTS beauty_appt_client_select ON public.beauty_appointments;
CREATE POLICY beauty_appt_client_select ON public.beauty_appointments
  FOR SELECT TO authenticated USING (customer_user_id = auth.uid());

-- ── RPC : pénalité no-show (prestataire) — débit client → crédit prestataire ─
CREATE OR REPLACE FUNCTION public.mark_beauty_no_show_atomic(p_appointment_id uuid, p_actor_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a public.beauty_appointments%ROWTYPE; v_provider uuid; v_fee numeric;
BEGIN
  SELECT * INTO a FROM public.beauty_appointments WHERE id = p_appointment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'APPOINTMENT_NOT_FOUND'; END IF;
  SELECT user_id INTO v_provider FROM public.professional_services WHERE id = a.professional_service_id;
  IF p_actor_user_id <> v_provider THEN RAISE EXCEPTION 'NOT_PROVIDER'; END IF;
  IF a.status = 'no_show' THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;

  UPDATE public.beauty_appointments SET status = 'no_show' WHERE id = p_appointment_id;

  v_fee := COALESCE(a.no_show_fee, 0);
  IF a.customer_user_id IS NOT NULL AND v_fee > 0 THEN
    PERFORM public.wallet_debit_internal(a.customer_user_id, v_fee, 'Pénalité no-show (RDV beauté)', 'beauty-noshow-' || a.id::text);
    PERFORM public.credit_user_wallet_safe(v_provider, v_fee, 'GNF', 'beauty_no_show_fee', a.id::text);
    RETURN jsonb_build_object('success', true, 'fee_charged', v_fee);
  END IF;
  RETURN jsonb_build_object('success', true, 'fee_charged', 0);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.mark_beauty_no_show_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mark_beauty_no_show_atomic(uuid, uuid) TO service_role;

-- ── RPC : créneaux occupés (sans PII) pour le calcul des disponibilités client ─
CREATE OR REPLACE FUNCTION public.get_beauty_busy_slots(p_service_id uuid, p_date date)
RETURNS TABLE (start_min integer, end_min integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT (extract(hour from appointment_time) * 60 + extract(minute from appointment_time))::int AS start_min,
         (extract(hour from appointment_time) * 60 + extract(minute from appointment_time) + COALESCE(duration_minutes, 30))::int AS end_min
  FROM public.beauty_appointments
  WHERE professional_service_id = p_service_id AND appointment_date = p_date AND status <> 'cancelled';
$$;
GRANT EXECUTE ON FUNCTION public.get_beauty_busy_slots(uuid, date) TO anon, authenticated;

SELECT 'Beauté : réservation client + no-show + créneaux (schéma professional_service_id/duration_minutes).' AS status;
