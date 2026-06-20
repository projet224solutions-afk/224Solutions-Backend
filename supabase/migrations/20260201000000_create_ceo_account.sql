-- =======================================================================
-- CRÉATION COMPTE CEO POUR 224SOLUTIONS
-- =======================================================================
-- Ce script crée un compte CEO avec tous les accès nécessaires
-- =======================================================================

-- INSTRUCTIONS:
-- 1. Créer d'abord l'utilisateur dans Supabase Auth Dashboard:
--    - Email: ceo@224solutions.com (ou votre email)
--    - Password: (choisissez un mot de passe sécurisé)
--    - Copiez l'UUID généré
--
-- 2. Remplacez 'VOTRE-USER-ID-ICI' ci-dessous par l'UUID copié
--
-- 3. Exécutez ce script dans l'éditeur SQL Supabase

DO $$
DECLARE
  v_user_id UUID := 'VOTRE-USER-ID-ICI'; -- ⚠️ REMPLACER PAR L'UUID DE L'UTILISATEUR
  v_email TEXT := 'ceo@224solutions.com'; -- ⚠️ REMPLACER PAR VOTRE EMAIL
  v_first_name TEXT := 'PDG';
  v_last_name TEXT := '224Solutions';
  v_custom_id TEXT;
BEGIN
  -- Vérifier si le profil existe déjà
  IF EXISTS (SELECT 1 FROM profiles WHERE id = v_user_id) THEN
    RAISE NOTICE 'Profil existe déjà, mise à jour du rôle...';

    -- Mettre à jour le rôle existant
    UPDATE profiles
    SET role = 'ceo',
        is_active = true,
        updated_at = NOW()
    WHERE id = v_user_id;

    RAISE NOTICE '✅ Rôle mis à jour vers CEO';
  ELSE
    -- Créer le profil CEO
    INSERT INTO profiles (
      id,
      email,
      first_name,
      last_name,
      role,
      is_active,
      created_at,
      updated_at
    ) VALUES (
      v_user_id,
      v_email,
      v_first_name,
      v_last_name,
      'ceo',
      true,
      NOW(),
      NOW()
    );

    RAISE NOTICE '✅ Profil CEO créé';
  END IF;

  -- Générer un ID personnalisé pour le CEO
  BEGIN
    SELECT generate_custom_id_with_role('ceo') INTO v_custom_id;

    -- Créer/mettre à jour l'ID utilisateur
    INSERT INTO user_ids (user_id, custom_id, created_at)
    VALUES (v_user_id, v_custom_id, NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET custom_id = v_custom_id;

    RAISE NOTICE '✅ ID personnalisé créé: %', v_custom_id;
  EXCEPTION WHEN OTHERS THEN
    -- Si la fonction n'existe pas, créer un ID manuel
    v_custom_id := 'CEO0001';
    INSERT INTO user_ids (user_id, custom_id, created_at)
    VALUES (v_user_id, v_custom_id, NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET custom_id = v_custom_id;

    RAISE NOTICE '⚠️ ID personnalisé créé manuellement: %', v_custom_id;
  END;

  -- Initialiser le wallet
  BEGIN
    PERFORM initialize_user_wallet(v_user_id);
    RAISE NOTICE '✅ Wallet initialisé';
  EXCEPTION WHEN OTHERS THEN
    -- Créer wallet manuellement si la fonction n'existe pas
    INSERT INTO wallets (user_id, balance, currency, created_at, updated_at)
    VALUES (v_user_id, 0, 'GNF', NOW(), NOW())
    ON CONFLICT (user_id) DO NOTHING;
    RAISE NOTICE '⚠️ Wallet créé manuellement';
  END;

  -- Créer carte virtuelle
  INSERT INTO virtual_cards (
    user_id,
    card_number,
    holder_name,
    expiry_date,
    cvv,
    daily_limit,
    monthly_limit,
    is_active,
    created_at
  ) VALUES (
    v_user_id,
    '4*** **** **** ' || LPAD((FLOOR(RANDOM() * 9999))::TEXT, 4, '0'),
    v_first_name || ' ' || v_last_name,
    TO_CHAR(NOW() + INTERVAL '3 years', 'MM/YY'),
    LPAD((FLOOR(RANDOM() * 900 + 100))::TEXT, 3, '0'),
    10000000, -- 10M GNF par jour
    50000000, -- 50M GNF par mois
    true,
    NOW()
  )
  ON CONFLICT (user_id) DO NOTHING;

  RAISE NOTICE '✅ Carte virtuelle créée';

  -- Créer entrée dans la table PDG si elle existe
  BEGIN
    INSERT INTO pdg (id, name, email, phone, created_at, updated_at)
    VALUES (
      v_user_id,
      v_first_name || ' ' || v_last_name,
      v_email,
      '+224 000 00 00 00', -- ⚠️ REMPLACER PAR VOTRE NUMÉRO
      NOW(),
      NOW()
    )
    ON CONFLICT (id) DO NOTHING;
    RAISE NOTICE '✅ Entrée PDG créée';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '⚠️ Table PDG non disponible (optionnel)';
  END;

  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE '✅ COMPTE CEO CRÉÉ AVEC SUCCÈS !';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE 'Email: %', v_email;
  RAISE NOTICE 'ID Personnalisé: %', v_custom_id;
  RAISE NOTICE 'Rôle: CEO';
  RAISE NOTICE '';
  RAISE NOTICE '🔐 Vous pouvez maintenant vous connecter avec:';
  RAISE NOTICE '   Email: %', v_email;
  RAISE NOTICE '   Password: (celui que vous avez défini)';
  RAISE NOTICE '';
  RAISE NOTICE '📱 Accès autorisé aux interfaces:';
  RAISE NOTICE '   - /pdg (avec rôle admin requis - à modifier)';
  RAISE NOTICE '   - /pdg/copilot (accès direct)';
  RAISE NOTICE '   - Tous les dashboards CEO';
  RAISE NOTICE '═══════════════════════════════════════════════';
END $$;
