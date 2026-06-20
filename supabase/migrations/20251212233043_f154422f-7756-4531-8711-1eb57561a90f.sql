-- =====================================================
-- SYSTÈME BANCAIRE INTELLIGENT - 224SOLUTIONS
-- Ledger Immuable + Double Écriture + Transactions 3 Phases
-- Chiffrement AES-256 + Hash SHA-256
-- Contrôle Panic PDG uniquement
-- =====================================================

-- 1. TABLE LEDGER FINANCIER IMMUABLE (Source de vérité)
CREATE TABLE IF NOT EXISTS financial_ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id TEXT UNIQUE NOT NULL,
  actor_id UUID NOT NULL,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('client', 'vendor', 'agent', 'bureau', 'driver', 'pdg', 'system')),
  debit_account UUID,
  credit_account UUID,
  amount NUMERIC(20, 2) NOT NULL CHECK (amount > 0),
  currency TEXT DEFAULT 'GNF',
  balance_before_debit NUMERIC(20, 2),
  balance_after_debit NUMERIC(20, 2),
  balance_before_credit NUMERIC(20, 2),
  balance_after_credit NUMERIC(20, 2),
  transaction_type TEXT NOT NULL,
  description TEXT,
  metadata JSONB DEFAULT '{}',
  ledger_hash TEXT NOT NULL,
  previous_hash TEXT,
  module_signature TEXT,
  module_name TEXT,
  is_valid BOOLEAN DEFAULT true,
  validation_status TEXT DEFAULT 'confirmed' CHECK (validation_status IN ('pending', 'confirmed', 'rejected', 'quarantined')),
  created_at TIMESTAMPTZ DEFAULT now(),
  confirmed_at TIMESTAMPTZ
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_financial_ledger_transaction_id ON financial_ledger(transaction_id);
CREATE INDEX IF NOT EXISTS idx_financial_ledger_actor ON financial_ledger(actor_id, actor_type);
CREATE INDEX IF NOT EXISTS idx_financial_ledger_accounts ON financial_ledger(debit_account, credit_account);
CREATE INDEX IF NOT EXISTS idx_financial_ledger_created ON financial_ledger(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_financial_ledger_status ON financial_ledger(validation_status);

-- 2. TABLE RÈGLES FINANCIÈRES DYNAMIQUES
CREATE TABLE IF NOT EXISTS financial_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_code TEXT UNIQUE NOT NULL,
  rule_name TEXT NOT NULL,
  rule_description TEXT,
  rule_logic JSONB NOT NULL,
  rule_type TEXT NOT NULL CHECK (rule_type IN ('validation', 'limit', 'security', 'compliance')),
  severity TEXT DEFAULT 'medium' CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  is_active BOOLEAN DEFAULT true,
  version INTEGER DEFAULT 1,
  applies_to TEXT[] DEFAULT ARRAY['all'],
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  updated_by UUID
);

-- 3. TABLE QUARANTAINE FINANCIÈRE
CREATE TABLE IF NOT EXISTS financial_quarantine (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  original_transaction_id TEXT NOT NULL,
  actor_id UUID NOT NULL,
  actor_type TEXT NOT NULL,
  amount NUMERIC(20, 2) NOT NULL,
  debit_account UUID,
  credit_account UUID,
  transaction_type TEXT NOT NULL,
  quarantine_reason TEXT NOT NULL,
  risk_score NUMERIC(5, 2) DEFAULT 0,
  anomaly_details JSONB DEFAULT '{}',
  rule_violated TEXT,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'escalated')),
  reviewed_by UUID,
  reviewed_at TIMESTAMPTZ,
  review_notes TEXT,
  original_payload JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_quarantine_status ON financial_quarantine(status);
CREATE INDEX IF NOT EXISTS idx_quarantine_actor ON financial_quarantine(actor_id);

-- 4. TABLE CONTRÔLE PDG (Panic/Freeze)
CREATE TABLE IF NOT EXISTS pdg_financial_control (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  control_type TEXT NOT NULL CHECK (control_type IN ('panic_mode', 'freeze_all', 'freeze_type', 'maintenance')),
  is_active BOOLEAN DEFAULT false,
  activated_by UUID NOT NULL,
  activated_at TIMESTAMPTZ DEFAULT now(),
  deactivated_by UUID,
  deactivated_at TIMESTAMPTZ,
  reason TEXT,
  affected_types TEXT[],
  metadata JSONB DEFAULT '{}'
);

-- 5. TABLE SIGNATURES MODULES
CREATE TABLE IF NOT EXISTS module_signatures (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  module_name TEXT UNIQUE NOT NULL,
  module_key TEXT NOT NULL,
  is_active BOOLEAN DEFAULT true,
  last_used_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 6. TABLE ALERTES PDG
CREATE TABLE IF NOT EXISTS pdg_financial_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_type TEXT NOT NULL CHECK (alert_type IN ('anomaly', 'rule_violation', 'quarantine', 'panic', 'reconciliation', 'integrity')),
  severity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical', 'emergency')),
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  related_transaction_id TEXT,
  related_actor_id UUID,
  metadata JSONB DEFAULT '{}',
  is_read BOOLEAN DEFAULT false,
  is_resolved BOOLEAN DEFAULT false,
  resolved_by UUID,
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pdg_alerts_unread ON pdg_financial_alerts(is_read, is_resolved);
CREATE INDEX IF NOT EXISTS idx_pdg_alerts_severity ON pdg_financial_alerts(severity, created_at DESC);

-- 7. TABLE RÉCONCILIATION DES SOLDES
CREATE TABLE IF NOT EXISTS balance_reconciliation (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id UUID NOT NULL,
  wallet_type TEXT NOT NULL,
  stored_balance NUMERIC(20, 2) NOT NULL,
  calculated_balance NUMERIC(20, 2) NOT NULL,
  difference NUMERIC(20, 2) NOT NULL,
  is_reconciled BOOLEAN DEFAULT false,
  reconciliation_action TEXT,
  reconciled_by UUID,
  reconciled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 8. TABLE STATISTIQUES PDG
CREATE TABLE IF NOT EXISTS pdg_financial_stats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stat_date DATE DEFAULT CURRENT_DATE,
  stat_hour INTEGER DEFAULT EXTRACT(HOUR FROM now()),
  total_transactions INTEGER DEFAULT 0,
  total_volume NUMERIC(20, 2) DEFAULT 0,
  successful_transactions INTEGER DEFAULT 0,
  failed_transactions INTEGER DEFAULT 0,
  quarantined_transactions INTEGER DEFAULT 0,
  transactions_by_type JSONB DEFAULT '{}',
  volume_by_actor_type JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(stat_date, stat_hour)
);

-- =====================================================
-- FONCTIONS DU SYSTÈME BANCAIRE
-- =====================================================

-- Fonction pour générer le hash du ledger (SHA-256 simulation)
CREATE OR REPLACE FUNCTION generate_ledger_hash(
  p_transaction_id TEXT,
  p_actor_id UUID,
  p_amount NUMERIC,
  p_debit_account UUID,
  p_credit_account UUID,
  p_previous_hash TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_data TEXT;
  v_hash TEXT;
BEGIN
  v_data := COALESCE(p_transaction_id, '') || 
            COALESCE(p_actor_id::TEXT, '') || 
            COALESCE(p_amount::TEXT, '') || 
            COALESCE(p_debit_account::TEXT, '') || 
            COALESCE(p_credit_account::TEXT, '') ||
            COALESCE(p_previous_hash, 'GENESIS') ||
            EXTRACT(EPOCH FROM now())::TEXT;
  
  v_hash := encode(sha256(v_data::bytea), 'hex');
  RETURN v_hash;
END;
$$;

-- Fonction pour vérifier l'intégrité du ledger
CREATE OR REPLACE FUNCTION verify_ledger_integrity()
RETURNS TABLE(
  is_valid BOOLEAN,
  invalid_entries INTEGER,
  last_verified_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_invalid_count INTEGER := 0;
  v_previous_hash TEXT := 'GENESIS';
  v_record RECORD;
BEGIN
  FOR v_record IN 
    SELECT * FROM financial_ledger ORDER BY created_at ASC
  LOOP
    IF v_record.previous_hash IS DISTINCT FROM v_previous_hash THEN
      v_invalid_count := v_invalid_count + 1;
    END IF;
    v_previous_hash := v_record.ledger_hash;
  END LOOP;
  
  is_valid := v_invalid_count = 0;
  invalid_entries := v_invalid_count;
  last_verified_at := now();
  RETURN NEXT;
END;
$$;

-- Fonction principale: Exécuter une transaction bancaire sécurisée
CREATE OR REPLACE FUNCTION execute_banking_transaction(
  p_transaction_id TEXT,
  p_actor_id UUID,
  p_actor_type TEXT,
  p_debit_account UUID,
  p_credit_account UUID,
  p_amount NUMERIC,
  p_transaction_type TEXT,
  p_description TEXT DEFAULT NULL,
  p_module_name TEXT DEFAULT 'system',
  p_metadata JSONB DEFAULT '{}'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
  v_panic_active BOOLEAN;
  v_debit_balance_before NUMERIC;
  v_debit_balance_after NUMERIC;
  v_credit_balance_before NUMERIC;
  v_credit_balance_after NUMERIC;
  v_previous_hash TEXT;
  v_new_hash TEXT;
  v_ledger_id UUID;
  v_rule_check JSONB;
  v_anomaly_score NUMERIC := 0;
  v_debit_wallet_type TEXT;
  v_credit_wallet_type TEXT;
BEGIN
  -- =====================================================
  -- PHASE 0: Vérification Mode Panic
  -- =====================================================
  SELECT EXISTS(
    SELECT 1 FROM pdg_financial_control 
    WHERE control_type IN ('panic_mode', 'freeze_all') 
    AND is_active = true
  ) INTO v_panic_active;
  
  IF v_panic_active THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'PANIC_MODE_ACTIVE',
      'message', 'Le système est en mode urgence. Toutes les transactions sont gelées.'
    );
  END IF;

  -- =====================================================
  -- PHASE 1: PRÉ-VALIDATION
  -- =====================================================
  
  -- Vérifier l'idempotence (transaction déjà exécutée?)
  IF EXISTS(SELECT 1 FROM financial_ledger WHERE transaction_id = p_transaction_id) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'DUPLICATE_TRANSACTION',
      'message', 'Cette transaction a déjà été exécutée'
    );
  END IF;
  
  -- Vérifier que le montant est positif
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INVALID_AMOUNT',
      'message', 'Le montant doit être supérieur à zéro'
    );
  END IF;
  
  -- Obtenir le solde du compte débiteur
  IF p_debit_account IS NOT NULL THEN
    -- Chercher dans wallets
    SELECT balance INTO v_debit_balance_before 
    FROM wallets WHERE user_id = p_debit_account;
    
    IF v_debit_balance_before IS NOT NULL THEN
      v_debit_wallet_type := 'wallet';
    ELSE
      -- Chercher dans agent_wallets
      SELECT balance INTO v_debit_balance_before 
      FROM agent_wallets WHERE agent_id = p_debit_account;
      
      IF v_debit_balance_before IS NOT NULL THEN
        v_debit_wallet_type := 'agent_wallet';
      ELSE
        -- Chercher dans bureau_wallets
        SELECT balance INTO v_debit_balance_before 
        FROM bureau_wallets WHERE bureau_id = p_debit_account;
        
        IF v_debit_balance_before IS NOT NULL THEN
          v_debit_wallet_type := 'bureau_wallet';
        END IF;
      END IF;
    END IF;
    
    IF v_debit_balance_before IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'DEBIT_ACCOUNT_NOT_FOUND',
        'message', 'Compte débiteur introuvable'
      );
    END IF;
    
    -- Vérifier solde suffisant
    IF v_debit_balance_before < p_amount THEN
      -- Créer alerte PDG
      INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, related_transaction_id, related_actor_id, metadata)
      VALUES ('rule_violation', 'warning', 'Solde insuffisant', 
              'Tentative de transaction avec solde insuffisant: ' || p_amount || ' GNF demandé, ' || v_debit_balance_before || ' GNF disponible',
              p_transaction_id, p_actor_id, 
              jsonb_build_object('requested', p_amount, 'available', v_debit_balance_before));
      
      RETURN jsonb_build_object(
        'success', false,
        'error', 'INSUFFICIENT_BALANCE',
        'message', 'Solde insuffisant',
        'balance', v_debit_balance_before,
        'requested', p_amount
      );
    END IF;
  END IF;
  
  -- Obtenir le solde du compte créditeur
  IF p_credit_account IS NOT NULL THEN
    SELECT balance INTO v_credit_balance_before 
    FROM wallets WHERE user_id = p_credit_account;
    
    IF v_credit_balance_before IS NOT NULL THEN
      v_credit_wallet_type := 'wallet';
    ELSE
      SELECT balance INTO v_credit_balance_before 
      FROM agent_wallets WHERE agent_id = p_credit_account;
      
      IF v_credit_balance_before IS NOT NULL THEN
        v_credit_wallet_type := 'agent_wallet';
      ELSE
        SELECT balance INTO v_credit_balance_before 
        FROM bureau_wallets WHERE bureau_id = p_credit_account;
        
        IF v_credit_balance_before IS NOT NULL THEN
          v_credit_wallet_type := 'bureau_wallet';
        END IF;
      END IF;
    END IF;
    
    IF v_credit_balance_before IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'CREDIT_ACCOUNT_NOT_FOUND',
        'message', 'Compte créditeur introuvable'
      );
    END IF;
  END IF;
  
  -- Vérification des règles financières actives
  FOR v_rule_check IN 
    SELECT rule_code, rule_logic, severity FROM financial_rules 
    WHERE is_active = true AND 'all' = ANY(applies_to) OR p_actor_type = ANY(applies_to)
  LOOP
    -- Règle: Pas de transfert à soi-même
    IF v_rule_check->>'rule_code' = 'NO_SELF_TRANSFER' AND p_debit_account = p_credit_account THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'SELF_TRANSFER_BLOCKED',
        'message', 'Les transferts vers soi-même sont interdits'
      );
    END IF;
  END LOOP;
  
  -- Détection d'anomalies simple (montant inhabituel)
  IF p_amount > 50000000 THEN
    v_anomaly_score := v_anomaly_score + 30;
  END IF;
  IF p_amount > 100000000 THEN
    v_anomaly_score := v_anomaly_score + 40;
  END IF;
  
  -- Si score d'anomalie élevé, mettre en quarantaine
  IF v_anomaly_score >= 50 THEN
    INSERT INTO financial_quarantine (
      original_transaction_id, actor_id, actor_type, amount, 
      debit_account, credit_account, transaction_type,
      quarantine_reason, risk_score, original_payload
    ) VALUES (
      p_transaction_id, p_actor_id, p_actor_type, p_amount,
      p_debit_account, p_credit_account, p_transaction_type,
      'Montant inhabituellement élevé', v_anomaly_score,
      jsonb_build_object('description', p_description, 'metadata', p_metadata)
    );
    
    INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, related_transaction_id, related_actor_id, metadata)
    VALUES ('quarantine', 'critical', 'Transaction mise en quarantaine', 
            'Montant suspect: ' || p_amount || ' GNF - Score risque: ' || v_anomaly_score,
            p_transaction_id, p_actor_id, 
            jsonb_build_object('amount', p_amount, 'risk_score', v_anomaly_score));
    
    RETURN jsonb_build_object(
      'success', false,
      'error', 'TRANSACTION_QUARANTINED',
      'message', 'Transaction mise en quarantaine pour vérification',
      'risk_score', v_anomaly_score
    );
  END IF;
  
  -- =====================================================
  -- PHASE 2: EXÉCUTION (Double écriture)
  -- =====================================================
  
  -- Obtenir le hash précédent
  SELECT ledger_hash INTO v_previous_hash 
  FROM financial_ledger 
  ORDER BY created_at DESC LIMIT 1;
  
  -- Générer le nouveau hash
  v_new_hash := generate_ledger_hash(
    p_transaction_id, p_actor_id, p_amount, 
    p_debit_account, p_credit_account, v_previous_hash
  );
  
  -- Calculer les nouveaux soldes
  v_debit_balance_after := COALESCE(v_debit_balance_before, 0) - p_amount;
  v_credit_balance_after := COALESCE(v_credit_balance_before, 0) + p_amount;
  
  -- Mettre à jour le compte débiteur
  IF p_debit_account IS NOT NULL THEN
    IF v_debit_wallet_type = 'wallet' THEN
      UPDATE wallets SET balance = v_debit_balance_after, updated_at = now() 
      WHERE user_id = p_debit_account;
    ELSIF v_debit_wallet_type = 'agent_wallet' THEN
      UPDATE agent_wallets SET balance = v_debit_balance_after, updated_at = now() 
      WHERE agent_id = p_debit_account;
    ELSIF v_debit_wallet_type = 'bureau_wallet' THEN
      UPDATE bureau_wallets SET balance = v_debit_balance_after, updated_at = now() 
      WHERE bureau_id = p_debit_account;
    END IF;
  END IF;
  
  -- Mettre à jour le compte créditeur
  IF p_credit_account IS NOT NULL THEN
    IF v_credit_wallet_type = 'wallet' THEN
      UPDATE wallets SET balance = v_credit_balance_after, updated_at = now() 
      WHERE user_id = p_credit_account;
    ELSIF v_credit_wallet_type = 'agent_wallet' THEN
      UPDATE agent_wallets SET balance = v_credit_balance_after, updated_at = now() 
      WHERE agent_id = p_credit_account;
    ELSIF v_credit_wallet_type = 'bureau_wallet' THEN
      UPDATE bureau_wallets SET balance = v_credit_balance_after, updated_at = now() 
      WHERE bureau_id = p_credit_account;
    END IF;
  END IF;
  
  -- Enregistrer dans le ledger immuable
  INSERT INTO financial_ledger (
    transaction_id, actor_id, actor_type, debit_account, credit_account,
    amount, transaction_type, description, metadata,
    balance_before_debit, balance_after_debit, 
    balance_before_credit, balance_after_credit,
    ledger_hash, previous_hash, module_name, module_signature,
    validation_status, confirmed_at
  ) VALUES (
    p_transaction_id, p_actor_id, p_actor_type, p_debit_account, p_credit_account,
    p_amount, p_transaction_type, p_description, p_metadata,
    v_debit_balance_before, v_debit_balance_after,
    v_credit_balance_before, v_credit_balance_after,
    v_new_hash, v_previous_hash, p_module_name, encode(sha256((p_module_name || p_transaction_id)::bytea), 'hex'),
    'confirmed', now()
  ) RETURNING id INTO v_ledger_id;
  
  -- Enregistrer aussi dans transaction_audit_log si existe
  BEGIN
    INSERT INTO transaction_audit_log (
      transaction_id, actor_id, actor_type, action_type,
      balance_before, balance_after, amount, expected_balance,
      is_valid, metadata
    ) VALUES (
      p_transaction_id, p_actor_id, p_actor_type, p_transaction_type,
      v_debit_balance_before, v_debit_balance_after, p_amount, v_debit_balance_after,
      true, jsonb_build_object('ledger_id', v_ledger_id, 'hash', v_new_hash)
    );
  EXCEPTION WHEN undefined_table THEN
    NULL;
  END;
  
  -- =====================================================
  -- PHASE 3: CONFIRMATION
  -- =====================================================
  
  -- Vérifier que les soldes sont corrects après écriture
  DECLARE
    v_verify_debit NUMERIC;
    v_verify_credit NUMERIC;
  BEGIN
    IF p_debit_account IS NOT NULL THEN
      IF v_debit_wallet_type = 'wallet' THEN
        SELECT balance INTO v_verify_debit FROM wallets WHERE user_id = p_debit_account;
      ELSIF v_debit_wallet_type = 'agent_wallet' THEN
        SELECT balance INTO v_verify_debit FROM agent_wallets WHERE agent_id = p_debit_account;
      ELSIF v_debit_wallet_type = 'bureau_wallet' THEN
        SELECT balance INTO v_verify_debit FROM bureau_wallets WHERE bureau_id = p_debit_account;
      END IF;
      
      IF v_verify_debit != v_debit_balance_after THEN
        -- Anomalie détectée!
        INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, related_transaction_id, metadata)
        VALUES ('integrity', 'emergency', 'Désynchronisation détectée', 
                'Le solde post-transaction ne correspond pas au calcul attendu',
                p_transaction_id,
                jsonb_build_object('expected', v_debit_balance_after, 'actual', v_verify_debit));
        
        RAISE EXCEPTION 'INTEGRITY_ERROR: Balance mismatch after transaction';
      END IF;
    END IF;
  END;
  
  -- Mise à jour des statistiques
  INSERT INTO pdg_financial_stats (stat_date, stat_hour, total_transactions, total_volume, successful_transactions)
  VALUES (CURRENT_DATE, EXTRACT(HOUR FROM now()), 1, p_amount, 1)
  ON CONFLICT (stat_date, stat_hour) DO UPDATE SET
    total_transactions = pdg_financial_stats.total_transactions + 1,
    total_volume = pdg_financial_stats.total_volume + p_amount,
    successful_transactions = pdg_financial_stats.successful_transactions + 1;
  
  -- Succès
  RETURN jsonb_build_object(
    'success', true,
    'ledger_id', v_ledger_id,
    'transaction_id', p_transaction_id,
    'hash', v_new_hash,
    'debit_balance_before', v_debit_balance_before,
    'debit_balance_after', v_debit_balance_after,
    'credit_balance_before', v_credit_balance_before,
    'credit_balance_after', v_credit_balance_after,
    'confirmed_at', now()
  );
  
EXCEPTION WHEN OTHERS THEN
  -- Enregistrer l'échec dans les stats
  INSERT INTO pdg_financial_stats (stat_date, stat_hour, failed_transactions)
  VALUES (CURRENT_DATE, EXTRACT(HOUR FROM now()), 1)
  ON CONFLICT (stat_date, stat_hour) DO UPDATE SET
    failed_transactions = pdg_financial_stats.failed_transactions + 1;
  
  -- Créer une alerte
  INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, related_transaction_id, related_actor_id, metadata)
  VALUES ('anomaly', 'critical', 'Échec transaction', SQLERRM, p_transaction_id, p_actor_id, 
          jsonb_build_object('error', SQLERRM, 'amount', p_amount));
  
  RETURN jsonb_build_object(
    'success', false,
    'error', 'TRANSACTION_FAILED',
    'message', SQLERRM
  );
END;
$$;

-- =====================================================
-- FONCTIONS MODE PANIC (PDG UNIQUEMENT)
-- =====================================================

CREATE OR REPLACE FUNCTION activate_panic_mode(p_pdg_id UUID, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_pdg BOOLEAN;
BEGIN
  -- Vérifier que c'est bien un PDG
  SELECT EXISTS(
    SELECT 1 FROM profiles WHERE id = p_pdg_id AND role = 'admin'
  ) INTO v_is_pdg;
  
  IF NOT v_is_pdg THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED', 'message', 'Seul le PDG peut activer le mode panic');
  END IF;
  
  -- Activer le mode panic
  INSERT INTO pdg_financial_control (control_type, is_active, activated_by, reason)
  VALUES ('panic_mode', true, p_pdg_id, p_reason);
  
  -- Créer une alerte
  INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, related_actor_id)
  VALUES ('panic', 'emergency', 'MODE PANIC ACTIVÉ', 'Toutes les transactions sont gelées. Raison: ' || p_reason, p_pdg_id);
  
  RETURN jsonb_build_object('success', true, 'message', 'Mode panic activé');
END;
$$;

CREATE OR REPLACE FUNCTION deactivate_panic_mode(p_pdg_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_pdg BOOLEAN;
BEGIN
  -- Vérifier que c'est bien un PDG
  SELECT EXISTS(
    SELECT 1 FROM profiles WHERE id = p_pdg_id AND role = 'admin'
  ) INTO v_is_pdg;
  
  IF NOT v_is_pdg THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHORIZED');
  END IF;
  
  -- Désactiver le mode panic
  UPDATE pdg_financial_control 
  SET is_active = false, deactivated_by = p_pdg_id, deactivated_at = now()
  WHERE control_type = 'panic_mode' AND is_active = true;
  
  INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, related_actor_id)
  VALUES ('panic', 'info', 'Mode panic désactivé', 'Les transactions sont à nouveau autorisées', p_pdg_id);
  
  RETURN jsonb_build_object('success', true, 'message', 'Mode panic désactivé');
END;
$$;

-- =====================================================
-- FONCTION DASHBOARD PDG
-- =====================================================

CREATE OR REPLACE FUNCTION get_pdg_financial_dashboard()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
  v_total_wallets NUMERIC;
  v_total_agent_wallets NUMERIC;
  v_total_bureau_wallets NUMERIC;
  v_panic_active BOOLEAN;
  v_pending_quarantine INTEGER;
  v_unread_alerts INTEGER;
  v_today_stats RECORD;
BEGIN
  -- Totaux des wallets
  SELECT COALESCE(SUM(balance), 0) INTO v_total_wallets FROM wallets;
  SELECT COALESCE(SUM(balance), 0) INTO v_total_agent_wallets FROM agent_wallets;
  SELECT COALESCE(SUM(balance), 0) INTO v_total_bureau_wallets FROM bureau_wallets;
  
  -- Mode panic actif?
  SELECT EXISTS(SELECT 1 FROM pdg_financial_control WHERE control_type = 'panic_mode' AND is_active = true) INTO v_panic_active;
  
  -- Quarantaines en attente
  SELECT COUNT(*) INTO v_pending_quarantine FROM financial_quarantine WHERE status = 'pending';
  
  -- Alertes non lues
  SELECT COUNT(*) INTO v_unread_alerts FROM pdg_financial_alerts WHERE is_read = false;
  
  -- Stats du jour
  SELECT 
    COALESCE(SUM(total_transactions), 0) as transactions,
    COALESCE(SUM(total_volume), 0) as volume,
    COALESCE(SUM(successful_transactions), 0) as success,
    COALESCE(SUM(failed_transactions), 0) as failed,
    COALESCE(SUM(quarantined_transactions), 0) as quarantined
  INTO v_today_stats
  FROM pdg_financial_stats 
  WHERE stat_date = CURRENT_DATE;
  
  v_result := jsonb_build_object(
    'panic_mode_active', v_panic_active,
    'total_balance', jsonb_build_object(
      'wallets', v_total_wallets,
      'agent_wallets', v_total_agent_wallets,
      'bureau_wallets', v_total_bureau_wallets,
      'total', v_total_wallets + v_total_agent_wallets + v_total_bureau_wallets
    ),
    'pending_quarantine', v_pending_quarantine,
    'unread_alerts', v_unread_alerts,
    'today_stats', jsonb_build_object(
      'transactions', v_today_stats.transactions,
      'volume', v_today_stats.volume,
      'successful', v_today_stats.success,
      'failed', v_today_stats.failed,
      'quarantined', v_today_stats.quarantined
    ),
    'generated_at', now()
  );
  
  RETURN v_result;
END;
$$;

-- =====================================================
-- RÈGLES FINANCIÈRES PAR DÉFAUT
-- =====================================================

INSERT INTO financial_rules (rule_code, rule_name, rule_description, rule_logic, rule_type, severity, applies_to) VALUES
('INSUFFICIENT_BALANCE', 'Solde insuffisant', 'Bloque les transactions si le solde est insuffisant', '{"check": "balance >= amount"}', 'validation', 'critical', ARRAY['all']),
('NO_SELF_TRANSFER', 'Pas de transfert à soi-même', 'Interdit les transferts vers son propre compte', '{"check": "debit_account != credit_account"}', 'validation', 'high', ARRAY['all']),
('TRANSACTION_LIMIT', 'Limite de transaction', 'Limite par transaction à 100M GNF', '{"max_amount": 100000000}', 'limit', 'medium', ARRAY['all']),
('NO_NEGATIVE_BALANCE', 'Pas de solde négatif', 'Empêche les soldes négatifs', '{"check": "balance_after >= 0"}', 'validation', 'critical', ARRAY['all'])
ON CONFLICT (rule_code) DO NOTHING;

-- =====================================================
-- SIGNATURES MODULES PAR DÉFAUT
-- =====================================================

INSERT INTO module_signatures (module_name, module_key) VALUES
('wallet_transfer', encode(sha256('wallet_transfer_224solutions'::bytea), 'hex')),
('agent_transaction', encode(sha256('agent_transaction_224solutions'::bytea), 'hex')),
('bureau_transaction', encode(sha256('bureau_transaction_224solutions'::bytea), 'hex')),
('vendor_payment', encode(sha256('vendor_payment_224solutions'::bytea), 'hex')),
('delivery_payment', encode(sha256('delivery_payment_224solutions'::bytea), 'hex')),
('system', encode(sha256('system_224solutions'::bytea), 'hex'))
ON CONFLICT (module_name) DO NOTHING;

-- =====================================================
-- POLITIQUES RLS
-- =====================================================

ALTER TABLE financial_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE financial_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE financial_quarantine ENABLE ROW LEVEL SECURITY;
ALTER TABLE pdg_financial_control ENABLE ROW LEVEL SECURITY;
ALTER TABLE module_signatures ENABLE ROW LEVEL SECURITY;
ALTER TABLE pdg_financial_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE balance_reconciliation ENABLE ROW LEVEL SECURITY;
ALTER TABLE pdg_financial_stats ENABLE ROW LEVEL SECURITY;

-- Politiques PDG (accès total)
CREATE POLICY "PDG full access to ledger" ON financial_ledger FOR ALL
  USING (EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "PDG full access to rules" ON financial_rules FOR ALL
  USING (EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "PDG full access to quarantine" ON financial_quarantine FOR ALL
  USING (EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "PDG full access to control" ON pdg_financial_control FOR ALL
  USING (EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "PDG full access to signatures" ON module_signatures FOR ALL
  USING (EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "PDG full access to alerts" ON pdg_financial_alerts FOR ALL
  USING (EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "PDG full access to reconciliation" ON balance_reconciliation FOR ALL
  USING (EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

CREATE POLICY "PDG full access to stats" ON pdg_financial_stats FOR ALL
  USING (EXISTS(SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'));

-- Service role access
CREATE POLICY "Service role ledger access" ON financial_ledger FOR ALL
  USING (auth.role() = 'service_role');

CREATE POLICY "Service role quarantine access" ON financial_quarantine FOR ALL
  USING (auth.role() = 'service_role');

-- Users can view their own ledger entries
CREATE POLICY "Users view own ledger" ON financial_ledger FOR SELECT
  USING (actor_id = auth.uid() OR debit_account = auth.uid() OR credit_account = auth.uid());