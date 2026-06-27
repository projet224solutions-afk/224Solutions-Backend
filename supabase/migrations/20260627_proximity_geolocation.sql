BEGIN;

-- ════════════════════════════════════════════════════════════
-- 1. Colonnes de géolocalisation pour professional_services
--    NB : latitude/longitude/city existent déjà en base ; seul location_accuracy
--    manque. ADD COLUMN IF NOT EXISTS rend l'ensemble idempotent.
-- ════════════════════════════════════════════════════════════
ALTER TABLE public.professional_services
  ADD COLUMN IF NOT EXISTS latitude   DECIMAL(10, 8),
  ADD COLUMN IF NOT EXISTS longitude  DECIMAL(11, 8),
  ADD COLUMN IF NOT EXISTS city       VARCHAR(100),
  ADD COLUMN IF NOT EXISTS location_accuracy DECIMAL(10, 2); -- précision GPS en mètres

-- Index pour les requêtes de proximité (filtrage par bounding box)
CREATE INDEX IF NOT EXISTS idx_prof_services_geo
  ON public.professional_services (latitude, longitude)
  WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

-- Index sur le statut actif (les requêtes proximité filtrent status='active')
CREATE INDEX IF NOT EXISTS idx_prof_services_active_geo
  ON public.professional_services (status, latitude, longitude)
  WHERE status = 'active';

-- ════════════════════════════════════════════════════════════
-- 2. RPC ATOMIQUE — création prestataire de proximité tout-ou-rien
-- ════════════════════════════════════════════════════════════
-- Crée/MAJ la ligne professional_services de façon atomique avec géolocalisation.
-- Idempotent : si un service existe déjà pour ce user, le met à jour (complète la géoloc).
CREATE OR REPLACE FUNCTION public.create_proximity_service(
  p_user_id           UUID,
  p_service_type_code TEXT,
  p_business_name     TEXT,
  p_phone             TEXT,
  p_email             TEXT,
  p_city              TEXT DEFAULT NULL,
  p_address           TEXT DEFAULT NULL,
  p_latitude          DECIMAL DEFAULT NULL,
  p_longitude         DECIMAL DEFAULT NULL,
  p_accuracy          DECIMAL DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_service_type_id UUID;
  v_existing_id     UUID;
  v_service_id      UUID;
BEGIN
  -- 1. Résoudre le service_type_id depuis le code
  SELECT id INTO v_service_type_id
  FROM public.service_types
  WHERE code = p_service_type_code
  LIMIT 1;

  IF v_service_type_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'service_type_introuvable', 'code', p_service_type_code);
  END IF;

  -- 2. Idempotence : service déjà existant pour ce user ?
  SELECT id INTO v_existing_id
  FROM public.professional_services
  WHERE user_id = p_user_id
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    UPDATE public.professional_services SET
      business_name     = COALESCE(NULLIF(p_business_name, ''), business_name),
      phone             = COALESCE(NULLIF(p_phone, ''), phone),
      email             = COALESCE(NULLIF(p_email, ''), email),
      city              = COALESCE(NULLIF(p_city, ''), city),
      address           = COALESCE(NULLIF(p_address, ''), address),
      latitude          = COALESCE(p_latitude, latitude),
      longitude         = COALESCE(p_longitude, longitude),
      location_accuracy = COALESCE(p_accuracy, location_accuracy),
      updated_at        = now()
    WHERE id = v_existing_id;

    RETURN jsonb_build_object('success', true, 'service_id', v_existing_id, 'updated', true);
  END IF;

  -- 3. Création atomique
  INSERT INTO public.professional_services (
    user_id, service_type_id, business_name, phone, email,
    city, address, latitude, longitude, location_accuracy,
    status, verification_status
  ) VALUES (
    p_user_id, v_service_type_id, p_business_name, p_phone, p_email,
    p_city, p_address, p_latitude, p_longitude, p_accuracy,
    'active', 'unverified'
  )
  RETURNING id INTO v_service_id;

  RETURN jsonb_build_object('success', true, 'service_id', v_service_id, 'created', true);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END; $$;

GRANT EXECUTE ON FUNCTION public.create_proximity_service(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, DECIMAL, DECIMAL, DECIMAL
) TO authenticated, service_role;

-- ════════════════════════════════════════════════════════════
-- 3. Garde-fou
-- ════════════════════════════════════════════════════════════
DO $$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_name='professional_services' AND column_name='location_accuracy'
  ) THEN RAISE EXCEPTION 'Colonne location_accuracy absente'; END IF;

  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='create_proximity_service')
  THEN RAISE EXCEPTION 'RPC create_proximity_service absente'; END IF;

  RAISE NOTICE '✅ Migration proximity_geolocation OK';
END; $$;

COMMIT;
