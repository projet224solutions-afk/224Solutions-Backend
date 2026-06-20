-- ============================================================
-- CORRECTION PROFONDE: Wallet Agent PDG
-- ============================================================
-- Problème: La contrainte wallets_user_id_fkey référence auth.users
-- Les agents sont dans agents_management, pas dans auth.users
-- Solution: S'assurer qu'aucun système n'essaie de créer des wallets
-- dans la table 'wallets' pour des agents
-- ============================================================

-- 1. Créer une fonction sécurisée pour vérifier si un ID est un vrai utilisateur
CREATE OR REPLACE FUNCTION public.is_real_user(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
BEGIN
  -- Vérifier si l'ID existe dans auth.users
  RETURN EXISTS (
    SELECT 1 FROM auth.users WHERE id = p_user_id
  );
END;
$$;

-- 2. Modifier initialize_user_wallet pour vérifier avant de créer
DROP FUNCTION IF EXISTS public.initialize_user_wallet(UUID) CASCADE;

CREATE FUNCTION public.initialize_user_wallet(p_user_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_wallet_id UUID;
  v_balance NUMERIC := 0;
  v_currency TEXT := 'GNF';
BEGIN
  -- CRITIQUE: Vérifier que c'est un vrai utilisateur dans auth.users
  IF NOT public.is_real_user(p_user_id) THEN
    RETURN json_build_object(
      'success', false,
      'error', 'INVALID_USER',
      'message', 'Cet ID n''est pas un utilisateur valide. Les agents utilisent agent_wallets.'
    );
  END IF;

  -- Vérifier si le wallet existe déjà
  SELECT id, balance, currency
  INTO v_wallet_id, v_balance, v_currency
  FROM wallets
  WHERE user_id = p_user_id;

  -- Si le wallet n'existe pas, le créer
  IF v_wallet_id IS NULL THEN
    INSERT INTO wallets (user_id, balance, currency, wallet_status)
    VALUES (p_user_id, 0, 'GNF', 'active')
    RETURNING id, balance, currency INTO v_wallet_id, v_balance, v_currency;
  END IF;

  -- Retourner les informations du wallet
  RETURN json_build_object(
    'success', true,
    'wallet_id', v_wallet_id,
    'balance', v_balance,
    'currency', v_currency
  );
EXCEPTION
  WHEN foreign_key_violation THEN
    RETURN json_build_object(
      'success', false,
      'error', 'FOREIGN_KEY_VIOLATION',
      'message', 'Impossible de créer un wallet pour cet ID. Utilisez agent_wallets pour les agents.'
    );
  WHEN OTHERS THEN
    RETURN json_build_object(
      'success', false,
      'error', SQLSTATE,
      'message', SQLERRM
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.initialize_user_wallet TO authenticated;

-- 3. Modifier auto_create_user_wallet pour ne créer que pour auth.users
DROP FUNCTION IF EXISTS public.auto_create_user_wallet() CASCADE;

CREATE FUNCTION public.auto_create_user_wallet()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
BEGIN
  -- Créer un wallet automatiquement uniquement pour les nouveaux utilisateurs auth.users
  -- Les agents auront leur wallet créé dans agent_wallets séparément
  INSERT INTO wallets (user_id, balance, currency, wallet_status)
  VALUES (NEW.id, 0, 'GNF', 'active')
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
EXCEPTION
  WHEN foreign_key_violation THEN
    -- Si la clé étrangère échoue, c'est que ce n'est pas un vrai utilisateur
    -- Ne pas lever d'erreur, juste ignorer
    RETURN NEW;
  WHEN OTHERS THEN
    -- Logger l'erreur mais ne pas bloquer la création de l'utilisateur
    RAISE WARNING 'Erreur création wallet automatique: % %', SQLSTATE, SQLERRM;
    RETURN NEW;
END;
$$;

-- Recréer le trigger sur auth.users
DROP TRIGGER IF EXISTS on_auth_user_created_wallet ON auth.users;
CREATE TRIGGER on_auth_user_created_wallet
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_create_user_wallet();

-- 4. S'assurer que agent_wallets a bien sa structure
-- (Cette table devrait déjà exister, mais on la vérifie)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'agent_wallets') THEN
    RAISE EXCEPTION 'La table agent_wallets n''existe pas. Elle doit être créée d''abord.';
  END IF;
END
$$;

-- 5. Ajouter des commentaires de documentation
COMMENT ON FUNCTION public.is_real_user IS 'Vérifie si un UUID correspond à un utilisateur réel dans auth.users (pas un agent)';
COMMENT ON FUNCTION public.initialize_user_wallet IS 'Initialise un wallet UNIQUEMENT pour les vrais utilisateurs auth.users. Les agents utilisent agent_wallets.';
COMMENT ON FUNCTION public.auto_create_user_wallet IS 'Trigger pour créer automatiquement un wallet lors de l''inscription d''un utilisateur (auth.users uniquement)';

-- ============================================================
-- FIN DE LA CORRECTION
-- ============================================================