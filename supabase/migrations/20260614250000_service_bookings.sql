-- ============================================================================
-- SERVICES DE PROXIMITÉ — Réservations / RDV PARTAGÉES (Ménage, Fitness, Coach,
-- Réparation, Photo, Éducation… : tout service « sur rendez-vous »).
-- ----------------------------------------------------------------------------
-- Une table générique `service_bookings` + RPC atomiques durcis (REVOKE FROM PUBLIC),
-- réutilisable par TOUS les modules de proximité (comme le shell artisan). Le prestataire
-- enregistre/gère ses RDV, le client (s'il a un compte) suit/annule les siens.
-- Rejouable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.proximity_bookings (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id       uuid REFERENCES public.professional_services(id) ON DELETE CASCADE,
  provider_id      uuid NOT NULL REFERENCES auth.users(id),
  client_id        uuid REFERENCES auth.users(id),
  customer_name    text,
  customer_phone   text,
  service_code     text,
  service_label    text,
  scheduled_date   date,
  scheduled_time   text,
  duration_minutes integer,
  address          text,
  price            numeric(12,2) NOT NULL DEFAULT 0,
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','confirmed','in_progress','completed','cancelled')),
  recurring        boolean NOT NULL DEFAULT false,
  frequency        text,
  notes            text,
  metadata         jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_proximity_bookings_provider ON public.proximity_bookings (provider_id, scheduled_date DESC);
CREATE INDEX IF NOT EXISTS idx_proximity_bookings_service  ON public.proximity_bookings (service_id, status);
CREATE INDEX IF NOT EXISTS idx_proximity_bookings_client   ON public.proximity_bookings (client_id, created_at DESC);

-- ── RLS : prestataire + client voient/gèrent les leurs ──────────────────────
ALTER TABLE public.proximity_bookings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS proximity_bookings_select_own ON public.proximity_bookings;
CREATE POLICY proximity_bookings_select_own ON public.proximity_bookings
  FOR SELECT TO authenticated USING (provider_id = auth.uid() OR client_id = auth.uid() OR public.is_admin_or_pdg());

-- ── RPC : créer une réservation (prestataire OU client). Atomique, validée. ──
CREATE OR REPLACE FUNCTION public.create_service_booking(
  p_service_id uuid, p_actor_user_id uuid,
  p_customer_name text, p_customer_phone text,
  p_service_code text, p_service_label text,
  p_scheduled_date date, p_scheduled_time text, p_duration_minutes integer,
  p_address text, p_price numeric, p_recurring boolean, p_frequency text, p_notes text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_provider uuid; v_client uuid; v_status text; v_id uuid;
BEGIN
  IF p_actor_user_id IS NULL THEN RAISE EXCEPTION 'NO_ACTOR'; END IF;
  SELECT user_id INTO v_provider FROM public.professional_services WHERE id = p_service_id;
  IF v_provider IS NULL THEN RAISE EXCEPTION 'SERVICE_NOT_FOUND'; END IF;

  -- Le prestataire enregistre un RDV (client walk-in) → confirmé d'office ; un client
  -- demande un RDV → en attente de confirmation du prestataire.
  IF p_actor_user_id = v_provider THEN
    v_client := NULL; v_status := 'confirmed';
  ELSE
    v_client := p_actor_user_id; v_status := 'pending';
  END IF;

  INSERT INTO public.proximity_bookings (
    service_id, provider_id, client_id, customer_name, customer_phone, service_code, service_label,
    scheduled_date, scheduled_time, duration_minutes, address, price, status, recurring, frequency, notes
  ) VALUES (
    p_service_id, v_provider, v_client, p_customer_name, p_customer_phone, p_service_code, p_service_label,
    p_scheduled_date, p_scheduled_time, p_duration_minutes, p_address, COALESCE(p_price,0), v_status,
    COALESCE(p_recurring,false), p_frequency, p_notes
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'booking_id', v_id, 'status', v_status);
END;
$$;

-- ── RPC : changer le statut. Prestataire = toutes transitions ; client = annuler. ──
CREATE OR REPLACE FUNCTION public.update_service_booking_status(
  p_booking_id uuid, p_actor_user_id uuid, p_status text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b public.proximity_bookings%ROWTYPE;
BEGIN
  SELECT * INTO b FROM public.proximity_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BOOKING_NOT_FOUND'; END IF;
  IF p_actor_user_id <> b.provider_id AND p_actor_user_id <> b.client_id THEN RAISE EXCEPTION 'NOT_AUTHORIZED'; END IF;
  IF p_status NOT IN ('pending','confirmed','in_progress','completed','cancelled') THEN RAISE EXCEPTION 'BAD_STATUS'; END IF;
  -- Un client ne peut QUE annuler.
  IF p_actor_user_id = b.client_id AND p_actor_user_id <> b.provider_id AND p_status <> 'cancelled' THEN
    RAISE EXCEPTION 'CLIENT_CAN_ONLY_CANCEL';
  END IF;

  UPDATE public.proximity_bookings SET status = p_status, updated_at = now() WHERE id = p_booking_id;
  RETURN jsonb_build_object('success', true, 'status', p_status);
END;
$$;

-- ── Durcissement : REVOKE FROM PUBLIC, backend (service_role) uniquement ─────
REVOKE EXECUTE ON FUNCTION public.create_service_booking(uuid, uuid, text, text, text, text, date, text, integer, text, numeric, boolean, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.create_service_booking(uuid, uuid, text, text, text, text, date, text, integer, text, numeric, boolean, text, text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.update_service_booking_status(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.update_service_booking_status(uuid, uuid, text) TO service_role;

SELECT 'Réservations de proximité créées (service_bookings + RPC create/status durcies, REVOKE PUBLIC).' AS status;
