-- =====================================================
-- ALIGN ID PREFIX HELPERS WITH CURRENT APP STANDARD
-- - client => CLT (not CLI)
-- - bureau/syndicat => BST
-- This makes the "Tout réorganiser" action generate the same
-- prefixes as the frontend and Edge Functions.
-- =====================================================

CREATE OR REPLACE FUNCTION public.identity_role_prefix(p_role TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN CASE LOWER(BTRIM(COALESCE(p_role, 'client')))
    WHEN 'vendeur' THEN 'VND'
    WHEN 'vendor' THEN 'VND'
    WHEN 'agent' THEN 'AGT'
    WHEN 'pdg' THEN 'PDG'
    WHEN 'livreur' THEN 'LIV'
    WHEN 'taxi' THEN 'TAX'
    WHEN 'driver' THEN 'DRV'
    WHEN 'chauffeur' THEN 'DRV'
    WHEN 'transitaire' THEN 'TRS'
    WHEN 'bureau' THEN 'BST'
    WHEN 'syndicat' THEN 'BST'
    WHEN 'worker' THEN 'WRK'
    ELSE 'CLT'
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.identity_role_to_prefix(p_role TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN CASE LOWER(BTRIM(COALESCE(p_role, '')))
    WHEN 'vendeur' THEN 'VND'
    WHEN 'vendor' THEN 'VND'
    WHEN 'client' THEN 'CLT'
    WHEN 'agent' THEN 'AGT'
    WHEN 'pdg' THEN 'PDG'
    WHEN 'livreur' THEN 'LIV'
    WHEN 'taxi' THEN 'TAX'
    WHEN 'driver' THEN 'DRV'
    WHEN 'chauffeur' THEN 'DRV'
    WHEN 'transitaire' THEN 'TRS'
    WHEN 'bureau' THEN 'BST'
    WHEN 'syndicat' THEN 'BST'
    WHEN 'worker' THEN 'WRK'
    ELSE NULL
  END;
END;
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'id_sequences'
  ) THEN
    INSERT INTO public.id_sequences (prefix, last_number, updated_at)
    VALUES
      (
        'CLT',
        GREATEST(
          COALESCE((SELECT last_number FROM public.id_sequences WHERE prefix = 'CLT'), 0),
          COALESCE((SELECT last_number FROM public.id_sequences WHERE prefix = 'CLI'), 0)
        ),
        NOW()
      ),
      (
        'BST',
        GREATEST(
          COALESCE((SELECT last_number FROM public.id_sequences WHERE prefix = 'BST'), 0),
          COALESCE((SELECT last_number FROM public.id_sequences WHERE prefix = 'SYN'), 0)
        ),
        NOW()
      )
    ON CONFLICT (prefix)
    DO UPDATE SET
      last_number = GREATEST(public.id_sequences.last_number, EXCLUDED.last_number),
      updated_at = NOW();

    DELETE FROM public.id_sequences
    WHERE prefix IN ('CLI', 'SYN');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'repair_user_identity_integrity'
  ) THEN
    PERFORM public.repair_user_identity_integrity();
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'reorganize_user_ids_from_db'
  ) THEN
    BEGIN
      PERFORM 1
      FROM public.reorganize_user_ids_from_db(NULL);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'Réorganisation différée pendant la migration d''alignement: %', SQLERRM;
    END;
  END IF;
END;
$$;

COMMENT ON FUNCTION public.identity_role_prefix(TEXT) IS 'Retourne le préfixe d''ID séquentiel à utiliser selon le rôle utilisateur (standard courant: CLT/BST).';
COMMENT ON FUNCTION public.identity_role_to_prefix(TEXT) IS 'Mappe un rôle utilisateur vers le préfixe d''ID standard courant pour la réorganisation.';
