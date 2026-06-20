-- Corriger le nom de colonne dans auto_create_user_data
CREATE OR REPLACE FUNCTION public.auto_create_user_data()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_custom_id TEXT;
BEGIN
  -- Générer un custom_id unique
  v_custom_id := generate_unique_custom_id();
  
  -- Créer custom_id dans user_ids (avec ON CONFLICT sur user_id qui est unique)
  INSERT INTO user_ids (user_id, custom_id, created_at)
  VALUES (NEW.id, v_custom_id, NOW())
  ON CONFLICT (user_id) DO NOTHING;
  
  -- Créer wallet (avec ON CONFLICT sur (user_id, currency) qui est unique)
  INSERT INTO wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
  VALUES (NEW.id, 0, 'GNF', 'active', NOW(), NOW())
  ON CONFLICT (user_id, currency) DO NOTHING;
  
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION auto_create_user_data() IS 'Crée automatiquement user_ids et wallet après insertion dans profiles';
