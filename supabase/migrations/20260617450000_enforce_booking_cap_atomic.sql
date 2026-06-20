-- ============================================================================
-- 🔒 DURCISSEMENT — plafond de réservations du plan appliqué ATOMIQUEMENT.
--
-- Avant : create_service_booking n'imposait PAS max_bookings_per_month → la limite
-- n'était qu'UI (useServiceLimits / BookingManagement), donc contournable en appelant
-- le backend en boucle. On l'enforce DANS la RPC (même transaction que l'insert),
-- en réutilisant get_service_subscription (plan actif + repli plan gratuit).
--
-- Règle : on compte les RDV NON annulés du service créés dans le MOIS courant ;
-- si >= max_bookings (et max non NULL = non illimité) → BOOKING_LIMIT_REACHED.
-- Idempotent (CREATE OR REPLACE). Les grants existants sont conservés + ré-affirmés.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_service_booking(
  p_service_id uuid, p_actor_user_id uuid,
  p_customer_name text, p_customer_phone text,
  p_service_code text, p_service_label text,
  p_scheduled_date date, p_scheduled_time text, p_duration_minutes integer,
  p_address text, p_price numeric, p_recurring boolean, p_frequency text, p_notes text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_provider uuid; v_client uuid; v_status text; v_id uuid;
  v_max integer; v_count integer;
BEGIN
  IF p_actor_user_id IS NULL THEN RAISE EXCEPTION 'NO_ACTOR'; END IF;
  SELECT user_id INTO v_provider FROM public.professional_services WHERE id = p_service_id;
  IF v_provider IS NULL THEN RAISE EXCEPTION 'SERVICE_NOT_FOUND'; END IF;

  -- ── Plafond du plan (atomique) : max_bookings_per_month du plan actif (ou gratuit) ──
  SELECT max_bookings INTO v_max FROM public.get_service_subscription(p_service_id) LIMIT 1;
  IF v_max IS NOT NULL THEN
    SELECT count(*) INTO v_count
    FROM public.proximity_bookings
    WHERE service_id = p_service_id
      AND status <> 'cancelled'
      AND created_at >= date_trunc('month', now());
    IF v_count >= v_max THEN
      RAISE EXCEPTION 'BOOKING_LIMIT_REACHED';
    END IF;
  END IF;

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

-- Durcissement (ré-affirmé) : backend service_role uniquement.
REVOKE EXECUTE ON FUNCTION public.create_service_booking(uuid, uuid, text, text, text, text, date, text, integer, text, numeric, boolean, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.create_service_booking(uuid, uuid, text, text, text, text, date, text, integer, text, numeric, boolean, text, text) TO service_role;

SELECT 'create_service_booking : plafond max_bookings_per_month désormais appliqué atomiquement (BOOKING_LIMIT_REACHED).' AS status;
