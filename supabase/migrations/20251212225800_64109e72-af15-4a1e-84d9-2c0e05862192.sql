
-- =====================================================
-- CORRECTION CRITIQUE: TRANSACTIONS FINANCIÈRES AGENTS
-- Fonction atomique avec journalisation et validation
-- =====================================================

-- 1. Créer une table pour journaliser toutes les transactions avec soldes avant/après
CREATE TABLE IF NOT EXISTS transaction_audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID,
  user_id UUID NOT NULL,
  user_type TEXT, -- 'agent', 'vendor', 'client', 'bureau'
  operation_type TEXT NOT NULL, -- 'credit', 'debit', 'transfer_in', 'transfer_out'
  amount NUMERIC NOT NULL,
  fee_amount NUMERIC DEFAULT 0,
  balance_before NUMERIC NOT NULL,
  balance_after NUMERIC NOT NULL,
  expected_balance NUMERIC NOT NULL, -- pour validation
  is_valid BOOLEAN DEFAULT TRUE,
  error_message TEXT,
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Index pour recherche rapide
CREATE INDEX IF NOT EXISTS idx_transaction_audit_user ON transaction_audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_transaction_audit_created ON transaction_audit_log(created_at DESC);

-- 2. Fonction atomique corrigée pour les transferts avec journalisation complète
CREATE OR REPLACE FUNCTION process_secure_wallet_transfer(
  p_sender_id UUID,
  p_receiver_id UUID,
  p_amount NUMERIC,
  p_description TEXT DEFAULT NULL,
  p_fee_percent NUMERIC DEFAULT 1.5
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_fee_amount NUMERIC;
  v_total_debit NUMERIC;
  v_sender_balance_before NUMERIC;
  v_sender_balance_after NUMERIC;
  v_receiver_balance_before NUMERIC;
  v_receiver_balance_after NUMERIC;
  v_transaction_id UUID;
  v_sender_agent_id UUID;
  v_receiver_agent_id UUID;
  v_idempotency_key TEXT;
BEGIN
  -- Générer une clé d'idempotence
  v_idempotency_key := md5(p_sender_id::text || p_receiver_id::text || p_amount::text || now()::text);
  
  -- Vérification anti-doublon (même transaction dans les 5 dernières secondes)
  IF EXISTS (
    SELECT 1 FROM enhanced_transactions 
    WHERE sender_id = p_sender_id 
    AND receiver_id = p_receiver_id 
    AND amount = p_amount 
    AND created_at > now() - interval '5 seconds'
  ) THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Transaction doublon détectée. Veuillez patienter.',
      'code', 'DUPLICATE_TRANSACTION'
    );
  END IF;
  
  -- Calcul des frais
  v_fee_amount := ROUND((p_amount * p_fee_percent) / 100, 0);
  v_total_debit := p_amount + v_fee_amount;
  
  -- Vérifier et récupérer le solde de l'expéditeur avec verrouillage
  SELECT balance INTO v_sender_balance_before
  FROM wallets
  WHERE user_id = p_sender_id
  FOR UPDATE;
  
  IF v_sender_balance_before IS NULL THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Wallet expéditeur introuvable',
      'code', 'SENDER_WALLET_NOT_FOUND'
    );
  END IF;
  
  -- Vérifier le solde suffisant (montant + frais)
  IF v_sender_balance_before < v_total_debit THEN
    RETURN json_build_object(
      'success', false,
      'error', 'Solde insuffisant',
      'code', 'INSUFFICIENT_BALANCE',
      'required', v_total_debit,
      'current', v_sender_balance_before
    );
  END IF;
  
  -- Vérifier et récupérer le solde du destinataire avec verrouillage
  SELECT balance INTO v_receiver_balance_before
  FROM wallets
  WHERE user_id = p_receiver_id
  FOR UPDATE;
  
  IF v_receiver_balance_before IS NULL THEN
    -- Créer le wallet s'il n'existe pas
    INSERT INTO wallets (user_id, balance, currency, wallet_status)
    VALUES (p_receiver_id, 0, 'GNF', 'active');
    v_receiver_balance_before := 0;
  END IF;
  
  -- ========================================
  -- CALCUL CRITIQUE: Nouveaux soldes
  -- ========================================
  v_sender_balance_after := v_sender_balance_before - v_total_debit;
  v_receiver_balance_after := v_receiver_balance_before + p_amount; -- Le destinataire reçoit le montant COMPLET (sans frais)
  
  -- ========================================
  -- VALIDATION PRÉ-TRANSACTION
  -- ========================================
  IF v_sender_balance_after != (v_sender_balance_before - v_total_debit) THEN
    -- Journaliser l'erreur
    INSERT INTO transaction_audit_log (
      user_id, operation_type, amount, balance_before, balance_after, 
      expected_balance, is_valid, error_message
    ) VALUES (
      p_sender_id, 'debit', v_total_debit, v_sender_balance_before, v_sender_balance_after,
      v_sender_balance_before - v_total_debit, false, 'Erreur de calcul débit'
    );
    RETURN json_build_object('success', false, 'error', 'Erreur de calcul détectée', 'code', 'CALCULATION_ERROR');
  END IF;
  
  IF v_receiver_balance_after != (v_receiver_balance_before + p_amount) THEN
    -- Journaliser l'erreur
    INSERT INTO transaction_audit_log (
      user_id, operation_type, amount, balance_before, balance_after,
      expected_balance, is_valid, error_message
    ) VALUES (
      p_receiver_id, 'credit', p_amount, v_receiver_balance_before, v_receiver_balance_after,
      v_receiver_balance_before + p_amount, false, 'Erreur de calcul crédit'
    );
    RETURN json_build_object('success', false, 'error', 'Erreur de calcul détectée', 'code', 'CALCULATION_ERROR');
  END IF;
  
  -- ========================================
  -- EXÉCUTION DES MISES À JOUR ATOMIQUES
  -- ========================================
  
  -- 1. Débiter l'expéditeur
  UPDATE wallets
  SET balance = v_sender_balance_after, updated_at = now()
  WHERE user_id = p_sender_id;
  
  -- 2. Créditer le destinataire
  UPDATE wallets
  SET balance = v_receiver_balance_after, updated_at = now()
  WHERE user_id = p_receiver_id;
  
  -- 3. Créer la transaction dans enhanced_transactions
  INSERT INTO enhanced_transactions (
    sender_id, receiver_id, amount, currency, method, status, metadata, created_at
  ) VALUES (
    p_sender_id, p_receiver_id, p_amount, 'GNF', 'wallet', 'completed',
    jsonb_build_object(
      'description', COALESCE(p_description, 'Transfert'),
      'fee_percent', p_fee_percent,
      'fee_amount', v_fee_amount,
      'total_debit', v_total_debit,
      'amount_received', p_amount,
      'sender_balance_before', v_sender_balance_before,
      'sender_balance_after', v_sender_balance_after,
      'receiver_balance_before', v_receiver_balance_before,
      'receiver_balance_after', v_receiver_balance_after,
      'idempotency_key', v_idempotency_key
    ),
    now()
  ) RETURNING id INTO v_transaction_id;
  
  -- 4. Journaliser l'opération pour l'expéditeur
  INSERT INTO transaction_audit_log (
    transaction_id, user_id, operation_type, amount, fee_amount,
    balance_before, balance_after, expected_balance, is_valid, metadata
  ) VALUES (
    v_transaction_id, p_sender_id, 'transfer_out', v_total_debit, v_fee_amount,
    v_sender_balance_before, v_sender_balance_after, v_sender_balance_after, true,
    jsonb_build_object('receiver_id', p_receiver_id, 'description', p_description)
  );
  
  -- 5. Journaliser l'opération pour le destinataire
  INSERT INTO transaction_audit_log (
    transaction_id, user_id, operation_type, amount, fee_amount,
    balance_before, balance_after, expected_balance, is_valid, metadata
  ) VALUES (
    v_transaction_id, p_receiver_id, 'transfer_in', p_amount, 0,
    v_receiver_balance_before, v_receiver_balance_after, v_receiver_balance_after, true,
    jsonb_build_object('sender_id', p_sender_id, 'description', p_description)
  );
  
  -- ========================================
  -- SYNCHRONISATION AGENT_WALLETS
  -- ========================================
  
  -- Synchroniser l'agent expéditeur si applicable
  SELECT id INTO v_sender_agent_id FROM agents_management WHERE user_id = p_sender_id;
  IF v_sender_agent_id IS NOT NULL THEN
    UPDATE agent_wallets
    SET balance = v_sender_balance_after, updated_at = now()
    WHERE agent_id = v_sender_agent_id;
  END IF;
  
  -- Synchroniser l'agent destinataire si applicable
  SELECT id INTO v_receiver_agent_id FROM agents_management WHERE user_id = p_receiver_id;
  IF v_receiver_agent_id IS NOT NULL THEN
    UPDATE agent_wallets
    SET balance = v_receiver_balance_after, updated_at = now()
    WHERE agent_id = v_receiver_agent_id;
  END IF;
  
  -- ========================================
  -- VÉRIFICATION POST-TRANSACTION
  -- ========================================
  DECLARE
    v_verify_sender NUMERIC;
    v_verify_receiver NUMERIC;
  BEGIN
    SELECT balance INTO v_verify_sender FROM wallets WHERE user_id = p_sender_id;
    SELECT balance INTO v_verify_receiver FROM wallets WHERE user_id = p_receiver_id;
    
    IF v_verify_sender != v_sender_balance_after OR v_verify_receiver != v_receiver_balance_after THEN
      -- Annuler en cas d'incohérence
      RAISE EXCEPTION 'Incohérence de solde post-transaction détectée';
    END IF;
  END;
  
  -- Retourner le succès avec tous les détails
  RETURN json_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount', p_amount,
    'fee_amount', v_fee_amount,
    'fee_percent', p_fee_percent,
    'total_debit', v_total_debit,
    'sender_balance_before', v_sender_balance_before,
    'sender_balance_after', v_sender_balance_after,
    'receiver_balance_before', v_receiver_balance_before,
    'receiver_balance_after', v_receiver_balance_after
  );
  
EXCEPTION
  WHEN OTHERS THEN
    -- Journaliser l'erreur
    INSERT INTO transaction_audit_log (
      user_id, operation_type, amount, balance_before, balance_after,
      expected_balance, is_valid, error_message
    ) VALUES (
      p_sender_id, 'transfer_failed', p_amount, COALESCE(v_sender_balance_before, 0), 
      COALESCE(v_sender_balance_before, 0), 0, false, SQLERRM
    );
    
    RETURN json_build_object(
      'success', false,
      'error', 'Erreur lors de la transaction: ' || SQLERRM,
      'code', 'TRANSACTION_FAILED'
    );
END;
$$;

-- 3. Corriger immédiatement la désynchronisation actuelle entre wallets et agent_wallets
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN 
    SELECT am.id as agent_id, w.balance as correct_balance
    FROM agents_management am
    JOIN wallets w ON w.user_id = am.user_id
    LEFT JOIN agent_wallets aw ON aw.agent_id = am.id
    WHERE w.balance != COALESCE(aw.balance, 0)
  LOOP
    UPDATE agent_wallets
    SET balance = r.correct_balance, updated_at = now()
    WHERE agent_id = r.agent_id;
    
    -- Si le wallet agent n'existe pas, le créer
    INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
    VALUES (r.agent_id, r.correct_balance, 'GNF', 'active')
    ON CONFLICT (agent_id) DO UPDATE SET balance = r.correct_balance, updated_at = now();
  END LOOP;
END $$;

-- 4. Améliorer le trigger de synchronisation pour être plus robuste
CREATE OR REPLACE FUNCTION sync_agent_wallet_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_agent_id UUID;
BEGIN
  -- Trouver si cet utilisateur est un agent
  SELECT id INTO v_agent_id
  FROM agents_management
  WHERE user_id = NEW.user_id;
  
  IF v_agent_id IS NOT NULL THEN
    -- Synchroniser le solde vers agent_wallets immédiatement
    UPDATE agent_wallets
    SET balance = NEW.balance, updated_at = now()
    WHERE agent_id = v_agent_id;
    
    -- Si le wallet agent n'existe pas encore, le créer
    IF NOT FOUND THEN
      INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
      VALUES (v_agent_id, NEW.balance, 'GNF', 'active');
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

-- 5. Recréer le trigger pour s'assurer qu'il est actif
DROP TRIGGER IF EXISTS trigger_sync_agent_wallet ON wallets;
CREATE TRIGGER trigger_sync_agent_wallet
AFTER INSERT OR UPDATE OF balance ON wallets
FOR EACH ROW
EXECUTE FUNCTION sync_agent_wallet_balance();

-- 6. Activer RLS sur la nouvelle table d'audit
ALTER TABLE transaction_audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own audit logs"
ON transaction_audit_log FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "System can insert audit logs"
ON transaction_audit_log FOR INSERT
WITH CHECK (true);

-- 7. Grant permissions
GRANT SELECT ON transaction_audit_log TO authenticated;
GRANT INSERT ON transaction_audit_log TO authenticated;
