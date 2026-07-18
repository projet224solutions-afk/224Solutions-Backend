-- ============================================================
-- 🚚 SUIVI PUBLIC DE LIVRAISON — /track/{code}
-- Chaque livraison reçoit un code opaque partageable (CL + 8 chars, alphabet
-- sans ambiguïté 0/O/1/I/L). La page publique lit via UNE RPC SECURITY DEFINER
-- qui n'expose QUE des champs sûrs (jamais téléphone client ni montants) —
-- le code EST la capacité (espace 31^8, non énumérable).
-- ============================================================

-- 1) Colonne code de suivi
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS tracking_code text;
CREATE UNIQUE INDEX IF NOT EXISTS deliveries_tracking_code_key
  ON public.deliveries (tracking_code) WHERE tracking_code IS NOT NULL;

-- 2) Générateur (trigger BEFORE INSERT) — jamais exposé à PostgREST
CREATE OR REPLACE FUNCTION public.set_delivery_tracking_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_code text;
  v_tries int := 0;
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; -- 31 chars, sans 0/O/1/I/L
BEGIN
  IF NEW.tracking_code IS NOT NULL THEN RETURN NEW; END IF;
  LOOP
    SELECT 'CL' || string_agg(substr(v_alphabet, (get_byte(gen_random_bytes(1), 0) % 31) + 1, 1), '')
      INTO v_code FROM generate_series(1, 8);
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.deliveries WHERE tracking_code = v_code);
    v_tries := v_tries + 1;
    IF v_tries > 5 THEN
      v_code := 'CL' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
      EXIT;
    END IF;
  END LOOP;
  NEW.tracking_code := v_code;
  RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION public.set_delivery_tracking_code() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_set_delivery_tracking_code ON public.deliveries;
CREATE TRIGGER trg_set_delivery_tracking_code
  BEFORE INSERT ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.set_delivery_tracking_code();

-- 3) Backfill des livraisons existantes
DO $$
DECLARE r record; v_code text;
BEGIN
  FOR r IN SELECT id FROM public.deliveries WHERE tracking_code IS NULL LOOP
    SELECT 'CL' || string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', (get_byte(gen_random_bytes(1), 0) % 31) + 1, 1), '')
      INTO v_code FROM generate_series(1, 8);
    UPDATE public.deliveries SET tracking_code = v_code WHERE id = r.id AND tracking_code IS NULL;
  END LOOP;
END $$;

-- 4) Lecture publique — champs SÛRS uniquement (pas de téléphone, pas de montants)
CREATE OR REPLACE FUNCTION public.get_delivery_public_tracking(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  d record;
  v_pos_lat double precision;
  v_pos_lng double precision;
  v_pos_at timestamptz;
  dest jsonb;
BEGIN
  IF p_code IS NULL OR length(trim(p_code)) < 6 OR length(trim(p_code)) > 24 THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  SELECT id, status::text AS status, created_at, accepted_at, actual_pickup_time, started_at,
         completed_at, vendor_name, package_description, distance_km, delivery_address, tracking_code
    INTO d
    FROM public.deliveries
   WHERE tracking_code = upper(trim(p_code))
   LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('found', false); END IF;

  IF d.status IN ('assigned', 'picked_up', 'in_transit') THEN
    SELECT latitude, longitude, recorded_at INTO v_pos_lat, v_pos_lng, v_pos_at
      FROM public.delivery_tracking
     WHERE delivery_id = d.id
     ORDER BY recorded_at DESC
     LIMIT 1;
  END IF;

  dest := coalesce(d.delivery_address, '{}'::jsonb);
  RETURN jsonb_build_object(
    'found', true,
    'id', d.id,
    'code', d.tracking_code,
    'status', d.status,
    'vendor_name', d.vendor_name,
    'reference', d.package_description,
    'destination', jsonb_build_object(
      'address', coalesce(dest->>'address', dest->>'address_line'),
      'city', dest->>'city',
      'lat', dest->'lat',
      'lng', dest->'lng'
    ),
    'distance_km', d.distance_km,
    'created_at', d.created_at,
    'accepted_at', d.accepted_at,
    'picked_up_at', coalesce(d.actual_pickup_time, d.started_at),
    'completed_at', d.completed_at,
    'driver_position', CASE
      WHEN v_pos_lat IS NOT NULL
      THEN jsonb_build_object('lat', v_pos_lat, 'lng', v_pos_lng, 'at', v_pos_at)
      ELSE NULL
    END
  );
END $$;

REVOKE ALL ON FUNCTION public.get_delivery_public_tracking(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_delivery_public_tracking(text) TO anon, authenticated, service_role;
