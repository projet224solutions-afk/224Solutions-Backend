-- ============================================================================
-- BEAUTÉ — FONDATION FRESHA (Phase 1) : réservation PAYANTE atomique (dépôt, domicile,
-- walk-in) + fidélité + notes client + paramètres prestataire.
-- ----------------------------------------------------------------------------
-- On ÉTEND les tables live (beauty_services / beauty_appointments) au lieu de créer
-- une table beauty_bookings parallèle (la base utilise déjà beauty_appointments avec
-- professional_service_id). Paiement via les primitives atomiques de la plateforme
-- (wallet_debit_internal + credit_user_wallet_safe). Beauté = 0 % commission (Fresha).
-- Rejouable.
-- ============================================================================

-- ── Services : dépôt, domicile ──────────────────────────────────────────────
ALTER TABLE public.beauty_services ADD COLUMN IF NOT EXISTS deposit_required       numeric(10,2) NOT NULL DEFAULT 0;
ALTER TABLE public.beauty_services ADD COLUMN IF NOT EXISTS is_home_service        boolean       NOT NULL DEFAULT false;
ALTER TABLE public.beauty_services ADD COLUMN IF NOT EXISTS home_service_extra_fee numeric(10,2) NOT NULL DEFAULT 0;

-- ── RDV : type de réservation, dépôt, solde, pénalité, paiement, avis ────────
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS booking_type     text NOT NULL DEFAULT 'salon';
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS client_address   text;
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS total_price      numeric(10,2) NOT NULL DEFAULT 0;
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS deposit_paid     numeric(10,2) NOT NULL DEFAULT 0;
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS remaining_amount numeric(10,2) NOT NULL DEFAULT 0;
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS penalty_applied  numeric(10,2) NOT NULL DEFAULT 0;
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS paid             boolean       NOT NULL DEFAULT false;
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS idempotency_key  text;
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS rating           integer;
ALTER TABLE public.beauty_appointments ADD COLUMN IF NOT EXISTS review_text      text;
CREATE UNIQUE INDEX IF NOT EXISTS uq_beauty_appt_idem ON public.beauty_appointments (idempotency_key) WHERE idempotency_key IS NOT NULL;

-- ── Paramètres prestataire (walk-in, annulation, fidélité) ──────────────────
CREATE TABLE IF NOT EXISTS public.beauty_settings (
  professional_service_id uuid PRIMARY KEY REFERENCES public.professional_services(id) ON DELETE CASCADE,
  accepts_walkin       boolean NOT NULL DEFAULT false,
  cancel_window_hours  integer NOT NULL DEFAULT 24,
  noshow_penalty_pct   numeric(5,2) NOT NULL DEFAULT 50,
  loyalty_threshold    integer NOT NULL DEFAULT 10,
  loyalty_reward       text,
  reminder_day_before_hour integer NOT NULL DEFAULT 18,
  updated_at           timestamptz DEFAULT now()
);

-- ── Notes client (privées, prestataire uniquement) ──────────────────────────
CREATE TABLE IF NOT EXISTS public.beauty_client_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  client_user_id uuid REFERENCES auth.users(id),
  client_phone   text,
  notes          text,
  allergies      text,
  preferences    text,
  updated_at     timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_beauty_notes_service ON public.beauty_client_notes (professional_service_id);

-- ── Fidélité ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.beauty_loyalty (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  client_user_id   uuid REFERENCES auth.users(id),
  visits_count     integer NOT NULL DEFAULT 0,
  visits_threshold integer NOT NULL DEFAULT 10,
  last_rewarded_at timestamptz,
  created_at       timestamptz DEFAULT now(),
  UNIQUE (professional_service_id, client_user_id)
);

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.beauty_settings     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beauty_client_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beauty_loyalty      ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bset_owner ON public.beauty_settings;
CREATE POLICY bset_owner ON public.beauty_settings
  FOR ALL USING (public.check_service_owner(professional_service_id)) WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS bset_public_read ON public.beauty_settings;
CREATE POLICY bset_public_read ON public.beauty_settings FOR SELECT USING (true);

DROP POLICY IF EXISTS bnotes_owner ON public.beauty_client_notes;
CREATE POLICY bnotes_owner ON public.beauty_client_notes
  FOR ALL USING (public.check_service_owner(professional_service_id)) WITH CHECK (public.check_service_owner(professional_service_id));

DROP POLICY IF EXISTS bloy_owner ON public.beauty_loyalty;
CREATE POLICY bloy_owner ON public.beauty_loyalty
  FOR ALL USING (public.check_service_owner(professional_service_id)) WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS bloy_client_read ON public.beauty_loyalty;
CREATE POLICY bloy_client_read ON public.beauty_loyalty
  FOR SELECT TO authenticated USING (client_user_id = auth.uid());

-- ── RPC : RÉSERVATION PAYANTE ATOMIQUE (verrou créneau + idempotence + dépôt) ─
CREATE OR REPLACE FUNCTION public.process_beauty_booking_atomic(
  p_actor_user_id uuid, p_service_id uuid, p_beauty_service_id uuid,
  p_slot_date date, p_slot_time time, p_booking_type text DEFAULT 'salon',
  p_client_address text DEFAULT NULL, p_customer_name text DEFAULT NULL, p_customer_phone text DEFAULT NULL,
  p_idempotency_key text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  bs public.beauty_services%ROWTYPE; v_provider uuid; v_dur int; v_price numeric; v_extra numeric;
  v_charge numeric; v_deposit numeric; v_remaining numeric; v_end time; v_taken boolean; v_appt uuid; v_existing uuid;
BEGIN
  IF p_idempotency_key IS NOT NULL THEN
    SELECT id INTO v_existing FROM public.beauty_appointments WHERE idempotency_key = p_idempotency_key;
    IF v_existing IS NOT NULL THEN RETURN jsonb_build_object('success', true, 'already', true, 'booking_id', v_existing); END IF;
  END IF;

  SELECT * INTO bs FROM public.beauty_services WHERE id = p_beauty_service_id AND professional_service_id = p_service_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'SERVICE_NOT_FOUND'; END IF;
  IF NOT bs.is_active THEN RAISE EXCEPTION 'SERVICE_INACTIVE'; END IF;

  SELECT user_id INTO v_provider FROM public.professional_services WHERE id = p_service_id;
  IF v_provider = p_actor_user_id THEN RAISE EXCEPTION 'OWN_SERVICE'; END IF;

  v_dur := COALESCE(bs.duration_minutes, 30);
  v_extra := CASE WHEN p_booking_type = 'home' THEN COALESCE(bs.home_service_extra_fee,0) ELSE 0 END;
  v_price := COALESCE(bs.price,0) + v_extra;
  v_deposit := COALESCE(bs.deposit_required,0);
  v_charge := CASE WHEN v_deposit > 0 THEN v_deposit ELSE v_price END;   -- dépôt si configuré, sinon total
  v_remaining := v_price - v_charge;
  v_end := p_slot_time + (v_dur || ' minutes')::interval;

  -- Verrou créneau : pas de chevauchement sur ce service ce jour-là.
  SELECT EXISTS (
    SELECT 1 FROM public.beauty_appointments a
    WHERE a.professional_service_id = p_service_id AND a.appointment_date = p_slot_date
      AND a.status NOT IN ('cancelled','no_show')
      AND a.appointment_time < v_end
      AND (a.appointment_time + (COALESCE(a.duration_minutes,30) || ' minutes')::interval) > p_slot_time
  ) INTO v_taken;
  IF v_taken THEN RAISE EXCEPTION 'CRENEAU_DEJA_PRIS'; END IF;

  -- Paiement atomique (Beauté = 0 % commission). Débit client → crédit prestataire.
  IF v_charge > 0 THEN
    PERFORM public.wallet_debit_internal(p_actor_user_id, v_charge, 'Réservation beauté', COALESCE(p_idempotency_key, 'beauty-' || p_service_id::text || '-' || p_actor_user_id::text || '-' || p_slot_date::text || '-' || p_slot_time::text));
    PERFORM public.credit_user_wallet_safe(v_provider, v_charge, 'GNF', 'beauty_booking', p_service_id::text);
  END IF;

  INSERT INTO public.beauty_appointments (
    professional_service_id, beauty_service_id, customer_user_id, customer_name, customer_phone,
    appointment_date, appointment_time, duration_minutes, total_price, deposit_paid, remaining_amount,
    booking_type, client_address, no_show_fee, paid, status, idempotency_key
  ) VALUES (
    p_service_id, p_beauty_service_id, p_actor_user_id, p_customer_name, p_customer_phone,
    p_slot_date, p_slot_time, v_dur, v_price, v_charge, v_remaining,
    p_booking_type, p_client_address, round(v_price * 0.5), (v_charge >= v_price), 'confirmed', p_idempotency_key
  ) RETURNING id INTO v_appt;

  -- Fidélité : +1 visite.
  INSERT INTO public.beauty_loyalty (professional_service_id, client_user_id, visits_count)
  VALUES (p_service_id, p_actor_user_id, 1)
  ON CONFLICT (professional_service_id, client_user_id)
  DO UPDATE SET visits_count = public.beauty_loyalty.visits_count + 1;

  RETURN jsonb_build_object('success', true, 'booking_id', v_appt, 'charged', v_charge, 'remaining', v_remaining, 'total', v_price);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.process_beauty_booking_atomic(uuid, uuid, uuid, date, time, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.process_beauty_booking_atomic(uuid, uuid, uuid, date, time, text, text, text, text, text) TO service_role;

SELECT 'Beauté Phase 1 : réservation payante atomique (dépôt/domicile/walk-in) + fidélité + notes + paramètres.' AS status;
