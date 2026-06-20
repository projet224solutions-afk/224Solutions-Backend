-- =====================================================
-- AUDIT + REPAIR: INTÉGRITÉ DU SYSTÈME D'IDENTITÉ UTILISATEUR
-- Source de vérité: profiles.public_id
-- Cibles synchronisées:
--   - profiles.custom_id
--   - user_ids.custom_id
--   - vendors.vendor_code
-- =====================================================

CREATE OR REPLACE FUNCTION public.identity_role_prefix(p_role TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN CASE LOWER(COALESCE(p_role, 'client'))
    WHEN 'vendeur' THEN 'VND'
    WHEN 'vendor' THEN 'VND'
    WHEN 'agent' THEN 'AGT'
    WHEN 'pdg' THEN 'PDG'
    WHEN 'livreur' THEN 'LIV'
    WHEN 'taxi' THEN 'TAX'
    WHEN 'driver' THEN 'DRV'
    WHEN 'transitaire' THEN 'TRS'
    WHEN 'syndicat' THEN 'SYN'
    ELSE 'CLI'
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.audit_user_identity_integrity()
RETURNS TABLE (
  issue_key TEXT,
  affected_count BIGINT,
  sample JSONB
)
LANGUAGE sql
STABLE
AS $$
  WITH duplicate_user_ids_by_user AS (
    SELECT user_id, COUNT(*) AS duplicate_count
    FROM public.user_ids
    GROUP BY user_id
    HAVING COUNT(*) > 1
  ),
  duplicate_user_ids_by_custom AS (
    SELECT custom_id, COUNT(*) AS duplicate_count
    FROM public.user_ids
    GROUP BY custom_id
    HAVING COUNT(*) > 1
  ),
  duplicate_profiles_public_id AS (
    SELECT public_id, COUNT(*) AS duplicate_count
    FROM public.profiles
    WHERE public_id IS NOT NULL AND BTRIM(public_id) <> ''
    GROUP BY public_id
    HAVING COUNT(*) > 1
  ),
  profile_user_id_mismatch AS (
    SELECT p.id, p.public_id, ui.custom_id
    FROM public.profiles p
    JOIN public.user_ids ui ON ui.user_id = p.id
    WHERE p.public_id IS NOT NULL
      AND BTRIM(p.public_id) <> ''
      AND ui.custom_id IS DISTINCT FROM p.public_id
  ),
  profile_custom_id_mismatch AS (
    SELECT id, public_id, custom_id
    FROM public.profiles
    WHERE public_id IS NOT NULL
      AND BTRIM(public_id) <> ''
      AND custom_id IS DISTINCT FROM public_id
  ),
  profiles_missing_public_id AS (
    SELECT id, role
    FROM public.profiles
    WHERE public_id IS NULL OR BTRIM(public_id) = ''
  ),
  profiles_missing_user_ids AS (
    SELECT p.id, p.public_id
    FROM public.profiles p
    LEFT JOIN public.user_ids ui ON ui.user_id = p.id
    WHERE ui.user_id IS NULL
      AND p.public_id IS NOT NULL
      AND BTRIM(p.public_id) <> ''
  ),
  vendor_code_mismatch AS (
    SELECT v.id, v.user_id, v.vendor_code, p.public_id
    FROM public.vendors v
    JOIN public.profiles p ON p.id = v.user_id
    WHERE p.public_id IS NOT NULL
      AND BTRIM(p.public_id) <> ''
      AND v.vendor_code IS DISTINCT FROM p.public_id
  )
  SELECT 'duplicate_user_ids_by_user'::TEXT,
         (SELECT COUNT(*) FROM duplicate_user_ids_by_user),
         COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (SELECT * FROM duplicate_user_ids_by_user LIMIT 5) t), '[]'::jsonb)
  UNION ALL
  SELECT 'duplicate_user_ids_by_custom_id',
         (SELECT COUNT(*) FROM duplicate_user_ids_by_custom),
         COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (SELECT * FROM duplicate_user_ids_by_custom LIMIT 5) t), '[]'::jsonb)
  UNION ALL
  SELECT 'duplicate_profiles_public_id',
         (SELECT COUNT(*) FROM duplicate_profiles_public_id),
         COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (SELECT * FROM duplicate_profiles_public_id LIMIT 5) t), '[]'::jsonb)
  UNION ALL
  SELECT 'profile_public_id_vs_user_ids_custom_id_mismatch',
         (SELECT COUNT(*) FROM profile_user_id_mismatch),
         COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (SELECT * FROM profile_user_id_mismatch LIMIT 5) t), '[]'::jsonb)
  UNION ALL
  SELECT 'profile_public_id_vs_profile_custom_id_mismatch',
         (SELECT COUNT(*) FROM profile_custom_id_mismatch),
         COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (SELECT * FROM profile_custom_id_mismatch LIMIT 5) t), '[]'::jsonb)
  UNION ALL
  SELECT 'profiles_missing_public_id',
         (SELECT COUNT(*) FROM profiles_missing_public_id),
         COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (SELECT * FROM profiles_missing_public_id LIMIT 5) t), '[]'::jsonb)
  UNION ALL
  SELECT 'profiles_missing_user_ids',
         (SELECT COUNT(*) FROM profiles_missing_user_ids),
         COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (SELECT * FROM profiles_missing_user_ids LIMIT 5) t), '[]'::jsonb)
  UNION ALL
  SELECT 'vendors_vendor_code_mismatch',
         (SELECT COUNT(*) FROM vendor_code_mismatch),
         COALESCE((SELECT jsonb_agg(to_jsonb(t)) FROM (SELECT * FROM vendor_code_mismatch LIMIT 5) t), '[]'::jsonb);
$$;

CREATE OR REPLACE FUNCTION public.repair_user_identity_integrity()
RETURNS TABLE (
  step_key TEXT,
  affected_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count BIGINT;
  v_new_id TEXT;
  v_profile RECORD;
BEGIN
  -- Normaliser le format des IDs publics existants.
  UPDATE public.profiles
  SET public_id = UPPER(BTRIM(public_id))
  WHERE public_id IS NOT NULL
    AND public_id <> UPPER(BTRIM(public_id));
  GET DIAGNOSTICS v_count = ROW_COUNT;
  step_key := 'normalize_profiles_public_id';
  affected_count := v_count;
  RETURN NEXT;

  UPDATE public.profiles
  SET custom_id = UPPER(BTRIM(custom_id))
  WHERE custom_id IS NOT NULL
    AND custom_id <> UPPER(BTRIM(custom_id));
  GET DIAGNOSTICS v_count = ROW_COUNT;
  step_key := 'normalize_profiles_custom_id';
  affected_count := v_count;
  RETURN NEXT;

  UPDATE public.user_ids
  SET custom_id = UPPER(BTRIM(custom_id))
  WHERE custom_id <> UPPER(BTRIM(custom_id));
  GET DIAGNOSTICS v_count = ROW_COUNT;
  step_key := 'normalize_user_ids_custom_id';
  affected_count := v_count;
  RETURN NEXT;

  UPDATE public.vendors
  SET vendor_code = UPPER(BTRIM(vendor_code))
  WHERE vendor_code IS NOT NULL
    AND vendor_code <> UPPER(BTRIM(vendor_code));
  GET DIAGNOSTICS v_count = ROW_COUNT;
  step_key := 'normalize_vendor_code';
  affected_count := v_count;
  RETURN NEXT;

  -- Si public_id manque mais user_ids existe déjà, recopier vers profiles.
  UPDATE public.profiles p
  SET public_id = ui.custom_id
  FROM public.user_ids ui
  WHERE ui.user_id = p.id
    AND (p.public_id IS NULL OR BTRIM(p.public_id) = '');
  GET DIAGNOSTICS v_count = ROW_COUNT;
  step_key := 'backfill_profiles_public_id_from_user_ids';
  affected_count := v_count;
  RETURN NEXT;

  -- Générer les IDs manquants pour les profils sans identifiant public.
  v_count := 0;
  FOR v_profile IN
    SELECT p.id, p.role
    FROM public.profiles p
    WHERE p.public_id IS NULL OR BTRIM(p.public_id) = ''
    ORDER BY p.created_at, p.id
  LOOP
    v_new_id := public.generate_sequential_id(public.identity_role_prefix(v_profile.role::TEXT));

    UPDATE public.profiles
    SET public_id = v_new_id,
        custom_id = v_new_id
    WHERE id = v_profile.id;

    INSERT INTO public.user_ids (user_id, custom_id, created_at)
    VALUES (v_profile.id, v_new_id, NOW())
    ON CONFLICT (user_id) DO UPDATE SET custom_id = EXCLUDED.custom_id;

    v_count := v_count + 1;
  END LOOP;
  step_key := 'generate_missing_public_ids';
  affected_count := v_count;
  RETURN NEXT;

  -- Si des doublons existent déjà sur profiles.public_id, régénérer une valeur unique
  -- pour toutes les occurrences au-delà de la première avant de resynchroniser user_ids.
  v_count := 0;
  FOR v_profile IN
    WITH ranked_duplicates AS (
      SELECT p.id,
             p.role,
             ROW_NUMBER() OVER (
               PARTITION BY p.public_id
               ORDER BY p.created_at NULLS LAST, p.id
             ) AS duplicate_rank
      FROM public.profiles p
      WHERE p.public_id IS NOT NULL
        AND BTRIM(p.public_id) <> ''
    )
    SELECT id, role
    FROM ranked_duplicates
    WHERE duplicate_rank > 1
  LOOP
    v_new_id := public.generate_sequential_id(public.identity_role_prefix(v_profile.role::TEXT));

    UPDATE public.profiles
    SET public_id = v_new_id,
        custom_id = v_new_id
    WHERE id = v_profile.id;

    v_count := v_count + 1;
  END LOOP;
  step_key := 'resolve_duplicate_profiles_public_id';
  affected_count := v_count;
  RETURN NEXT;

  -- Préparer les lignes user_ids désynchronisées avec des IDs temporaires pour éviter les collisions uniques.
  WITH mismatched AS (
    SELECT ui.id,
           UPPER(SUBSTRING(MD5(ui.id::TEXT) FROM 1 FOR 6)) AS temp_suffix
    FROM public.user_ids ui
    JOIN public.profiles p ON p.id = ui.user_id
    WHERE p.public_id IS NOT NULL
      AND BTRIM(p.public_id) <> ''
      AND ui.custom_id IS DISTINCT FROM p.public_id
  )
  UPDATE public.user_ids ui
  SET custom_id = 'T' || m.temp_suffix
  FROM mismatched m
  WHERE ui.id = m.id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  step_key := 'stage_mismatched_user_ids';
  affected_count := v_count;
  RETURN NEXT;

  -- Appliquer la vraie valeur de référence depuis profiles.public_id.
  UPDATE public.user_ids ui
  SET custom_id = p.public_id
  FROM public.profiles p
  WHERE ui.user_id = p.id
    AND p.public_id IS NOT NULL
    AND BTRIM(p.public_id) <> ''
    AND ui.custom_id IS DISTINCT FROM p.public_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  step_key := 'sync_user_ids_from_profiles_public_id';
  affected_count := v_count;
  RETURN NEXT;

  -- Assurer qu'aucun profil avec public_id ne manque dans user_ids.
  INSERT INTO public.user_ids (user_id, custom_id, created_at)
  SELECT p.id, p.public_id, NOW()
  FROM public.profiles p
  LEFT JOIN public.user_ids ui ON ui.user_id = p.id
  WHERE ui.user_id IS NULL
    AND p.public_id IS NOT NULL
    AND BTRIM(p.public_id) <> ''
  ON CONFLICT (user_id) DO UPDATE SET custom_id = EXCLUDED.custom_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  step_key := 'insert_missing_user_ids';
  affected_count := v_count;
  RETURN NEXT;

  -- Garder profiles.custom_id aligné pour les composants legacy.
  UPDATE public.profiles
  SET custom_id = public_id
  WHERE public_id IS NOT NULL
    AND BTRIM(public_id) <> ''
    AND custom_id IS DISTINCT FROM public_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  step_key := 'sync_profiles_custom_id_from_public_id';
  affected_count := v_count;
  RETURN NEXT;

  -- Synchroniser les codes vendeurs sur l'ID public de l'utilisateur.
  UPDATE public.vendors v
  SET vendor_code = p.public_id
  FROM public.profiles p
  WHERE p.id = v.user_id
    AND p.public_id IS NOT NULL
    AND BTRIM(p.public_id) <> ''
    AND v.vendor_code IS DISTINCT FROM p.public_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  step_key := 'sync_vendor_code_from_profiles_public_id';
  affected_count := v_count;
  RETURN NEXT;
END;
$$;

DO $$
DECLARE
  audit_row RECORD;
  repair_row RECORD;
BEGIN
  RAISE NOTICE '=== AUDIT IDENTITÉ AVANT RÉPARATION ===';
  FOR audit_row IN SELECT * FROM public.audit_user_identity_integrity() LOOP
    RAISE NOTICE '% => %', audit_row.issue_key, audit_row.affected_count;
  END LOOP;

  RAISE NOTICE '=== RÉPARATION IDENTITÉ ===';
  FOR repair_row IN SELECT * FROM public.repair_user_identity_integrity() LOOP
    RAISE NOTICE '% => %', repair_row.step_key, repair_row.affected_count;
  END LOOP;

  RAISE NOTICE '=== AUDIT IDENTITÉ APRÈS RÉPARATION ===';
  FOR audit_row IN SELECT * FROM public.audit_user_identity_integrity() LOOP
    RAISE NOTICE '% => %', audit_row.issue_key, audit_row.affected_count;
  END LOOP;
END $$;

COMMENT ON FUNCTION public.identity_role_prefix(TEXT) IS 'Retourne le préfixe d''ID séquentiel à utiliser selon le rôle utilisateur.';
COMMENT ON FUNCTION public.audit_user_identity_integrity() IS 'Audit des divergences d''identité entre profiles.public_id, profiles.custom_id, user_ids.custom_id et vendors.vendor_code.';
COMMENT ON FUNCTION public.repair_user_identity_integrity() IS 'Répare de manière idempotente les divergences d''identité et complète les IDs publics manquants.';