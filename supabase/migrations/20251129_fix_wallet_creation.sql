-- Migration: Fix wallet creation (20251129)
-- Objectif: Créer une fonction RPC sécurisée pour initialiser les wallets

-- 1. Créer la fonction RPC qui contourne les RLS
-- Migration: Fix wallet creation (20251129)
-- Objectif: Ajouter une RPC sécurisée unique pour initialiser les wallets sans modifier
-- les policies existantes afin d'éviter des effets de bord.

-- Crée une RPC nommée `rpc_create_user_wallet` (nom unique pour éviter conflits)
CREATE OR REPLACE FUNCTION public.rpc_create_user_wallet(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  user_id UUID,
  balance NUMERIC,
  currency TEXT,
  wallet_status TEXT,
  created_at TIMESTAMP
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
BEGIN
  -- Sécurité: autoriser seulement le rôle `service_role` ou l'utilisateur ciblé
  IF auth.role() IS NOT NULL AND auth.role() <> 'service_role' AND auth.uid() IS NOT NULL AND auth.uid() <> p_user_id THEN
    RAISE EXCEPTION 'Unauthorized to initialize wallet for another user';
  END IF;

  -- Vérifier que l'utilisateur existe dans auth.users
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_user_id) THEN
    RAISE EXCEPTION 'User % does not exist', p_user_id;
  END IF;

  -- Si le wallet existe déjà, le retourner
  IF EXISTS (SELECT 1 FROM wallets WHERE user_id = p_user_id) THEN
    RETURN QUERY
    SELECT id, user_id, balance, currency, wallet_status, created_at
    FROM wallets WHERE user_id = p_user_id;
    RETURN;
  END IF;

  -- Créer le wallet et le retourner
  RETURN QUERY
  INSERT INTO wallets (user_id, balance, currency, wallet_status)
  VALUES (p_user_id, 0, 'GNF', 'active')
  RETURNING id, user_id, balance, currency, wallet_status, created_at;
END;
$$;

-- Donner le droit d'exécution sur la RPC aux rôles standards (authentifié/anon/service_role)
GRANT EXECUTE ON FUNCTION public.rpc_create_user_wallet(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_create_user_wallet(UUID) TO service_role;

COMMENT ON FUNCTION public.rpc_create_user_wallet IS 'RPC (unique) pour initialiser/retourner le wallet utilisateur en toute sécurité.';
