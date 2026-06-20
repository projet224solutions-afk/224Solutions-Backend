-- Corriger TOUTES les fonctions qui utilisent 'status' au lieu de 'wallet_status' dans la table wallets

-- 1. Corriger auto_create_user_data()
CREATE OR REPLACE FUNCTION public.auto_create_user_data()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_custom_id TEXT;
  v_wallet_id UUID;
BEGIN
  -- Générer un custom_id unique
  v_custom_id := generate_unique_custom_id();
  
  -- Créer custom_id dans user_ids (avec ON CONFLICT sur user_id qui est unique)
  INSERT INTO user_ids (user_id, custom_id, created_at)
  VALUES (NEW.id, v_custom_id, NOW())
  ON CONFLICT (user_id) DO NOTHING;
  
  -- Créer wallet (avec ON CONFLICT sur (user_id, currency) qui est unique)
  -- CORRECTION: utiliser wallet_status au lieu de status
  INSERT INTO wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
  VALUES (NEW.id, 0, 'GNF', 'active', NOW(), NOW())
  ON CONFLICT (user_id, currency) DO NOTHING;
  
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION auto_create_user_data() IS 'Crée automatiquement user_ids et wallet après insertion dans profiles';

-- 2. Corriger process_wallet_transfer() si elle existe
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc 
    WHERE proname = 'process_wallet_transfer'
  ) THEN
    -- Recréer la fonction avec la bonne colonne
    EXECUTE '
      CREATE OR REPLACE FUNCTION public.process_wallet_transfer(
        p_sender_id UUID,
        p_receiver_id UUID,
        p_amount NUMERIC,
        p_currency VARCHAR,
        p_description TEXT DEFAULT NULL
      )
      RETURNS TABLE (
        success BOOLEAN,
        message TEXT,
        transfer_id UUID
      )
      LANGUAGE plpgsql
      SECURITY DEFINER
      SET search_path = public
      AS $func$
      DECLARE
        v_sender_balance NUMERIC;
        v_transfer_id UUID;
        v_total_debit NUMERIC;
        v_commission NUMERIC;
      BEGIN
        -- Vérifier que sender et receiver sont différents
        IF p_sender_id = p_receiver_id THEN
          RETURN QUERY SELECT FALSE, ''Impossible de transférer à soi-même'', NULL::UUID;
          RETURN;
        END IF;

        -- Vérifier le solde du sender
        SELECT balance INTO v_sender_balance
        FROM wallets
        WHERE user_id = p_sender_id AND currency = p_currency;

        IF v_sender_balance IS NULL THEN
          RETURN QUERY SELECT FALSE, ''Portefeuille non trouvé'', NULL::UUID;
          RETURN;
        END IF;

        -- Calculer la commission
        v_commission := 0;
        v_total_debit := p_amount + v_commission;

        IF v_sender_balance < v_total_debit THEN
          RETURN QUERY SELECT FALSE, ''Solde insuffisant'', NULL::UUID;
          RETURN;
        END IF;

        -- Débiter le sender
        UPDATE wallets
        SET balance = balance - v_total_debit, updated_at = now()
        WHERE user_id = p_sender_id AND currency = p_currency;

        -- Créditer le destinataire avec wallet_status au lieu de status
        INSERT INTO wallets (user_id, balance, currency, wallet_status)
        VALUES (p_receiver_id, p_amount, p_currency, ''active'')
        ON CONFLICT (user_id, currency) 
        DO UPDATE SET 
          balance = wallets.balance + p_amount, 
          updated_at = now();

        RETURN QUERY SELECT TRUE, ''Transfert effectué avec succès'', v_transfer_id;
      END;
      $func$;
    ';
  END IF;
END $$;