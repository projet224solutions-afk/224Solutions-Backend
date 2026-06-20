-- Corriger toutes les références à wallets.status en wallets.wallet_status
-- dans les fonctions qui pourraient avoir ce problème

-- 1. Vérifier et corriger la fonction de création automatique de wallet
CREATE OR REPLACE FUNCTION public.ensure_user_wallet()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Créer un wallet si l'utilisateur n'en a pas
  IF NOT EXISTS (
    SELECT 1 FROM wallets WHERE user_id = NEW.id
  ) THEN
    INSERT INTO wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
    VALUES (NEW.id, 0, 'GNF', 'active', NOW(), NOW());
  END IF;
  
  RETURN NEW;
END;
$$;

-- 2. S'assurer que tous les triggers utilisent la bonne colonne
-- Recréer le trigger si nécessaire
DROP TRIGGER IF EXISTS ensure_user_wallet_trigger ON auth.users;
CREATE TRIGGER ensure_user_wallet_trigger
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION ensure_user_wallet();