-- Créer un trigger pour enregistrer automatiquement les revenus de transfert
CREATE OR REPLACE FUNCTION auto_record_transfer_revenue()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fee_amount DECIMAL;
BEGIN
  -- Si c'est un transfert wallet complété avec frais
  IF NEW.method = 'wallet' 
     AND NEW.status = 'completed' 
     AND NEW.metadata ? 'fee_amount' THEN
    
    v_fee_amount := (NEW.metadata->>'fee_amount')::DECIMAL;
    
    -- Enregistrer le revenu
    PERFORM record_platform_revenue(
      'transfer_fee',
      v_fee_amount,
      NEW.id,
      jsonb_build_object(
        'sender_id', NEW.sender_id,
        'receiver_id', NEW.receiver_id,
        'transfer_amount', NEW.amount,
        'fee_percent', (NEW.metadata->>'fee_percent')::DECIMAL
      )
    );
  END IF;
  
  RETURN NEW;
END;
$$;

-- Créer le trigger sur enhanced_transactions
DROP TRIGGER IF EXISTS trigger_record_transfer_revenue ON enhanced_transactions;
CREATE TRIGGER trigger_record_transfer_revenue
  AFTER INSERT ON enhanced_transactions
  FOR EACH ROW
  EXECUTE FUNCTION auto_record_transfer_revenue();

-- Créer une fonction pour initialiser/récupérer le wallet PDG
CREATE OR REPLACE FUNCTION ensure_pdg_wallet()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pdg_wallet_id UUID := '00000000-0000-0000-0000-000000000001';
  v_existing_wallet UUID;
  v_admin_user_id UUID;
BEGIN
  -- Vérifier si le wallet PDG existe déjà
  SELECT id INTO v_existing_wallet
  FROM wallets
  WHERE id = v_pdg_wallet_id;

  IF v_existing_wallet IS NOT NULL THEN
    RETURN v_existing_wallet;
  END IF;

  -- Sinon, récupérer ou créer un wallet pour l'admin
  -- Récupérer le premier wallet GNF d'un admin
  SELECT w.id INTO v_existing_wallet
  FROM wallets w
  JOIN profiles p ON w.user_id = p.id
  WHERE p.role = 'admin'
    AND w.currency = 'GNF'
  LIMIT 1;

  IF v_existing_wallet IS NOT NULL THEN
    -- Utiliser ce wallet existant comme wallet PDG
    UPDATE system_settings
    SET setting_value = v_existing_wallet::TEXT
    WHERE setting_key = 'pdg_wallet_id';
    
    RETURN v_existing_wallet;
  END IF;

  -- Si vraiment aucun wallet admin n'existe, en créer un
  SELECT id INTO v_admin_user_id
  FROM profiles
  WHERE role = 'admin'
  LIMIT 1;

  IF v_admin_user_id IS NOT NULL THEN
    INSERT INTO wallets (id, user_id, balance, currency)
    VALUES (v_pdg_wallet_id, v_admin_user_id, 0, 'GNF')
    ON CONFLICT (user_id, currency) DO NOTHING;
    
    RETURN v_pdg_wallet_id;
  END IF;

  RAISE EXCEPTION 'Impossible de créer ou trouver un wallet PDG';
END;
$$;

-- S'assurer que le wallet PDG existe
DO $$
BEGIN
  PERFORM ensure_pdg_wallet();
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Wallet PDG sera initialisé au premier transfert';
END $$;

COMMENT ON FUNCTION auto_record_transfer_revenue IS 'Trigger pour enregistrer automatiquement les frais de transfert dans platform_revenue';
COMMENT ON FUNCTION ensure_pdg_wallet IS 'Récupère ou crée le wallet PDG pour les revenus de la plateforme';