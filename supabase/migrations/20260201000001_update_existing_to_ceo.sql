-- =======================================================================
-- METTRE À JOUR UN COMPTE EXISTANT VERS CEO
-- =======================================================================
-- Utilisez ce script si vous avez déjà un compte et voulez le promouvoir en CEO
-- =======================================================================

-- ⚠️ REMPLACER 'votre-email@example.com' PAR VOTRE EMAIL ACTUEL

DO $$
DECLARE
  v_email TEXT := 'projet224solutions@gmail.com'; -- ⚠️ REMPLACER ICI
  v_user_id UUID;
  v_custom_id TEXT;
BEGIN
  -- Trouver l'utilisateur par email
  SELECT id INTO v_user_id
  FROM profiles
  WHERE email = v_email;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Aucun utilisateur trouvé avec l''email: %', v_email;
  END IF;

  -- Mettre à jour le rôle vers CEO
  UPDATE profiles
  SET role = 'ceo',
      is_active = true,
      updated_at = NOW()
  WHERE id = v_user_id;

  RAISE NOTICE '✅ Rôle mis à jour vers CEO pour: %', v_email;

  -- Mettre à jour l'ID personnalisé
  BEGIN
    SELECT generate_custom_id_with_role('ceo') INTO v_custom_id;

    UPDATE user_ids
    SET custom_id = v_custom_id,
        updated_at = NOW()
    WHERE user_id = v_user_id;

    RAISE NOTICE '✅ ID mis à jour vers: %', v_custom_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '⚠️ Impossible de mettre à jour l''ID personnalisé';
  END;

  -- Augmenter les limites de la carte virtuelle
  UPDATE virtual_cards
  SET daily_limit = 10000000,    -- 10M GNF
      monthly_limit = 50000000,  -- 50M GNF
      updated_at = NOW()
  WHERE user_id = v_user_id;

  RAISE NOTICE '✅ Limites carte virtuelle augmentées';

  -- Ajouter à la table PDG si elle existe
  BEGIN
    INSERT INTO pdg (id, name, email, phone, created_at, updated_at)
    SELECT
      v_user_id,
      COALESCE(first_name || ' ' || last_name, 'PDG'),
      email,
      COALESCE(phone, '+224 000 00 00 00'),
      NOW(),
      NOW()
    FROM profiles
    WHERE id = v_user_id
    ON CONFLICT (id) DO UPDATE
    SET email = EXCLUDED.email,
        updated_at = NOW();

    RAISE NOTICE '✅ Ajouté à la table PDG';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '⚠️ Table PDG non disponible';
  END;

  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE '✅ COMPTE PROMU EN CEO !';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE 'Email: %', v_email;
  RAISE NOTICE 'Nouveau rôle: CEO';
  RAISE NOTICE '';
  RAISE NOTICE '🔓 Reconnectez-vous pour activer les nouveaux privilèges';
  RAISE NOTICE '═══════════════════════════════════════════════';
END $$;
