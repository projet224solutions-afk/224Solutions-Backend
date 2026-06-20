-- 🔧 CORRECTION: Fonction generate_sequential_id avec ambiguïté résolue
CREATE OR REPLACE FUNCTION public.generate_sequential_id(p_prefix VARCHAR)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_current_value BIGINT;
  v_formatted_id TEXT;
BEGIN
  -- Insérer ou mettre à jour le compteur de manière atomique
  INSERT INTO public.id_counters (prefix, current_value, description)
    VALUES (p_prefix, 1, 'Auto-créé')
    ON CONFLICT (prefix) 
    DO UPDATE SET current_value = id_counters.current_value + 1
    RETURNING current_value INTO v_current_value;

  -- Formater l'ID avec au minimum 4 chiffres
  v_formatted_id := p_prefix || LPAD(v_current_value::TEXT, 4, '0');

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
  
  RAISE NOTICE '🔄 Remplacement de tous les IDs existants...';
  
  -- Parcourir TOUS les profils par ordre chronologique
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

    -- Générer le nouveau ID
    v_new_id := generate_sequential_id(v_prefix);

    -- Remplacer l'ID
    UPDATE public.profiles
    SET public_id = v_new_id
    WHERE id = v_profile.id;

    v_count := v_count + 1;
  END LOOP;
  
  RAISE NOTICE '✅ % IDs remplacés avec succès!', v_count;
END;
$$;