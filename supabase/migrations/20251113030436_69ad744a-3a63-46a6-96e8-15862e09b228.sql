
-- ============================================
-- SOLUTION DÉFINITIVE WALLET - 224SOLUTIONS
-- Étape 1: Ajouter les contraintes manquantes
-- ============================================

-- 1. Ajouter une contrainte UNIQUE sur user_id (si elle n'existe pas)
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint 
    WHERE conname = 'wallets_user_id_key'
  ) THEN
    ALTER TABLE public.wallets 
    ADD CONSTRAINT wallets_user_id_key UNIQUE (user_id);
  END IF;
END $$;

-- 2. Créer une fonction SECURITY DEFINER pour initialiser les wallets
CREATE OR REPLACE FUNCTION public.initialize_user_wallet(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id uuid;
  v_result jsonb;
BEGIN
  -- Sécurité: autoriser seulement le rôle `service_role` ou l'utilisateur ciblé
  IF auth.role() IS NOT NULL AND auth.role() <> 'service_role' AND auth.uid() IS NOT NULL AND auth.uid() <> p_user_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED', 'message', 'Not allowed to initialize wallet for another user');
  END IF;

  -- Vérifier si le wallet existe déjà
  SELECT id INTO v_wallet_id
  FROM public.wallets
  WHERE user_id = p_user_id;

  -- Si le wallet existe, le retourner
  IF v_wallet_id IS NOT NULL THEN
    SELECT jsonb_build_object(
      'success', true,
      'wallet_id', id,
      'balance', balance,
      'currency', currency,
      'message', 'Wallet existant'
    ) INTO v_result
    FROM public.wallets
    WHERE id = v_wallet_id;
    
    RETURN v_result;
  END IF;

  -- Créer le wallet
  INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
  VALUES (p_user_id, 0, 'GNF', 'active')
  RETURNING id INTO v_wallet_id;

  -- Retourner le résultat
  SELECT jsonb_build_object(
    'success', true,
    'wallet_id', v_wallet_id,
    'balance', 0,
    'currency', 'GNF',
    'message', 'Wallet créé avec succès'
  ) INTO v_result;

  RETURN v_result;

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$;

-- 3. Donner les permissions d'exécution
GRANT EXECUTE ON FUNCTION public.initialize_user_wallet TO authenticated;

-- 4. Créer un trigger pour auto-créer les wallets lors de l'inscription
CREATE OR REPLACE FUNCTION public.auto_create_user_wallet()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Créer le wallet automatiquement avec gestion des doublons
  INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
  VALUES (NEW.id, 0, 'GNF', 'active')
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
END;
$$;

-- 5. Créer le trigger sur auth.users
DROP TRIGGER IF EXISTS auto_create_wallet_on_signup ON auth.users;
CREATE TRIGGER auto_create_wallet_on_signup
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_create_user_wallet();

-- 6. Créer les wallets manquants pour les utilisateurs existants
INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
SELECT 
  au.id,
  0,
  'GNF',
  'active'
FROM auth.users au
LEFT JOIN public.wallets w ON w.user_id = au.id
WHERE w.id IS NULL
ON CONFLICT (user_id) DO NOTHING;

-- 7. Commentaires
COMMENT ON FUNCTION public.initialize_user_wallet IS 'Fonction sécurisée pour initialiser un wallet utilisateur via SECURITY DEFINER';
COMMENT ON FUNCTION public.auto_create_user_wallet IS 'Trigger function pour créer automatiquement un wallet lors de l''inscription';
