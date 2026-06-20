-- ============================================================
-- 🔐 SECURE FINANCIAL TRANSACTIONS SYSTEM
-- Règles de sécurité financières absolues - Montants immuables
-- ============================================================

-- Table des transactions sécurisées (immuables après création)
CREATE TABLE IF NOT EXISTS public.secure_transactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL,
  
  -- Montants calculés par le backend UNIQUEMENT
  requested_amount NUMERIC(15,2) NOT NULL,  -- Montant demandé par l'utilisateur
  fee_percentage NUMERIC(5,4) NOT NULL DEFAULT 0.025,  -- 2.5%
  fee_amount NUMERIC(15,2) NOT NULL,  -- Frais calculés
  total_amount NUMERIC(15,2) NOT NULL,  -- Montant total à payer
  net_amount NUMERIC(15,2) NOT NULL,  -- Montant net crédité
  
  -- Signature de sécurité (HMAC-SHA256)
  signature_hash TEXT NOT NULL,  -- Signature immuable
  signature_verified BOOLEAN DEFAULT false,
  
  -- Type et contexte
  transaction_type TEXT NOT NULL CHECK (transaction_type IN ('deposit', 'payment', 'withdrawal', 'transfer')),
  interface_type TEXT NOT NULL CHECK (interface_type IN ('client', 'vendor', 'driver', 'delivery')),
  
  -- Statut strict
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'rejected', 'blocked')),
  rejection_reason TEXT,
  
  -- Référence paiement externe
  external_transaction_id TEXT,
  payment_provider TEXT DEFAULT 'djomy',
  payment_method TEXT,
  
  -- Montant réellement payé (pour validation)
  amount_paid NUMERIC(15,2),
  
  -- Audit complet
  ip_address INET,
  user_agent TEXT,
  device_fingerprint TEXT,
  
  -- Timestamps immuables
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  validated_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  
  -- Contraintes d'intégrité
  CONSTRAINT positive_amounts CHECK (
    requested_amount > 0 AND 
    fee_amount >= 0 AND 
    total_amount > 0 AND 
    net_amount > 0
  ),
  CONSTRAINT valid_fee_calculation CHECK (
    ABS(fee_amount - (requested_amount * fee_percentage)) < 0.01 AND
    ABS(total_amount - (requested_amount + fee_amount)) < 0.01 AND
    ABS(net_amount - requested_amount) < 0.01
  )
);

-- Index pour recherches rapides
CREATE INDEX IF NOT EXISTS idx_secure_transactions_user ON public.secure_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_secure_transactions_status ON public.secure_transactions(status);
CREATE INDEX IF NOT EXISTS idx_secure_transactions_external ON public.secure_transactions(external_transaction_id);
CREATE INDEX IF NOT EXISTS idx_secure_transactions_created ON public.secure_transactions(created_at DESC);

-- RLS
ALTER TABLE public.secure_transactions ENABLE ROW LEVEL SECURITY;

-- Les utilisateurs ne peuvent voir que leurs propres transactions
CREATE POLICY "users_view_own_transactions" ON public.secure_transactions
  FOR SELECT USING (auth.uid() = user_id);

-- AUCUNE insertion/modification directe autorisée - uniquement via fonctions serveur
-- Les utilisateurs NE PEUVENT PAS modifier les transactions directement


-- ============================================================
-- 🔐 TABLE DES LOGS D'AUDIT FINANCIER (INALTÉRABLE)
-- ============================================================

CREATE TABLE IF NOT EXISTS public.financial_audit_logs (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  transaction_id UUID REFERENCES public.secure_transactions(id),
  
  -- Contexte
  user_id UUID NOT NULL,
  action_type TEXT NOT NULL,  -- 'create', 'validate', 'complete', 'reject', 'block', 'attempt'
  
  -- Détails
  description TEXT NOT NULL,
  old_status TEXT,
  new_status TEXT,
  
  -- Données complètes
  request_data JSONB,
  response_data JSONB,
  
  -- Audit
  ip_address INET,
  user_agent TEXT,
  device_info JSONB,
  
  -- Signature de l'entrée d'audit
  audit_hash TEXT,
  
  -- Timestamp inaltérable
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  
  -- Drapeaux de sécurité
  is_suspicious BOOLEAN DEFAULT false,
  security_flags TEXT[]
);

-- Index
CREATE INDEX IF NOT EXISTS idx_financial_audit_user ON public.financial_audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_financial_audit_transaction ON public.financial_audit_logs(transaction_id);
CREATE INDEX IF NOT EXISTS idx_financial_audit_action ON public.financial_audit_logs(action_type);
CREATE INDEX IF NOT EXISTS idx_financial_audit_created ON public.financial_audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_financial_audit_suspicious ON public.financial_audit_logs(is_suspicious) WHERE is_suspicious = true;

-- RLS strict
ALTER TABLE public.financial_audit_logs ENABLE ROW LEVEL SECURITY;

-- Lecture seule pour les utilisateurs (leurs propres logs)
CREATE POLICY "users_view_own_audit_logs" ON public.financial_audit_logs
  FOR SELECT USING (auth.uid() = user_id);


-- ============================================================
-- 🔐 TABLE DES ALERTES DE SÉCURITÉ FINANCIÈRE
-- ============================================================

CREATE TABLE IF NOT EXISTS public.financial_security_alerts (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  transaction_id UUID REFERENCES public.secure_transactions(id),
  user_id UUID NOT NULL,
  
  alert_type TEXT NOT NULL,  -- 'amount_mismatch', 'signature_invalid', 'duplicate_attempt', 'modification_attempt'
  severity TEXT NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  
  -- Données suspectes
  expected_value TEXT,
  received_value TEXT,
  
  -- Contexte
  ip_address INET,
  user_agent TEXT,
  metadata JSONB,
  
  -- Traitement
  is_resolved BOOLEAN DEFAULT false,
  resolved_at TIMESTAMPTZ,
  resolved_by UUID,
  resolution_notes TEXT,
  
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index
CREATE INDEX IF NOT EXISTS idx_security_alerts_user ON public.financial_security_alerts(user_id);
CREATE INDEX IF NOT EXISTS idx_security_alerts_severity ON public.financial_security_alerts(severity);
CREATE INDEX IF NOT EXISTS idx_security_alerts_unresolved ON public.financial_security_alerts(is_resolved) WHERE is_resolved = false;

-- RLS
ALTER TABLE public.financial_security_alerts ENABLE ROW LEVEL SECURITY;

-- Les utilisateurs ne peuvent pas voir les alertes de sécurité
-- Seuls les admins/PDG y ont accès via service role


-- ============================================================
-- 🔐 DRAPEAUX DE SÉCURITÉ UTILISATEUR
-- ============================================================

CREATE TABLE IF NOT EXISTS public.user_security_flags (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL UNIQUE,
  
  -- Drapeaux
  is_flagged BOOLEAN DEFAULT false,
  flag_reason TEXT,
  flagged_at TIMESTAMPTZ,
  
  -- Compteurs
  failed_payment_count INTEGER DEFAULT 0,
  modification_attempt_count INTEGER DEFAULT 0,
  suspicious_activity_count INTEGER DEFAULT 0,
  
  -- Blocage
  is_blocked BOOLEAN DEFAULT false,
  blocked_at TIMESTAMPTZ,
  blocked_reason TEXT,
  blocked_until TIMESTAMPTZ,
  
  -- Métadonnées
  last_activity_at TIMESTAMPTZ DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index
CREATE INDEX IF NOT EXISTS idx_user_security_flagged ON public.user_security_flags(is_flagged) WHERE is_flagged = true;
CREATE INDEX IF NOT EXISTS idx_user_security_blocked ON public.user_security_flags(is_blocked) WHERE is_blocked = true;

-- RLS
ALTER TABLE public.user_security_flags ENABLE ROW LEVEL SECURITY;

-- Les utilisateurs ne peuvent voir que leur propre statut (lecture seule)
CREATE POLICY "users_view_own_security_status" ON public.user_security_flags
  FOR SELECT USING (auth.uid() = user_id);


-- ============================================================
-- 🔐 FONCTION: Créer une transaction sécurisée (BACKEND ONLY)
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_secure_transaction(
  p_user_id UUID,
  p_requested_amount NUMERIC,
  p_transaction_type TEXT,
  p_interface_type TEXT,
  p_payment_method TEXT DEFAULT NULL,
  p_ip_address INET DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL,
  p_device_fingerprint TEXT DEFAULT NULL,
  p_secret_key TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fee_percentage NUMERIC := 0.025;  -- 2.5%
  v_fee_amount NUMERIC;
  v_total_amount NUMERIC;
  v_net_amount NUMERIC;
  v_signature_hash TEXT;
  v_transaction_id UUID;
  v_user_blocked BOOLEAN;
BEGIN
  -- 🔐 Vérifier si l'utilisateur est bloqué
  SELECT is_blocked INTO v_user_blocked
  FROM public.user_security_flags
  WHERE user_id = p_user_id;
  
  IF v_user_blocked = true THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'USER_BLOCKED',
      'message', 'Compte bloqué pour raisons de sécurité'
    );
  END IF;

  -- 🔐 Calculer les frais (BACKEND UNIQUEMENT)
  v_fee_amount := ROUND(p_requested_amount * v_fee_percentage, 2);
  v_total_amount := p_requested_amount + v_fee_amount;
  v_net_amount := p_requested_amount;

  -- 🔐 Générer l'ID de transaction
  v_transaction_id := gen_random_uuid();

  -- 🔐 Générer la signature HMAC-SHA256
  -- Format: transaction_id + total_amount + secret_key
  v_signature_hash := encode(
    hmac(
      v_transaction_id::text || v_total_amount::text,
      COALESCE(p_secret_key, current_setting('app.settings.transaction_secret', true), 'secure-default-key'),
      'sha256'
    ),
    'hex'
  );

  -- 🔐 Créer la transaction (IMMUABLE après création)
  INSERT INTO public.secure_transactions (
    id,
    user_id,
    requested_amount,
    fee_percentage,
    fee_amount,
    total_amount,
    net_amount,
    signature_hash,
    transaction_type,
    interface_type,
    payment_method,
    status,
    ip_address,
    user_agent,
    device_fingerprint
  ) VALUES (
    v_transaction_id,
    p_user_id,
    p_requested_amount,
    v_fee_percentage,
    v_fee_amount,
    v_total_amount,
    v_net_amount,
    v_signature_hash,
    p_transaction_type,
    p_interface_type,
    p_payment_method,
    'pending',
    p_ip_address,
    p_user_agent,
    p_device_fingerprint
  );

  -- 🔐 Log d'audit
  INSERT INTO public.financial_audit_logs (
    transaction_id,
    user_id,
    action_type,
    description,
    new_status,
    request_data,
    ip_address,
    user_agent
  ) VALUES (
    v_transaction_id,
    p_user_id,
    'create',
    'Transaction créée - Montant: ' || v_total_amount || ' GNF',
    'pending',
    jsonb_build_object(
      'requested_amount', p_requested_amount,
      'fee_amount', v_fee_amount,
      'total_amount', v_total_amount,
      'net_amount', v_net_amount,
      'interface', p_interface_type,
      'payment_method', p_payment_method
    ),
    p_ip_address,
    p_user_agent
  );

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'requested_amount', p_requested_amount,
    'fee_amount', v_fee_amount,
    'total_amount', v_total_amount,
    'net_amount', v_net_amount,
    'signature', v_signature_hash,
    'status', 'pending'
  );
END;
$$;


-- ============================================================
-- 🔐 FONCTION: Valider le paiement (SERVEUR-À-SERVEUR)
-- ============================================================

CREATE OR REPLACE FUNCTION public.validate_secure_payment(
  p_transaction_id UUID,
  p_external_transaction_id TEXT,
  p_amount_paid NUMERIC,
  p_payment_status TEXT,
  p_signature TEXT,
  p_secret_key TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_transaction RECORD;
  v_expected_signature TEXT;
  v_user_id UUID;
  v_wallet_id UUID;
  v_current_balance NUMERIC;
  v_new_balance NUMERIC;
BEGIN
  -- 🔐 Récupérer la transaction
  SELECT * INTO v_transaction
  FROM public.secure_transactions
  WHERE id = p_transaction_id;

  IF v_transaction IS NULL THEN
    -- Log tentative avec ID invalide
    INSERT INTO public.financial_audit_logs (user_id, action_type, description, request_data, is_suspicious, security_flags)
    VALUES (
      '00000000-0000-0000-0000-000000000000'::UUID,
      'attempt',
      'Tentative validation avec ID transaction invalide',
      jsonb_build_object('transaction_id', p_transaction_id),
      true,
      ARRAY['invalid_transaction_id']
    );
    
    RETURN jsonb_build_object('success', false, 'error', 'TRANSACTION_NOT_FOUND');
  END IF;

  v_user_id := v_transaction.user_id;

  -- 🔐 Vérifier que la transaction est en pending
  IF v_transaction.status != 'pending' THEN
    INSERT INTO public.financial_audit_logs (transaction_id, user_id, action_type, description, old_status, is_suspicious, security_flags)
    VALUES (p_transaction_id, v_user_id, 'attempt', 'Tentative validation transaction non-pending', v_transaction.status, true, ARRAY['invalid_status']);
    
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_TRANSACTION_STATUS', 'current_status', v_transaction.status);
  END IF;

  -- 🔐 Calculer la signature attendue
  v_expected_signature := encode(
    hmac(
      p_transaction_id::text || v_transaction.total_amount::text,
      COALESCE(p_secret_key, current_setting('app.settings.transaction_secret', true), 'secure-default-key'),
      'sha256'
    ),
    'hex'
  );

  -- 🔐 RÈGLE 1: Vérifier la signature API
  IF p_signature IS NULL OR p_signature != v_expected_signature THEN
    -- Créer alerte sécurité
    INSERT INTO public.financial_security_alerts (transaction_id, user_id, alert_type, severity, title, description, expected_value, received_value)
    VALUES (p_transaction_id, v_user_id, 'signature_invalid', 'critical', 'Signature API invalide', 'Tentative de validation avec signature incorrecte', v_expected_signature, p_signature);
    
    -- Incrémenter compteur de tentatives suspectes
    INSERT INTO public.user_security_flags (user_id, suspicious_activity_count, is_flagged, flag_reason, flagged_at)
    VALUES (v_user_id, 1, true, 'Signature API invalide', now())
    ON CONFLICT (user_id) DO UPDATE SET
      suspicious_activity_count = user_security_flags.suspicious_activity_count + 1,
      is_flagged = true,
      flag_reason = 'Signature API invalide',
      flagged_at = now();
    
    -- Log
    INSERT INTO public.financial_audit_logs (transaction_id, user_id, action_type, description, is_suspicious, security_flags)
    VALUES (p_transaction_id, v_user_id, 'reject', 'SIGNATURE INVALIDE - Paiement REFUSÉ', true, ARRAY['invalid_signature']);
    
    -- Rejeter la transaction
    UPDATE public.secure_transactions SET status = 'rejected', rejection_reason = 'INVALID_SIGNATURE', failed_at = now() WHERE id = p_transaction_id;
    
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_SIGNATURE', 'message', 'Paiement REFUSÉ - Signature invalide');
  END IF;

  -- 🔐 RÈGLE 2: Vérifier le statut du paiement
  IF p_payment_status != 'SUCCESS' AND p_payment_status != 'completed' THEN
    -- Incrémenter compteur échecs
    INSERT INTO public.user_security_flags (user_id, failed_payment_count)
    VALUES (v_user_id, 1)
    ON CONFLICT (user_id) DO UPDATE SET failed_payment_count = user_security_flags.failed_payment_count + 1;
    
    -- Log
    INSERT INTO public.financial_audit_logs (transaction_id, user_id, action_type, description, new_status)
    VALUES (p_transaction_id, v_user_id, 'reject', 'Paiement échoué: ' || p_payment_status, 'failed');
    
    UPDATE public.secure_transactions SET status = 'failed', rejection_reason = 'PAYMENT_' || UPPER(p_payment_status), failed_at = now(), external_transaction_id = p_external_transaction_id WHERE id = p_transaction_id;
    
    RETURN jsonb_build_object('success', false, 'error', 'PAYMENT_FAILED', 'status', p_payment_status);
  END IF;

  -- 🔐 RÈGLE 3: Vérifier le montant payé (EXACT)
  IF p_amount_paid IS NULL OR ABS(p_amount_paid - v_transaction.total_amount) > 0.01 THEN
    -- Créer alerte critique
    INSERT INTO public.financial_security_alerts (transaction_id, user_id, alert_type, severity, title, description, expected_value, received_value)
    VALUES (p_transaction_id, v_user_id, 'amount_mismatch', 'critical', 'Montant payé différent', 'Le montant payé ne correspond pas au montant attendu', v_transaction.total_amount::text, COALESCE(p_amount_paid::text, 'NULL'));
    
    -- Log
    INSERT INTO public.financial_audit_logs (transaction_id, user_id, action_type, description, is_suspicious, security_flags, request_data)
    VALUES (p_transaction_id, v_user_id, 'reject', 'MONTANT DIFFÉRENT - Attendu: ' || v_transaction.total_amount || ', Reçu: ' || COALESCE(p_amount_paid::text, 'NULL'), true, ARRAY['amount_mismatch'], jsonb_build_object('expected', v_transaction.total_amount, 'received', p_amount_paid));
    
    UPDATE public.secure_transactions SET status = 'rejected', rejection_reason = 'AMOUNT_MISMATCH', failed_at = now(), amount_paid = p_amount_paid WHERE id = p_transaction_id;
    
    RETURN jsonb_build_object('success', false, 'error', 'AMOUNT_MISMATCH', 'expected', v_transaction.total_amount, 'received', p_amount_paid);
  END IF;

  -- 🔐 TOUTES LES VALIDATIONS PASSÉES - Créditer le compte
  
  -- Récupérer le wallet
  SELECT id, balance INTO v_wallet_id, v_current_balance
  FROM public.wallets
  WHERE user_id = v_user_id;
  
  IF v_wallet_id IS NULL THEN
    -- Créer le wallet s'il n'existe pas
    INSERT INTO public.wallets (user_id, balance, currency)
    VALUES (v_user_id, 0, 'GNF')
    RETURNING id, balance INTO v_wallet_id, v_current_balance;
  END IF;

  -- Calculer nouveau solde (net_amount seulement, pas le total!)
  v_new_balance := v_current_balance + v_transaction.net_amount;

  -- Mettre à jour le wallet
  UPDATE public.wallets SET balance = v_new_balance, updated_at = now() WHERE id = v_wallet_id;

  -- Marquer la transaction comme complétée
  UPDATE public.secure_transactions SET
    status = 'completed',
    signature_verified = true,
    external_transaction_id = p_external_transaction_id,
    amount_paid = p_amount_paid,
    validated_at = now(),
    completed_at = now()
  WHERE id = p_transaction_id;

  -- Créer transaction wallet
  INSERT INTO public.wallet_transactions (wallet_id, user_id, type, amount, description, status, reference, metadata)
  VALUES (
    v_wallet_id,
    v_user_id,
    'deposit',
    v_transaction.net_amount,
    'Recharge sécurisée via ' || COALESCE(v_transaction.payment_method, 'Jomy'),
    'completed',
    p_external_transaction_id,
    jsonb_build_object(
      'secure_transaction_id', p_transaction_id,
      'fee_amount', v_transaction.fee_amount,
      'total_paid', v_transaction.total_amount,
      'signature_verified', true
    )
  );

  -- Log succès
  INSERT INTO public.financial_audit_logs (transaction_id, user_id, action_type, description, old_status, new_status, request_data)
  VALUES (
    p_transaction_id,
    v_user_id,
    'complete',
    'Paiement validé et crédité - Net: ' || v_transaction.net_amount || ' GNF',
    'pending',
    'completed',
    jsonb_build_object(
      'old_balance', v_current_balance,
      'new_balance', v_new_balance,
      'net_credited', v_transaction.net_amount,
      'fee_collected', v_transaction.fee_amount
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'transaction_id', p_transaction_id,
    'status', 'completed',
    'net_credited', v_transaction.net_amount,
    'new_balance', v_new_balance,
    'message', 'Paiement validé avec succès'
  );
END;
$$;


-- ============================================================
-- 🔐 TRIGGER: Empêcher modification des transactions
-- ============================================================

CREATE OR REPLACE FUNCTION public.prevent_transaction_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Seules les transitions de status autorisées par les fonctions serveur
  IF OLD.status IN ('completed', 'failed', 'rejected', 'blocked') THEN
    RAISE EXCEPTION 'SECURITY_VIOLATION: Transaction % is immutable (status: %)', OLD.id, OLD.status;
  END IF;
  
  -- Vérifier qu'on ne modifie pas les montants
  IF OLD.requested_amount != NEW.requested_amount OR
     OLD.fee_amount != NEW.fee_amount OR
     OLD.total_amount != NEW.total_amount OR
     OLD.net_amount != NEW.net_amount OR
     OLD.signature_hash != NEW.signature_hash THEN
    
    -- Créer alerte de sécurité
    INSERT INTO public.financial_security_alerts (transaction_id, user_id, alert_type, severity, title, description, metadata)
    VALUES (OLD.id, OLD.user_id, 'modification_attempt', 'critical', 'Tentative de modification de montant', 
            'Tentative de modifier les montants d''une transaction existante',
            jsonb_build_object('old', row_to_json(OLD), 'new', row_to_json(NEW)));
    
    -- Incrémenter compteur et potentiellement bloquer
    INSERT INTO public.user_security_flags (user_id, modification_attempt_count, is_blocked, blocked_at, blocked_reason)
    VALUES (OLD.user_id, 1, true, now(), 'Tentative de modification de transaction')
    ON CONFLICT (user_id) DO UPDATE SET
      modification_attempt_count = user_security_flags.modification_attempt_count + 1,
      is_blocked = true,
      blocked_at = now(),
      blocked_reason = 'Tentative de modification de transaction';
    
    RAISE EXCEPTION 'SECURITY_VIOLATION: Modification of transaction amounts is FORBIDDEN';
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_prevent_transaction_modification ON public.secure_transactions;
CREATE TRIGGER trigger_prevent_transaction_modification
  BEFORE UPDATE ON public.secure_transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_transaction_modification();


-- ============================================================
-- 🔐 TRIGGER: Empêcher suppression des transactions
-- ============================================================

CREATE OR REPLACE FUNCTION public.prevent_transaction_deletion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Créer alerte
  INSERT INTO public.financial_security_alerts (transaction_id, user_id, alert_type, severity, title, description)
  VALUES (OLD.id, OLD.user_id, 'deletion_attempt', 'critical', 'Tentative de suppression de transaction', 'Suppression de transactions interdite');
  
  RAISE EXCEPTION 'SECURITY_VIOLATION: Deletion of transactions is FORBIDDEN';
END;
$$;

DROP TRIGGER IF EXISTS trigger_prevent_transaction_deletion ON public.secure_transactions;
CREATE TRIGGER trigger_prevent_transaction_deletion
  BEFORE DELETE ON public.secure_transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_transaction_deletion();


-- ============================================================
-- 🔐 TRIGGER: Empêcher modification des logs d'audit
-- ============================================================

CREATE OR REPLACE FUNCTION public.prevent_audit_modification()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'SECURITY_VIOLATION: Audit logs are IMMUTABLE and cannot be modified or deleted';
END;
$$;

DROP TRIGGER IF EXISTS trigger_prevent_audit_update ON public.financial_audit_logs;
CREATE TRIGGER trigger_prevent_audit_update
  BEFORE UPDATE ON public.financial_audit_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_audit_modification();

DROP TRIGGER IF EXISTS trigger_prevent_audit_delete ON public.financial_audit_logs;
CREATE TRIGGER trigger_prevent_audit_delete
  BEFORE DELETE ON public.financial_audit_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_audit_modification();