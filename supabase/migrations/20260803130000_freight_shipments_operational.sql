-- ═══════════════════════════════════════════════════════════════════════════════
-- TRANSITAIRE OPÉRATIONNEL — expédition de fret AUTONOME (créer / suivre / escrow)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Avant : international_shipments.order_id NOT NULL (liée à une commande marketplace) → pas
-- d'expédition de fret autonome depuis le calculateur. On rend order_id NULLABLE + on ajoute
-- les champs pro. AUCUN nouveau chemin d'argent : le paiement réutilise le circuit escrow
-- EXISTANT (service_quotes + pay_quote_atomic / release_quote_atomic) via un quote lié.

ALTER TABLE public.international_shipments
  ALTER COLUMN order_id DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS reference           text,
  ADD COLUMN IF NOT EXISTS mode                text,          -- 'air' | 'sea'
  ADD COLUMN IF NOT EXISTS origin_city         text,
  ADD COLUMN IF NOT EXISTS destination_city    text,
  ADD COLUMN IF NOT EXISTS sender_name         text,
  ADD COLUMN IF NOT EXISTS sender_phone        text,
  ADD COLUMN IF NOT EXISTS receiver_name       text,
  ADD COLUMN IF NOT EXISTS receiver_phone      text,
  ADD COLUMN IF NOT EXISTS package_description text,
  ADD COLUMN IF NOT EXISTS pieces_count        integer,
  ADD COLUMN IF NOT EXISTS declared_value      numeric,
  ADD COLUMN IF NOT EXISTS incoterm            text,
  ADD COLUMN IF NOT EXISTS client_user_id      uuid,
  ADD COLUMN IF NOT EXISTS status              text NOT NULL DEFAULT 'booked',
  ADD COLUMN IF NOT EXISTS quote_id            uuid;

-- États autorisés (machine à états). delayed/issue = signalables à tout moment.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'international_shipments_status_chk') THEN
    ALTER TABLE public.international_shipments
      ADD CONSTRAINT international_shipments_status_chk
      CHECK (status IN ('booked','collected','in_transit','customs','cleared','delivered','delayed','issue'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_intl_shipments_reference ON public.international_shipments(reference) WHERE reference IS NOT NULL;
CREATE SEQUENCE IF NOT EXISTS public.freight_ref_seq;

-- Table de SUIVI dédiée au fret international (⚠️ shipment_tracking est lié à `shipments` domestique).
CREATE TABLE IF NOT EXISTS public.intl_shipment_events (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_id  uuid NOT NULL REFERENCES public.international_shipments(id) ON DELETE CASCADE,
  status       text NOT NULL,
  title        text,
  description  text,
  location     text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_intl_events_shipment ON public.intl_shipment_events(shipment_id, created_at);
ALTER TABLE public.intl_shipment_events ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='intl_shipment_events' AND policyname='intl_events_party_read') THEN
    CREATE POLICY intl_events_party_read ON public.intl_shipment_events FOR SELECT USING (
      EXISTS (SELECT 1 FROM public.international_shipments s WHERE s.id = shipment_id
              AND (s.transitaire_id = auth.uid() OR s.client_user_id = auth.uid() OR public.is_admin_or_pdg(auth.uid()))));
  END IF;
END $$;
GRANT SELECT ON public.intl_shipment_events TO authenticated, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) CRÉER une expédition depuis le calculateur — PRIX SERVEUR (recalculé, jamais le client).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_freight_shipment(
  p_mode text, p_origin_country text, p_destination_country text,
  p_weight_kg numeric, p_length_cm numeric DEFAULT 0, p_width_cm numeric DEFAULT 0, p_height_cm numeric DEFAULT 0,
  p_pieces integer DEFAULT 1,
  p_origin_city text DEFAULT NULL, p_destination_city text DEFAULT NULL,
  p_sender_name text DEFAULT NULL, p_sender_phone text DEFAULT NULL,
  p_receiver_name text DEFAULT NULL, p_receiver_phone text DEFAULT NULL,
  p_package_description text DEFAULT NULL, p_declared_value numeric DEFAULT NULL,
  p_incoterm text DEFAULT NULL, p_client_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_transitaire uuid := auth.uid();
  v_quote jsonb; v_price numeric; v_ref text; v_id uuid;
BEGIN
  IF v_transitaire IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED'); END IF;

  -- PRIX SERVEUR : recalcul via calculate_freight_quote (aucun prix client).
  v_quote := public.calculate_freight_quote(v_transitaire, p_mode, p_origin_country, p_destination_country,
                                            p_weight_kg, p_length_cm, p_width_cm, p_height_cm, p_pieces);
  IF NOT COALESCE((v_quote->>'success')::boolean, false) THEN
    RETURN jsonb_build_object('success', false, 'error', COALESCE(v_quote->>'error','QUOTE_FAILED'));
  END IF;
  v_price := (v_quote->>'price')::numeric;

  v_ref := 'EXP-' || to_char(now(),'YYYY') || '-' || lpad(nextval('public.freight_ref_seq')::text, 6, '0');

  INSERT INTO public.international_shipments(
    transitaire_id, tracking_number, reference, order_id, mode,
    origin_country, destination_country, origin_city, destination_city,
    sender_name, sender_phone, receiver_name, receiver_phone,
    package_description, pieces_count, declared_value, incoterm,
    total_weight_kg, shipping_cost, client_user_id, status, customs_status)
  VALUES (
    v_transitaire, v_ref, v_ref, NULL, p_mode,
    p_origin_country, p_destination_country, p_origin_city, p_destination_city,
    p_sender_name, p_sender_phone, p_receiver_name, p_receiver_phone,
    p_package_description, GREATEST(COALESCE(p_pieces,1),1), p_declared_value, p_incoterm,
    p_weight_kg, v_price, p_client_user_id, 'booked', 'pending')
  RETURNING id INTO v_id;

  -- Première étape de suivi.
  INSERT INTO public.intl_shipment_events(shipment_id, status, title, description)
  VALUES (v_id, 'booked', 'Expédition créée', 'Réservation enregistrée — ' || v_ref);

  -- Notifier le client (best-effort).
  IF p_client_user_id IS NOT NULL THEN
    BEGIN
      INSERT INTO public.notifications(user_id, title, message, type, metadata)
      VALUES (p_client_user_id, 'Expédition créée', 'Votre expédition ' || v_ref || ' est enregistrée.',
              'freight_shipment', jsonb_build_object('shipment_id', v_id, 'reference', v_ref));
    EXCEPTION WHEN others THEN NULL; END;
  END IF;

  RETURN jsonb_build_object('success', true, 'shipment_id', v_id, 'reference', v_ref, 'shipping_cost', v_price);
END;
$function$;

REVOKE ALL ON FUNCTION public.create_freight_shipment(text,text,text,numeric,numeric,numeric,numeric,integer,text,text,text,text,text,text,text,numeric,text,uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.create_freight_shipment(text,text,text,numeric,numeric,numeric,numeric,integer,text,text,text,text,text,text,text,numeric,text,uuid) TO authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) FAIRE AVANCER le statut — seul le transitaire propriétaire ; horodaté dans tracking + notif.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.advance_shipment_status(
  p_shipment_id uuid, p_status text, p_location text DEFAULT NULL, p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE s public.international_shipments%ROWTYPE; v_label text;
BEGIN
  SELECT * INTO s FROM public.international_shipments WHERE id = p_shipment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SHIPMENT_NOT_FOUND'; END IF;
  IF s.transitaire_id <> auth.uid() AND NOT public.is_admin_or_pdg(auth.uid()) THEN RAISE EXCEPTION 'NOT_TRANSITAIRE'; END IF;
  IF p_status NOT IN ('booked','collected','in_transit','customs','cleared','delivered','delayed','issue') THEN
    RAISE EXCEPTION 'BAD_STATUS';
  END IF;

  v_label := CASE p_status
    WHEN 'collected'  THEN 'Colis collecté'
    WHEN 'in_transit' THEN 'En transit'
    WHEN 'customs'    THEN 'En douane'
    WHEN 'cleared'    THEN 'Dédouané'
    WHEN 'delivered'  THEN 'Livré'
    WHEN 'delayed'    THEN 'Retardé'
    WHEN 'issue'      THEN 'Problème signalé'
    ELSE 'Réservé' END;

  UPDATE public.international_shipments
    SET status = p_status,
        customs_status = CASE WHEN p_status IN ('customs') THEN 'in_review'
                              WHEN p_status IN ('cleared','delivered') THEN 'cleared'
                              ELSE customs_status END,
        actual_delivery_date = CASE WHEN p_status = 'delivered' THEN CURRENT_DATE ELSE actual_delivery_date END,
        updated_at = now()
    WHERE id = p_shipment_id;

  INSERT INTO public.intl_shipment_events(shipment_id, status, title, description, location)
  VALUES (p_shipment_id, p_status, v_label, p_note, p_location);

  IF s.client_user_id IS NOT NULL THEN
    BEGIN
      INSERT INTO public.notifications(user_id, title, message, type, metadata)
      VALUES (s.client_user_id, 'Suivi expédition ' || COALESCE(s.reference,''), v_label,
              'freight_shipment', jsonb_build_object('shipment_id', p_shipment_id, 'status', p_status));
    EXCEPTION WHEN others THEN NULL; END;
  END IF;

  RETURN jsonb_build_object('success', true, 'status', p_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.advance_shipment_status(uuid,text,text,text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.advance_shipment_status(uuid,text,text,text) TO authenticated, service_role;
