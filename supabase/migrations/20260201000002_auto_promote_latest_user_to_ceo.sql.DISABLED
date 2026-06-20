-- =======================================================================
-- PROMOUVOIR AUTOMATIQUEMENT LE DERNIER UTILISATEUR VERS CEO
-- =======================================================================
-- Ce script trouve le dernier utilisateur créé dans auth.users
-- et le promeut automatiquement vers CEO
-- =======================================================================

DO $$
DECLARE
  v_user_id UUID;
  v_email TEXT;
  v_custom_id TEXT;
BEGIN
  -- Trouver le dernier utilisateur créé dans auth.users
  SELECT id, email INTO v_user_id, v_email
  FROM auth.users
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Aucun utilisateur trouvé dans auth.users';
  END IF;

  RAISE NOTICE '📧 Utilisateur trouvé: %', v_email;
  RAISE NOTICE '🆔 UUID: %', v_user_id;

  -- Créer ou mettre à jour le profil vers CEO
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
    'PDG',
    '224Solutions',
    'ceo',
    true,
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO UPDATE SET
    role = 'ceo',
    is_active = true,
    updated_at = NOW();

  RAISE NOTICE '✅ Profil CEO créé/mis à jour';

  -- Générer un ID personnalisé pour le CEO
  BEGIN
    SELECT generate_custom_id_with_role('ceo') INTO v_custom_id;

    INSERT INTO user_ids (user_id, custom_id, created_at)
    VALUES (v_user_id, v_custom_id, NOW())
    ON CONFLICT (user_id)
    DO UPDATE SET custom_id = v_custom_id;

    RAISE NOTICE '✅ ID personnalisé créé: %', v_custom_id;
  EXCEPTION WHEN OTHERS THEN
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
    INSERT INTO wallets (user_id, balance, currency, created_at, updated_at)
    VALUES (v_user_id, 0, 'GNF', NOW(), NOW())
    ON CONFLICT (user_id) DO NOTHING;
    RAISE NOTICE '✅ Wallet créé';
  END;

  -- Créer/mettre à jour carte virtuelle avec limites CEO
  INSERT INTO virtual_cards (
    user_id,
    card_number,
    holder_name,
    expiry_date,
    cvv,
    daily_limit,
    monthly_limit,
    created_at
  ) VALUES (
    v_user_id,
    '4*** **** **** ' || LPAD((FLOOR(RANDOM() * 9999))::TEXT, 4, '0'),
    'PDG 224Solutions',
    TO_CHAR(NOW() + INTERVAL '3 years', 'MM/YY'),
    LPAD((FLOOR(RANDOM() * 900 + 100))::TEXT, 3, '0'),
    10000000,  -- 10M GNF par jour
    50000000,  -- 50M GNF par mois
    NOW()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    daily_limit = 10000000,
    monthly_limit = 50000000;

  RAISE NOTICE '✅ Carte virtuelle créée/mise à jour';

  -- Créer entrée dans la table PDG
  BEGIN
    INSERT INTO pdg (id, name, email, phone, created_at, updated_at)
    VALUES (
      v_user_id,
      'PDG 224Solutions',
      v_email,
      '+224 000 00 00 00',
      NOW(),
      NOW()
    )
    ON CONFLICT (id) DO UPDATE SET
      email = v_email,
      updated_at = NOW();

    RAISE NOTICE '✅ Entrée PDG créée/mise à jour';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '⚠️ Table PDG non disponible (optionnel)';
  END;

  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE '✅ UTILISATEUR PROMU EN CEO AVEC SUCCÈS !';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE 'Email: %', v_email;
  RAISE NOTICE 'UUID: %', v_user_id;
  RAISE NOTICE 'ID Personnalisé: %', v_custom_id;
  RAISE NOTICE 'Rôle: CEO';
  RAISE NOTICE '';
  RAISE NOTICE '🔐 POUR VOUS CONNECTER:';
  RAISE NOTICE '   1. Allez sur la page de connexion';
  RAISE NOTICE '   2. Cliquez sur "Mot de passe oublié"';
  RAISE NOTICE '   3. Entrez: %', v_email;
  RAISE NOTICE '   4. Vérifiez vos emails';
  RAISE NOTICE '   5. Créez votre nouveau mot de passe';
  RAISE NOTICE '';
  RAISE NOTICE '📱 Limites de carte virtuelle:';
  RAISE NOTICE '   - Quotidien: 10,000,000 GNF';
  RAISE NOTICE '   - Mensuel: 50,000,000 GNF';
  RAISE NOTICE '═══════════════════════════════════════════════';
END $$;
