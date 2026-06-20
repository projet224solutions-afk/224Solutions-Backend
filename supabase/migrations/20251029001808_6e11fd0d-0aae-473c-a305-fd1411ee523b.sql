-- 🔧 CORRECTION: Fonction generate_sequential_id (résoudre ambiguïté)
CREATE OR REPLACE FUNCTION generate_sequential_id(p_prefix VARCHAR(3))
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_current_value BIGINT;
  v_formatted_id TEXT;
  v_digit_count INTEGER;
BEGIN
  -- Vérifier le préfixe
  IF p_prefix IS NULL OR LENGTH(p_prefix) != 3 THEN
    RAISE EXCEPTION 'Le préfixe doit contenir exactement 3 caractères';
  END IF;

  -- Incrémenter ou créer le compteur (RÉSOLUTION DE L'AMBIGUÏTÉ)
  INSERT INTO public.id_counters (prefix, current_value, description)
    VALUES (p_prefix, 1, 'Auto-créé')
    ON CONFLICT (prefix) DO UPDATE 
    SET current_value = id_counters.current_value + 1
    RETURNING current_value INTO v_current_value;

  -- Déterminer le nombre de chiffres (minimum 4)
  v_digit_count := GREATEST(4, LENGTH(v_current_value::TEXT));

  -- Formater l'ID : AAA + chiffres avec zéros à gauche
  v_formatted_id := p_prefix || LPAD(v_current_value::TEXT, v_digit_count, '0');

  RETURN v_formatted_id;
END;
$$;

-- 🔄 REMPLACER TOUS LES IDs EXISTANTS PAR LE FORMAT STANDARDISÉ
DO $$
DECLARE
  v_profile RECORD;
  v_prefix VARCHAR(3);
  v_new_id TEXT;
  v_count INTEGER := 0;
BEGIN
  -- Réinitialiser tous les compteurs
  TRUNCATE TABLE public.id_counters RESTART IDENTITY;
  
  RAISE NOTICE '🔄 Remplacement de tous les IDs...';
  
  -- Parcourir TOUS les profils
  FOR v_profile IN 
    SELECT id, role, email 
    FROM public.profiles 
    ORDER BY created_at ASC
  LOOP
    -- Déterminer le préfixe
    v_prefix := CASE 
      WHEN v_profile.role = 'vendeur' THEN 'VND'
      WHEN v_profile.role = 'livreur' THEN 'DRV'
      WHEN v_profile.role = 'taxi' THEN 'DRV'
      WHEN v_profile.role = 'admin' THEN 'PDG'
      WHEN v_profile.role = 'syndicat' THEN 'SYD'
      WHEN v_profile.role = 'transitaire' THEN 'AGT'
      ELSE 'USR'
    END;

    -- Générer nouvel ID
    v_new_id := generate_sequential_id(v_prefix);

    -- REMPLACER
    UPDATE public.profiles
    SET public_id = v_new_id
    WHERE id = v_profile.id;

    v_count := v_count + 1;
  END LOOP;
  
  RAISE NOTICE '✅ % IDs remplacés avec succès!', v_count;
END;
$$;