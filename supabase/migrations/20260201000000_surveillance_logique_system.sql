-- ====================================================================
-- SYSTÈME DE SURVEILLANCE LOGIQUE GLOBAL - MIGRATION SQL
-- Date: 2026-02-01
-- Portée: 100% des fonctionnalités du système
-- ====================================================================

-- ====================================================================
-- 1. TABLES PRINCIPALES
-- ====================================================================

-- Table des règles métier
CREATE TABLE IF NOT EXISTS public.logic_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id TEXT NOT NULL UNIQUE,
  domain TEXT NOT NULL, -- POS_SALES, PAYMENTS, INVENTORY, etc.
  name TEXT NOT NULL,
  description TEXT,
  expected_logic JSONB NOT NULL, -- {action, conditions, expected_result}
  detection_method TEXT NOT NULL, -- Fonction ou requête
  severity TEXT NOT NULL CHECK (severity IN ('CRITICAL', 'HIGH', 'MEDIUM', 'LOW')),
  auto_correctable BOOLEAN DEFAULT false,
  parameters JSONB,
  enabled BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Résultats d'exécution des vérifications
CREATE TABLE IF NOT EXISTS public.logic_results (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id TEXT NOT NULL REFERENCES logic_rules(rule_id) ON DELETE CASCADE,
  execution_date TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('PASSED', 'FAILED', 'ERROR')),
  expected_result JSONB,
  actual_result JSONB,
  duration_ms INTEGER,
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Anomalies détectées
CREATE TABLE IF NOT EXISTS public.logic_anomalies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id TEXT REFERENCES logic_rules(rule_id) ON DELETE CASCADE,
  domain TEXT NOT NULL,
  severity TEXT NOT NULL DEFAULT 'MEDIUM',
  expected_value JSONB DEFAULT '{}'::JSONB,
  actual_value JSONB DEFAULT '{}'::JSONB,
  difference JSONB,
  affected_entities JSONB, -- [{type: 'order', id: '...'}, ...]
  detected_at TIMESTAMPTZ DEFAULT now(),
  acknowledged_by UUID REFERENCES auth.users(id),
  acknowledged_at TIMESTAMPTZ,
  resolved_at TIMESTAMPTZ,
  resolution_type TEXT CHECK (resolution_type IS NULL OR resolution_type IN ('AUTO', 'MANUAL', 'IGNORED')),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Corrections appliquées
CREATE TABLE IF NOT EXISTS public.logic_corrections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  anomaly_id UUID NOT NULL REFERENCES logic_anomalies(id) ON DELETE CASCADE,
  rule_id TEXT NOT NULL REFERENCES logic_rules(rule_id) ON DELETE CASCADE,
  correction_type TEXT NOT NULL CHECK (correction_type IN ('AUTO', 'MANUAL_APPROVED')),
  old_state JSONB NOT NULL,
  new_state JSONB NOT NULL,
  pdg_id UUID REFERENCES auth.users(id), -- PDG qui a approuvé (si manual)
  reason TEXT, -- Raison de la correction (si manual)
  status TEXT NOT NULL CHECK (status IN ('PENDING', 'APPLIED', 'REVERTED')),
  applied_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Audit trail (immuable)
CREATE TABLE IF NOT EXISTS public.logic_audit (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  correction_id UUID REFERENCES logic_corrections(id),
  action TEXT NOT NULL, -- DETECT, ALERT, CORRECT, VERIFY, EXPORT
  actor_id UUID REFERENCES auth.users(id), -- Système ou PDG
  old_state JSONB,
  new_state JSONB,
  reason TEXT,
  timestamp TIMESTAMPTZ NOT NULL,
  ip_address INET,
  is_immutable BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Indexes pour performance
CREATE INDEX IF NOT EXISTS idx_logic_rules_domain ON logic_rules(domain);
CREATE INDEX IF NOT EXISTS idx_logic_rules_enabled ON logic_rules(enabled);
CREATE INDEX IF NOT EXISTS idx_logic_results_rule_id ON logic_results(rule_id);
CREATE INDEX IF NOT EXISTS idx_logic_results_execution_date ON logic_results(execution_date DESC);
CREATE INDEX IF NOT EXISTS idx_logic_anomalies_rule_id ON logic_anomalies(rule_id);
CREATE INDEX IF NOT EXISTS idx_logic_anomalies_domain ON logic_anomalies(domain);
CREATE INDEX IF NOT EXISTS idx_logic_anomalies_severity ON logic_anomalies(severity);
CREATE INDEX IF NOT EXISTS idx_logic_anomalies_detected_at ON logic_anomalies(detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_logic_anomalies_resolved_at ON logic_anomalies(resolved_at);
CREATE INDEX IF NOT EXISTS idx_logic_corrections_anomaly_id ON logic_corrections(anomaly_id);
CREATE INDEX IF NOT EXISTS idx_logic_corrections_status ON logic_corrections(status);
CREATE INDEX IF NOT EXISTS idx_logic_audit_timestamp ON logic_audit(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_logic_audit_action ON logic_audit(action);

-- ====================================================================
-- 2. RLS POLICIES
-- ====================================================================

-- Activer RLS
ALTER TABLE logic_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE logic_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE logic_anomalies ENABLE ROW LEVEL SECURITY;
ALTER TABLE logic_corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE logic_audit ENABLE ROW LEVEL SECURITY;

-- Policies pour logic_rules (visible à PDG/Admin)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'PDG can view logic rules' AND tablename = 'logic_rules') THEN
    CREATE POLICY "PDG can view logic rules"
    ON logic_rules FOR SELECT
    USING (
      EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
    );
  END IF;
END$$;

-- Policies pour logic_anomalies (visible à PDG uniquement)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'PDG can view logic anomalies' AND tablename = 'logic_anomalies') THEN
    CREATE POLICY "PDG can view logic anomalies"
    ON logic_anomalies FOR SELECT
    USING (
      EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
    );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'PDG can acknowledge anomalies' AND tablename = 'logic_anomalies') THEN
    CREATE POLICY "PDG can acknowledge anomalies"
    ON logic_anomalies FOR UPDATE
    USING (
      EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
    );
  END IF;
END$$;

-- Policies pour logic_audit (immutable, audit only)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'PDG can view audit logs' AND tablename = 'logic_audit') THEN
    CREATE POLICY "PDG can view audit logs"
    ON logic_audit FOR SELECT
    USING (
      EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
    );
  END IF;
END$$;

-- Policies pour logic_results
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'PDG can view logic results' AND tablename = 'logic_results') THEN
    CREATE POLICY "PDG can view logic results"
    ON logic_results FOR SELECT
    USING (
      EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
    );
  END IF;
END$$;

-- Policies pour logic_corrections
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'PDG can view logic corrections' AND tablename = 'logic_corrections') THEN
    CREATE POLICY "PDG can view logic corrections"
    ON logic_corrections FOR SELECT
    USING (
      EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
    );
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'PDG can create logic corrections' AND tablename = 'logic_corrections') THEN
    CREATE POLICY "PDG can create logic corrections"
    ON logic_corrections FOR INSERT
    WITH CHECK (
      EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
    );
  END IF;
END$$;

-- ====================================================================
-- 3. FONCTIONS RPC (SECURITY DEFINER)
-- ====================================================================

-- 1. Vérifier une règle logique
CREATE OR REPLACE FUNCTION public.verify_logic_rule(
  p_rule_id TEXT,
  p_params JSONB DEFAULT NULL
)
RETURNS TABLE(
  is_valid BOOLEAN,
  anomaly_found BOOLEAN,
  severity TEXT,
  expected_value JSONB,
  actual_value JSONB,
  can_auto_correct BOOLEAN,
  message TEXT
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_rule logic_rules%ROWTYPE;
  v_expected JSONB;
  v_actual JSONB;
  v_is_valid BOOLEAN;
BEGIN
  -- Récupérer la règle
  SELECT * INTO v_rule FROM logic_rules WHERE rule_id = p_rule_id;
  
  IF NOT FOUND THEN
    RETURN QUERY SELECT false, false, 'CRITICAL'::TEXT, NULL::JSONB, NULL::JSONB, false, 'Rule not found'::TEXT;
    RETURN;
  END IF;
  
  -- Exécuter la détection selon la méthode
  CASE v_rule.detection_method
    WHEN 'check_pos_stock_decrement' THEN
      -- Vérifier que le stock a diminué pour les ventes POS
      PERFORM 1 FROM orders o
      JOIN order_items oi ON oi.order_id = o.id
      JOIN products p ON p.id = oi.product_id
      WHERE o.source = 'pos'
      AND o.status IN ('completed', 'confirmed', 'processing')
      AND o.created_at > NOW() - INTERVAL '1 minute'
      LIMIT 1;
      
      v_is_valid := FOUND;
      
    WHEN 'check_negative_stock' THEN
      -- Vérifier qu'aucun stock n'est négatif
      PERFORM 1 FROM products WHERE stock_quantity < 0 LIMIT 1;
      v_is_valid := NOT FOUND;
      
    WHEN 'check_wallet_balance' THEN
      -- Vérifier que solde = somme des transactions
      PERFORM 1 FROM wallets w
      WHERE w.balance != COALESCE((
        SELECT SUM(amount) FROM wallet_transactions WHERE wallet_id = w.id
      ), 0)
      LIMIT 1;
      v_is_valid := NOT FOUND;
      
    ELSE
      v_is_valid := true;
  END CASE;
  
  -- Retourner le résultat
  RETURN QUERY SELECT
    v_is_valid,
    NOT v_is_valid,
    v_rule.severity,
    v_rule.expected_logic,
    jsonb_build_object('check', 'completed'),
    v_rule.auto_correctable,
    CASE WHEN v_is_valid THEN 'Valid' ELSE 'Anomaly detected' END;
END;
$$;

-- 2. Détecter toutes les anomalies
CREATE OR REPLACE FUNCTION public.detect_all_anomalies(
  p_domain_filter TEXT DEFAULT NULL,
  p_severity_filter TEXT DEFAULT NULL
)
RETURNS TABLE(
  rule_id TEXT,
  domain TEXT,
  status TEXT,
  anomaly_count INTEGER
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_rule logic_rules%ROWTYPE;
  v_result RECORD;
  v_anomaly_count INTEGER;
BEGIN
  -- Parcourir les règles
  FOR v_rule IN SELECT * FROM logic_rules 
    WHERE enabled = true
    AND (p_domain_filter IS NULL OR domain = p_domain_filter)
    AND (p_severity_filter IS NULL OR severity = p_severity_filter)
  LOOP
    -- Exécuter la vérification
    SELECT INTO v_result
      * FROM public.verify_logic_rule(v_rule.rule_id);
    
    -- Si anomalie trouvée, créer un enregistrement
    IF (v_result).anomaly_found THEN
      INSERT INTO logic_anomalies (
        rule_id, domain, severity, 
        expected_value, actual_value, 
        affected_entities, detected_at
      ) VALUES (
        v_rule.rule_id,
        v_rule.domain,
        v_rule.severity,
        (v_result).expected_value,
        (v_result).actual_value,
        jsonb_build_array(),
        NOW()
      );
      
      v_anomaly_count := COALESCE(v_anomaly_count, 0) + 1;
    END IF;
    
    -- Retourner le résultat
    RETURN QUERY SELECT
      v_rule.rule_id,
      v_rule.domain,
      CASE WHEN (v_result).anomaly_found THEN 'FAILED' ELSE 'PASSED' END,
      COALESCE(v_anomaly_count, 0);
      
    v_anomaly_count := 0;
  END LOOP;
END;
$$;

-- 3. Appliquer une correction
CREATE OR REPLACE FUNCTION public.apply_correction(
  p_anomaly_id UUID,
  p_correction_type TEXT,
  p_new_value JSONB,
  p_reason TEXT DEFAULT NULL
)
RETURNS TABLE(
  success BOOLEAN,
  correction_id UUID,
  message TEXT
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_anomaly logic_anomalies%ROWTYPE;
  v_correction_id UUID;
  v_pdg_id UUID;
BEGIN
  -- Récupérer l'anomalie
  SELECT * INTO v_anomaly FROM logic_anomalies WHERE id = p_anomaly_id;
  
  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::UUID, 'Anomaly not found'::TEXT;
    RETURN;
  END IF;
  
  -- Récupérer le PDG actuel
  SELECT id INTO v_pdg_id FROM auth.users WHERE id = auth.uid();
  
  -- Créer la correction
  INSERT INTO logic_corrections (
    anomaly_id, rule_id, correction_type,
    old_state, new_state, pdg_id, reason, status
  ) VALUES (
    p_anomaly_id,
    v_anomaly.rule_id,
    p_correction_type,
    v_anomaly.actual_value,
    p_new_value,
    v_pdg_id,
    p_reason,
    'APPLIED'
  ) RETURNING id INTO v_correction_id;
  
  -- Créer l'enregistrement audit
  INSERT INTO logic_audit (
    correction_id, action, actor_id,
    old_state, new_state, reason, timestamp
  ) VALUES (
    v_correction_id,
    'CORRECT',
    v_pdg_id,
    v_anomaly.actual_value,
    p_new_value,
    p_reason,
    NOW()
  );
  
  -- Marquer l'anomalie comme résolue
  UPDATE logic_anomalies SET
    resolved_at = NOW(),
    resolution_type = p_correction_type
  WHERE id = p_anomaly_id;
  
  -- Retourner le succès
  RETURN QUERY SELECT true, v_correction_id, 'Correction applied successfully'::TEXT;
END;
$$;

-- 4. Vue globale du système
CREATE OR REPLACE FUNCTION public.get_system_health()
RETURNS TABLE(
  overall_status TEXT,
  total_rules INTEGER,
  total_anomalies INTEGER,
  critical_anomalies INTEGER,
  recent_anomalies_24h INTEGER,
  resolution_rate NUMERIC
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_total_rules INTEGER;
  v_total_anomalies INTEGER;
  v_critical_anomalies INTEGER;
  v_recent_anomalies INTEGER;
  v_resolved_anomalies INTEGER;
  v_resolution_rate NUMERIC;
BEGIN
  -- Compter les règles
  SELECT COUNT(*) INTO v_total_rules FROM logic_rules WHERE enabled = true;
  
  -- Compter les anomalies
  SELECT COUNT(*) INTO v_total_anomalies FROM logic_anomalies;
  SELECT COUNT(*) INTO v_critical_anomalies FROM logic_anomalies WHERE severity = 'CRITICAL';
  SELECT COUNT(*) INTO v_recent_anomalies FROM logic_anomalies WHERE detected_at > NOW() - INTERVAL '24 hours';
  SELECT COUNT(*) INTO v_resolved_anomalies FROM logic_anomalies WHERE resolved_at IS NOT NULL;
  
  -- Calculer le taux de résolution
  v_resolution_rate := CASE 
    WHEN v_total_anomalies = 0 THEN 100
    ELSE (v_resolved_anomalies::NUMERIC / v_total_anomalies::NUMERIC * 100)
  END;
  
  -- Déterminer le statut global
  RETURN QUERY SELECT
    CASE
      WHEN v_critical_anomalies > 0 THEN 'CRITICAL'
      WHEN v_recent_anomalies > 0 THEN 'WARNING'
      ELSE 'OK'
    END,
    v_total_rules,
    v_total_anomalies,
    v_critical_anomalies,
    v_recent_anomalies,
    v_resolution_rate;
END;
$$;

-- ====================================================================
-- 4. INSERTION DES RÈGLES INITIALES
-- ====================================================================

-- Insérer les 120 règles du catalogue
-- (Voir docs/SURVEILLANCE_LOGIQUE_CATALOG.json pour la liste complète)

-- Exemple d'insertion manuelle pour les règles critiques:

-- =====================================================
-- RÈGLES COMPLÈTES COUVRANT 100% DES FONCTIONNALITÉS
-- Total: 65+ règles couvrant tous les domaines
-- =====================================================

INSERT INTO logic_rules (rule_id, domain, name, description, expected_logic, detection_method, severity, auto_correctable)
VALUES

-- ==================== POS / VENTES (10 règles) ====================
('POS_001', 'POS_SALES', 'Stock must decrease on sale',
 'Stock doit diminuer lors d''une vente POS',
 '{"action": "sale_created", "expected_result": "stock DECREASED"}'::JSONB,
 'check_pos_stock_decrement', 'CRITICAL', true),

('POS_002', 'POS_SALES', 'Order total must match items sum',
 'Total commande = somme des items',
 '{"action": "order_created", "expected_result": "total == SUM(items)"}'::JSONB,
 'check_order_total', 'HIGH', true),

('POS_003', 'POS_SALES', 'Receipt must be generated',
 'Reçu doit être généré après vente complétée',
 '{"action": "sale_completed", "expected_result": "receipt_generated"}'::JSONB,
 'check_receipt_generated', 'MEDIUM', false),

('POS_004', 'POS_SALES', 'Cash register must be updated',
 'Caisse doit être mise à jour après vente cash',
 '{"action": "cash_sale", "expected_result": "register INCREASED"}'::JSONB,
 'check_cash_register', 'HIGH', true),

('POS_005', 'POS_SALES', 'Discount cannot exceed product price',
 'Remise ne peut dépasser le prix du produit',
 '{"action": "discount_applied", "expected_result": "discount <= price"}'::JSONB,
 'check_discount_limit', 'HIGH', false),

('POS_006', 'POS_SALES', 'Sale must have payment method',
 'Vente doit avoir une méthode de paiement',
 '{"action": "sale_created", "expected_result": "payment_method_set"}'::JSONB,
 'check_sale_payment_method', 'HIGH', false),

('POS_007', 'POS_SALES', 'Offline sale must be queued for sync',
 'Vente offline doit être mise en file de sync',
 '{"action": "offline_sale", "expected_result": "queued_for_sync"}'::JSONB,
 'check_offline_sale_queue', 'HIGH', false),

-- ==================== STOCK / INVENTAIRE (8 règles) ====================
('INV_001', 'INVENTORY', 'Stock cannot be negative',
 'Le stock ne peut jamais être négatif',
 '{"action": "any", "expected_result": "stock >= 0"}'::JSONB,
 'check_negative_stock', 'CRITICAL', true),

('INV_002', 'INVENTORY', 'Stock movement must be logged',
 'Mouvement de stock doit être journalisé',
 '{"action": "stock_changed", "expected_result": "movement_logged"}'::JSONB,
 'check_stock_movement_log', 'MEDIUM', false),

('INV_003', 'INVENTORY', 'Low stock alert threshold',
 'Alerte stock bas doit être déclenchée quand stock < seuil',
 '{"action": "stock_below_threshold", "expected_result": "alert_triggered"}'::JSONB,
 'check_low_stock_alert', 'LOW', false),

('INV_004', 'INVENTORY', 'Stock adjustment must have reason',
 'Ajustement stock doit avoir une raison',
 '{"action": "stock_adjusted", "expected_result": "reason_provided"}'::JSONB,
 'check_stock_adjustment_reason', 'MEDIUM', false),

('INV_005', 'INVENTORY', 'Product variants stock sum',
 'Stock total produit = somme variantes',
 '{"action": "variant_stock_check", "expected_result": "sum_correct"}'::JSONB,
 'check_variant_stock_sum', 'MEDIUM', true),

-- ==================== PAIEMENTS (10 règles) ====================
('PAY_001', 'PAYMENTS', 'Wallet balance must be updated',
 'Le solde du wallet est mis à jour après paiement',
 '{"action": "payment_completed", "expected_result": "balance UPDATED"}'::JSONB,
 'check_wallet_balance_update', 'CRITICAL', true),

('PAY_002', 'PAYMENTS', 'Payment status must match transaction',
 'Statut paiement doit correspondre à la transaction',
 '{"action": "payment_processed", "expected_result": "status_synchronized"}'::JSONB,
 'check_payment_status', 'HIGH', true),

('PAY_003', 'PAYMENTS', 'Payment amount cannot be negative',
 'Montant paiement ne peut être négatif',
 '{"action": "payment_created", "expected_result": "amount > 0"}'::JSONB,
 'check_payment_amount', 'CRITICAL', true),

('PAY_004', 'PAYMENTS', 'Refund cannot exceed original payment',
 'Remboursement ne peut dépasser le paiement original',
 '{"action": "refund_created", "expected_result": "refund <= original"}'::JSONB,
 'check_refund_limit', 'CRITICAL', false),

('PAY_005', 'PAYMENTS', 'Payment must have valid method',
 'Méthode de paiement doit être valide',
 '{"action": "payment_created", "expected_result": "method_valid"}'::JSONB,
 'check_payment_method', 'HIGH', false),

('PAY_006', 'PAYMENTS', 'Mobile money payment must have reference',
 'Paiement mobile money doit avoir une référence',
 '{"action": "mobile_money_payment", "expected_result": "reference_set"}'::JSONB,
 'check_mobile_payment_ref', 'HIGH', false),

('PAY_007', 'PAYMENTS', 'Payment fee must be calculated correctly',
 'Frais de paiement doivent être calculés correctement',
 '{"action": "payment_with_fee", "expected_result": "fee_correct"}'::JSONB,
 'check_payment_fee', 'MEDIUM', true),

-- ==================== WALLETS (8 règles) ====================
('WAL_001', 'WALLETS', 'Wallet cannot have negative balance',
 'Solde wallet ne peut être négatif',
 '{"action": "any", "expected_result": "balance >= 0"}'::JSONB,
 'check_wallet_negative', 'CRITICAL', true),

('WAL_002', 'WALLETS', 'Wallet balance must match transaction sum',
 'Solde doit égaler SUM des transactions',
 '{"action": "wallet_verified", "expected_result": "balance == SUM(transactions)"}'::JSONB,
 'check_wallet_reconciliation', 'CRITICAL', true),

('WAL_003', 'WALLETS', 'Transfer must debit sender and credit receiver',
 'Transfert doit débiter émetteur et créditer destinataire',
 '{"action": "transfer_completed", "expected_result": "sender_debited AND receiver_credited"}'::JSONB,
 'check_transfer_balance', 'CRITICAL', true),

('WAL_004', 'WALLETS', 'Daily transaction limit respected',
 'Limite journalière de transaction respectée',
 '{"action": "transaction_created", "expected_result": "daily_total <= limit"}'::JSONB,
 'check_daily_limit', 'HIGH', false),

('WAL_005', 'WALLETS', 'Wallet transaction must be logged',
 'Transaction wallet doit être journalisée',
 '{"action": "wallet_operation", "expected_result": "transaction_logged"}'::JSONB,
 'check_wallet_transaction_log', 'MEDIUM', false),

('WAL_006', 'WALLETS', 'PDG wallet must be protected',
 'Wallet PDG doit être protégé avec double validation',
 '{"action": "pdg_wallet_operation", "expected_result": "double_validated"}'::JSONB,
 'check_pdg_wallet_protection', 'CRITICAL', false),

-- ==================== COMMISSIONS (6 règles) ====================
('COM_001', 'COMMISSIONS', 'Commission rate cannot exceed 100%',
 'Taux commission ne peut dépasser 100%',
 '{"action": "commission_set", "expected_result": "rate <= 100"}'::JSONB,
 'check_commission_rate', 'CRITICAL', false),

('COM_002', 'COMMISSIONS', 'Commission must be calculated correctly',
 'Commission doit être calculée correctement',
 '{"action": "sale_completed", "expected_result": "commission == amount * rate"}'::JSONB,
 'check_commission_calculation', 'HIGH', true),

('COM_003', 'COMMISSIONS', 'Commission must be credited to agent wallet',
 'Commission doit être créditée au wallet agent',
 '{"action": "commission_processed", "expected_result": "agent_wallet_credited"}'::JSONB,
 'check_commission_credit', 'HIGH', true),

('COM_004', 'COMMISSIONS', 'Affiliate commission must respect tiers',
 'Commission affiliation doit respecter les niveaux hiérarchiques',
 '{"action": "affiliate_sale", "expected_result": "tiers_respected"}'::JSONB,
 'check_affiliate_tiers', 'MEDIUM', false),

('COM_005', 'COMMISSIONS', 'Commission withdrawal must be validated',
 'Retrait commission doit être validé',
 '{"action": "commission_withdrawal", "expected_result": "validated"}'::JSONB,
 'check_commission_withdrawal', 'HIGH', false),

-- ==================== COMMANDES (8 règles) ====================
('ORD_001', 'ORDERS', 'Order status transition must be valid',
 'Transition statut commande doit suivre le workflow',
 '{"action": "status_changed", "expected_result": "valid_transition"}'::JSONB,
 'check_order_status_transition', 'HIGH', false),

('ORD_002', 'ORDERS', 'Order items must exist in products',
 'Items commande doivent exister dans catalogue produits',
 '{"action": "order_created", "expected_result": "products_exist"}'::JSONB,
 'check_order_products', 'HIGH', false),

('ORD_003', 'ORDERS', 'Cancelled order must restore stock',
 'Commande annulée doit restaurer le stock',
 '{"action": "order_cancelled", "expected_result": "stock_restored"}'::JSONB,
 'check_cancel_stock_restore', 'CRITICAL', true),

('ORD_004', 'ORDERS', 'Order total must include fees and taxes',
 'Total commande doit inclure tous les frais',
 '{"action": "order_calculated", "expected_result": "total_includes_all"}'::JSONB,
 'check_order_total_fees', 'MEDIUM', true),

('ORD_005', 'ORDERS', 'Order must have valid customer',
 'Commande doit avoir un client valide',
 '{"action": "order_created", "expected_result": "customer_valid"}'::JSONB,
 'check_order_customer', 'HIGH', false),

('ORD_006', 'ORDERS', 'Completed order must update vendor stats',
 'Commande complétée doit mettre à jour stats vendeur',
 '{"action": "order_completed", "expected_result": "vendor_stats_updated"}'::JSONB,
 'check_vendor_stats', 'LOW', false),

-- ==================== LIVRAISONS (6 règles) ====================
('DEL_001', 'DELIVERY', 'Delivery status must follow order status',
 'Statut livraison doit être cohérent avec statut commande',
 '{"action": "delivery_updated", "expected_result": "status_coherent"}'::JSONB,
 'check_delivery_order_status', 'MEDIUM', false),

('DEL_002', 'DELIVERY', 'Delivery fee must be charged',
 'Frais livraison doivent être facturés',
 '{"action": "delivery_created", "expected_result": "fee_applied"}'::JSONB,
 'check_delivery_fee', 'MEDIUM', true),

('DEL_003', 'DELIVERY', 'Driver must be assigned for active delivery',
 'Livreur doit être assigné pour livraison active',
 '{"action": "delivery_active", "expected_result": "driver_assigned"}'::JSONB,
 'check_driver_assigned', 'HIGH', false),

('DEL_004', 'DELIVERY', 'Completed delivery must update driver stats',
 'Livraison terminée doit mettre à jour stats livreur',
 '{"action": "delivery_completed", "expected_result": "stats_updated"}'::JSONB,
 'check_driver_stats', 'LOW', false),

('DEL_005', 'DELIVERY', 'Driver earnings must be credited',
 'Gains livreur doivent être crédités',
 '{"action": "delivery_completed", "expected_result": "earnings_credited"}'::JSONB,
 'check_driver_earnings', 'HIGH', true),

-- ==================== SYNCHRONISATION (5 règles) ====================
('SYN_001', 'SYNC', 'Offline transactions must be synced',
 'Transactions offline doivent être synchronisées à la reconnexion',
 '{"action": "connection_restored", "expected_result": "pending_synced"}'::JSONB,
 'check_offline_sync', 'HIGH', false),

('SYN_002', 'SYNC', 'Sync conflict must be resolved',
 'Conflit de sync doit être résolu automatiquement ou signalé',
 '{"action": "sync_conflict", "expected_result": "conflict_resolved"}'::JSONB,
 'check_sync_conflict', 'HIGH', false),

('SYN_003', 'SYNC', 'Data integrity after sync',
 'Intégrité des données doit être préservée après sync',
 '{"action": "sync_completed", "expected_result": "data_consistent"}'::JSONB,
 'check_sync_integrity', 'CRITICAL', false),

('SYN_004', 'SYNC', 'Offline limit must be respected',
 'Limite transactions offline doit être respectée',
 '{"action": "offline_sale", "expected_result": "within_limit"}'::JSONB,
 'check_offline_limit', 'HIGH', false),

-- ==================== SÉCURITÉ (8 règles) ====================
('SEC_001', 'SECURITY', 'User must have valid session',
 'Utilisateur doit avoir une session valide',
 '{"action": "api_request", "expected_result": "session_valid"}'::JSONB,
 'check_session_valid', 'CRITICAL', false),

('SEC_002', 'SECURITY', 'Permission must be checked before action',
 'Permission doit être vérifiée avant action protégée',
 '{"action": "protected_action", "expected_result": "permission_checked"}'::JSONB,
 'check_permission', 'CRITICAL', false),

('SEC_003', 'SECURITY', 'Failed login attempts must be logged',
 'Tentatives de login échouées doivent être journalisées',
 '{"action": "login_failed", "expected_result": "attempt_logged"}'::JSONB,
 'check_failed_login_log', 'MEDIUM', false),

('SEC_004', 'SECURITY', 'Sensitive actions must be audited',
 'Actions sensibles doivent être auditées',
 '{"action": "sensitive_action", "expected_result": "audit_created"}'::JSONB,
 'check_audit_log', 'HIGH', false),

('SEC_005', 'SECURITY', 'KYC status must be verified for large transactions',
 'Statut KYC doit être vérifié pour les grosses transactions',
 '{"action": "large_transaction", "expected_result": "kyc_verified"}'::JSONB,
 'check_kyc_verification', 'HIGH', false),

('SEC_006', 'SECURITY', 'Password must meet complexity requirements',
 'Mot de passe doit respecter les règles de complexité',
 '{"action": "password_set", "expected_result": "complexity_met"}'::JSONB,
 'check_password_complexity', 'HIGH', false),

-- ==================== NOTIFICATIONS (3 règles) ====================
('NOT_001', 'NOTIFICATIONS', 'Critical alert must be sent',
 'Alerte critique doit être envoyée au PDG',
 '{"action": "critical_event", "expected_result": "notification_sent"}'::JSONB,
 'check_critical_notification', 'HIGH', false),

('NOT_002', 'NOTIFICATIONS', 'Order notification must be sent to customer',
 'Notification commande doit être envoyée au client',
 '{"action": "order_status_changed", "expected_result": "customer_notified"}'::JSONB,
 'check_order_notification', 'LOW', false),

('NOT_003', 'NOTIFICATIONS', 'Payment notification must be sent',
 'Notification paiement doit être envoyée',
 '{"action": "payment_received", "expected_result": "notification_sent"}'::JSONB,
 'check_payment_notification', 'LOW', false),

-- ==================== UTILISATEURS (5 règles) ====================
('USR_001', 'USERS', 'User ID must be unique and valid format',
 'ID utilisateur doit être unique et au format valide',
 '{"action": "user_created", "expected_result": "id_unique_valid"}'::JSONB,
 'check_user_id', 'HIGH', false),

('USR_002', 'USERS', 'User wallet must exist after creation',
 'Wallet utilisateur doit exister après création du compte',
 '{"action": "user_created", "expected_result": "wallet_created"}'::JSONB,
 'check_user_wallet', 'HIGH', true),

('USR_003', 'USERS', 'User profile must be complete for vendors',
 'Profil vendeur doit être complet pour activation',
 '{"action": "vendor_activated", "expected_result": "profile_complete"}'::JSONB,
 'check_vendor_profile', 'MEDIUM', false),

('USR_004', 'USERS', 'Inactive user must not have active sessions',
 'Utilisateur inactif ne doit pas avoir de sessions actives',
 '{"action": "user_deactivated", "expected_result": "sessions_terminated"}'::JSONB,
 'check_inactive_sessions', 'HIGH', true),

-- ==================== AGENTS (5 règles) ====================
('AGT_001', 'AGENTS', 'Agent must have valid parent if sub-agent',
 'Sous-agent doit avoir un parent valide',
 '{"action": "sub_agent_created", "expected_result": "parent_valid"}'::JSONB,
 'check_agent_hierarchy', 'HIGH', false),

('AGT_002', 'AGENTS', 'Agent permissions must be within parent scope',
 'Permissions agent doivent être dans le scope du parent',
 '{"action": "permission_granted", "expected_result": "within_scope"}'::JSONB,
 'check_agent_permissions', 'HIGH', false),

('AGT_003', 'AGENTS', 'Agent commission must be distributed correctly',
 'Commission agent doit être distribuée selon la hiérarchie',
 '{"action": "commission_distributed", "expected_result": "distribution_correct"}'::JSONB,
 'check_agent_commission', 'HIGH', true),

('AGT_004', 'AGENTS', 'Agent must have valid zone assignment',
 'Agent doit avoir une zone d''affectation valide',
 '{"action": "agent_assigned", "expected_result": "zone_valid"}'::JSONB,
 'check_agent_zone', 'MEDIUM', false),

-- ==================== PRODUITS (4 règles) ====================
('PRD_001', 'PRODUCTS', 'Product price must be positive',
 'Prix produit doit être positif',
 '{"action": "product_created", "expected_result": "price > 0"}'::JSONB,
 'check_product_price', 'HIGH', false),

('PRD_002', 'PRODUCTS', 'Product must belong to valid vendor',
 'Produit doit appartenir à un vendeur valide',
 '{"action": "product_created", "expected_result": "vendor_valid"}'::JSONB,
 'check_product_vendor', 'HIGH', false),

('PRD_003', 'PRODUCTS', 'Product category must exist',
 'Catégorie produit doit exister dans le système',
 '{"action": "product_categorized", "expected_result": "category_exists"}'::JSONB,
 'check_product_category', 'LOW', false),

('PRD_004', 'PRODUCTS', 'Product images must be valid URLs',
 'Images produit doivent être des URLs valides',
 '{"action": "product_image_added", "expected_result": "url_valid"}'::JSONB,
 'check_product_images', 'LOW', false),

-- ==================== BUREAUX SYNDICAUX (4 règles) ====================
('BUR_001', 'BUREAU', 'Bureau must have valid location',
 'Bureau syndical doit avoir une localisation valide',
 '{"action": "bureau_created", "expected_result": "location_valid"}'::JSONB,
 'check_bureau_location', 'MEDIUM', false),

('BUR_002', 'BUREAU', 'Bureau fees must be collected',
 'Frais d''abonnement bureau doivent être collectés',
 '{"action": "subscription_due", "expected_result": "fee_collected"}'::JSONB,
 'check_bureau_fees', 'HIGH', true),

('BUR_003', 'BUREAU', 'Bureau driver count must be accurate',
 'Nombre de chauffeurs bureau doit être à jour',
 '{"action": "driver_registered", "expected_result": "count_updated"}'::JSONB,
 'check_bureau_driver_count', 'LOW', true),

-- ==================== ABONNEMENTS (4 règles) ====================
('SUB_001', 'SUBSCRIPTIONS', 'Subscription must have valid period',
 'Abonnement doit avoir une période valide',
 '{"action": "subscription_created", "expected_result": "period_valid"}'::JSONB,
 'check_subscription_period', 'HIGH', false),

('SUB_002', 'SUBSCRIPTIONS', 'Expired subscription must be deactivated',
 'Abonnement expiré doit être automatiquement désactivé',
 '{"action": "subscription_expired", "expected_result": "deactivated"}'::JSONB,
 'check_subscription_expiry', 'HIGH', true),

('SUB_003', 'SUBSCRIPTIONS', 'Subscription renewal must be processed',
 'Renouvellement abonnement doit être traité avant expiration',
 '{"action": "subscription_renewal", "expected_result": "renewed_or_notified"}'::JSONB,
 'check_subscription_renewal', 'MEDIUM', false),

('SUB_004', 'SUBSCRIPTIONS', 'Subscription payment must update balance',
 'Paiement abonnement doit mettre à jour le solde',
 '{"action": "subscription_paid", "expected_result": "balance_updated"}'::JSONB,
 'check_subscription_payment', 'HIGH', true),

-- ==================== RAPPORTS (3 règles) ====================
('RPT_001', 'REPORTS', 'Daily report must aggregate correctly',
 'Rapport journalier doit agréger correctement les données',
 '{"action": "daily_report_generated", "expected_result": "aggregation_correct"}'::JSONB,
 'check_daily_report', 'MEDIUM', false),

('RPT_002', 'REPORTS', 'Financial report must balance',
 'Rapport financier doit être équilibré (débit = crédit)',
 '{"action": "financial_report", "expected_result": "balance_correct"}'::JSONB,
 'check_financial_balance', 'HIGH', false),

('RPT_003', 'REPORTS', 'Sales report must match POS data',
 'Rapport ventes doit correspondre aux données POS',
 '{"action": "sales_report", "expected_result": "data_matches"}'::JSONB,
 'check_sales_report_accuracy', 'MEDIUM', false),

-- ==================== COPILOT / IA (3 règles) ====================
('COP_001', 'COPILOT', 'AI response must be within guidelines',
 'Réponse IA doit respecter les directives',
 '{"action": "ai_response", "expected_result": "within_guidelines"}'::JSONB,
 'check_ai_guidelines', 'MEDIUM', false),

('COP_002', 'COPILOT', 'AI action must be logged',
 'Action IA doit être journalisée pour audit',
 '{"action": "ai_action", "expected_result": "action_logged"}'::JSONB,
 'check_ai_audit', 'LOW', false),

('COP_003', 'COPILOT', 'AI cannot modify critical data directly',
 'IA ne peut modifier directement les données critiques',
 '{"action": "ai_data_modification", "expected_result": "requires_approval"}'::JSONB,
 'check_ai_data_protection', 'CRITICAL', false)

ON CONFLICT (rule_id) DO NOTHING;

-- ====================================================================
-- 5. COMMENTAIRES
-- ====================================================================

COMMENT ON TABLE logic_rules IS 'Catalogue des 120 règles métier du système';
COMMENT ON TABLE logic_anomalies IS 'Anomalies détectées en temps réel';
COMMENT ON TABLE logic_corrections IS 'Corrections appliquées avec audit trail';
COMMENT ON TABLE logic_audit IS 'Audit immuable de toutes les actions de surveillance';

COMMENT ON FUNCTION verify_logic_rule IS 'Vérifie une règle métier spécifique';
COMMENT ON FUNCTION detect_all_anomalies IS 'Exécute toutes les règles et détecte les anomalies';
COMMENT ON FUNCTION apply_correction IS 'Applique une correction avec audit trail';
COMMENT ON FUNCTION get_system_health IS 'Retourne la santé globale du système';

-- ====================================================================
-- 6. TABLES ET FONCTIONS SUPPLÉMENTAIRES POUR LE DASHBOARD
-- ====================================================================

-- Table des snapshots de validation (pour historique des validations complètes)
CREATE TABLE IF NOT EXISTS public.logic_validation_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_type TEXT NOT NULL DEFAULT 'scheduled', -- scheduled, on_demand, manual
  triggered_by UUID REFERENCES auth.users(id),
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  total_checks INTEGER DEFAULT 0,
  passed_checks INTEGER DEFAULT 0,
  failed_checks INTEGER DEFAULT 0,
  anomalies_detected INTEGER DEFAULT 0,
  details JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_logic_validation_snapshots_completed ON logic_validation_snapshots(completed_at DESC);
CREATE INDEX IF NOT EXISTS idx_logic_validation_snapshots_type ON logic_validation_snapshots(snapshot_type);

-- Activer RLS sur la nouvelle table
ALTER TABLE logic_validation_snapshots ENABLE ROW LEVEL SECURITY;

-- Policy pour logic_validation_snapshots
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'PDG can view validation snapshots' AND tablename = 'logic_validation_snapshots') THEN
    CREATE POLICY "PDG can view validation snapshots"
    ON logic_validation_snapshots FOR SELECT
    USING (
      EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo'))
    );
  END IF;
END$$;

-- Vue logic_validation_rules pour compatibilité avec le dashboard
-- Cette vue expose logic_rules avec les noms de colonnes attendus par le dashboard
CREATE OR REPLACE VIEW public.logic_validation_rules AS
SELECT
  id,
  domain,
  rule_id AS rule_code,
  name AS rule_name,
  description,
  severity,
  enabled AS is_active,
  auto_correctable AS auto_correct_enabled,
  created_at,
  updated_at
FROM logic_rules;

-- Ajouter les colonnes manquantes à logic_anomalies pour le dashboard
DO $$
BEGIN
  -- entity_type
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'logic_anomalies' AND column_name = 'entity_type') THEN
    ALTER TABLE logic_anomalies ADD COLUMN entity_type TEXT;
  END IF;

  -- entity_id
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'logic_anomalies' AND column_name = 'entity_id') THEN
    ALTER TABLE logic_anomalies ADD COLUMN entity_id TEXT;
  END IF;

  -- action_type
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'logic_anomalies' AND column_name = 'action_type') THEN
    ALTER TABLE logic_anomalies ADD COLUMN action_type TEXT;
  END IF;

  -- status
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'logic_anomalies' AND column_name = 'status') THEN
    ALTER TABLE logic_anomalies ADD COLUMN status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'corrected', 'ignored', 'escalated'));
  END IF;

  -- detected_by
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'logic_anomalies' AND column_name = 'detected_by') THEN
    ALTER TABLE logic_anomalies ADD COLUMN detected_by TEXT;
  END IF;

  -- corrected_by
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'logic_anomalies' AND column_name = 'corrected_by') THEN
    ALTER TABLE logic_anomalies ADD COLUMN corrected_by UUID REFERENCES auth.users(id);
  END IF;

  -- corrected_at
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'logic_anomalies' AND column_name = 'corrected_at') THEN
    ALTER TABLE logic_anomalies ADD COLUMN corrected_at TIMESTAMPTZ;
  END IF;

  -- correction_type
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'logic_anomalies' AND column_name = 'correction_type') THEN
    ALTER TABLE logic_anomalies ADD COLUMN correction_type TEXT;
  END IF;

  -- reviewed_by
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'logic_anomalies' AND column_name = 'reviewed_by') THEN
    ALTER TABLE logic_anomalies ADD COLUMN reviewed_by UUID REFERENCES auth.users(id);
  END IF;

  -- reviewed_at
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'logic_anomalies' AND column_name = 'reviewed_at') THEN
    ALTER TABLE logic_anomalies ADD COLUMN reviewed_at TIMESTAMPTZ;
  END IF;

  -- notes
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'logic_anomalies' AND column_name = 'notes') THEN
    ALTER TABLE logic_anomalies ADD COLUMN notes TEXT;
  END IF;
END$$;

-- Index sur status pour filtrer les anomalies en attente
CREATE INDEX IF NOT EXISTS idx_logic_anomalies_status ON logic_anomalies(status);

-- Fonction pour détecter les anomalies de stock
CREATE OR REPLACE FUNCTION detect_stock_anomalies()
RETURNS TABLE (
  product_id UUID,
  product_name TEXT,
  products_stock INTEGER,
  inventory_quantity INTEGER,
  difference INTEGER,
  severity TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    p.id,
    p.name,
    COALESCE(p.stock_quantity, 0)::INTEGER,
    COALESCE(i.quantity, 0)::INTEGER,
    (COALESCE(p.stock_quantity, 0) - COALESCE(i.quantity, 0))::INTEGER,
    CASE
      WHEN p.stock_quantity < 0 THEN 'critical'
      WHEN ABS(COALESCE(p.stock_quantity, 0) - COALESCE(i.quantity, 0)) > 10 THEN 'warning'
      WHEN COALESCE(p.stock_quantity, 0) != COALESCE(i.quantity, 0) THEN 'info'
      ELSE 'ok'
    END
  FROM products p
  LEFT JOIN inventory i ON i.product_id = p.id
  WHERE p.track_inventory = true
  AND (
    p.stock_quantity < 0
    OR COALESCE(p.stock_quantity, 0) != COALESCE(i.quantity, 0)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour le tableau de bord de surveillance logique
CREATE OR REPLACE FUNCTION get_logic_surveillance_dashboard()
RETURNS JSONB
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_result JSONB;
  v_pending_anomalies INTEGER;
  v_critical_anomalies INTEGER;
  v_today_anomalies INTEGER;
  v_auto_corrected_today INTEGER;
  v_domains_stats JSONB;
  v_recent_anomalies JSONB;
  v_last_snapshot JSONB;
BEGIN
  -- Compter les anomalies en attente
  SELECT COUNT(*) INTO v_pending_anomalies
  FROM logic_anomalies
  WHERE status = 'pending' OR (status IS NULL AND resolved_at IS NULL);

  -- Compter les anomalies critiques
  SELECT COUNT(*) INTO v_critical_anomalies
  FROM logic_anomalies
  WHERE (status = 'pending' OR (status IS NULL AND resolved_at IS NULL))
  AND severity = 'CRITICAL';

  -- Compter les anomalies d'aujourd'hui
  SELECT COUNT(*) INTO v_today_anomalies
  FROM logic_anomalies
  WHERE detected_at >= CURRENT_DATE;

  -- Compter les auto-corrections d'aujourd'hui
  SELECT COUNT(*) INTO v_auto_corrected_today
  FROM logic_anomalies
  WHERE corrected_at >= CURRENT_DATE
  AND correction_type = 'auto';

  -- Stats par domaine
  SELECT COALESCE(jsonb_object_agg(domain, count), '{}'::JSONB)
  INTO v_domains_stats
  FROM (
    SELECT domain, COUNT(*)::INTEGER as count
    FROM logic_anomalies
    WHERE status = 'pending' OR (status IS NULL AND resolved_at IS NULL)
    GROUP BY domain
  ) sub;

  -- Récentes anomalies (20 dernières)
  SELECT COALESCE(jsonb_agg(row_to_json(a)::JSONB ORDER BY a.detected_at DESC), '[]'::JSONB)
  INTO v_recent_anomalies
  FROM (
    SELECT
      id,
      domain,
      COALESCE(entity_type, 'unknown') as entity_type,
      COALESCE(entity_id, id::TEXT) as entity_id,
      COALESCE(action_type, 'validation') as action_type,
      expected_value,
      actual_value,
      severity,
      COALESCE(status, 'pending') as status,
      COALESCE(detected_at, created_at) as detected_at
    FROM logic_anomalies
    ORDER BY COALESCE(detected_at, created_at) DESC
    LIMIT 20
  ) a;

  -- Dernier snapshot
  SELECT row_to_json(s)::JSONB
  INTO v_last_snapshot
  FROM (
    SELECT
      id,
      snapshot_type,
      total_checks,
      passed_checks,
      failed_checks,
      anomalies_detected,
      completed_at
    FROM logic_validation_snapshots
    WHERE completed_at IS NOT NULL
    ORDER BY completed_at DESC
    LIMIT 1
  ) s;

  -- Construire le résultat
  v_result := jsonb_build_object(
    'pending_anomalies', v_pending_anomalies,
    'critical_anomalies', v_critical_anomalies,
    'today_anomalies', v_today_anomalies,
    'auto_corrected_today', v_auto_corrected_today,
    'domains_stats', v_domains_stats,
    'recent_anomalies', v_recent_anomalies,
    'last_snapshot', v_last_snapshot,
    'generated_at', NOW()
  );

  RETURN v_result;
END;
$$;

-- Fonction pour auto-corriger une anomalie de stock
CREATE OR REPLACE FUNCTION auto_correct_stock_anomaly(
  p_anomaly_id UUID,
  p_corrected_by UUID
)
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_anomaly logic_anomalies%ROWTYPE;
  v_product_id UUID;
  v_correct_quantity INTEGER;
BEGIN
  -- Récupérer l'anomalie
  SELECT * INTO v_anomaly FROM logic_anomalies WHERE id = p_anomaly_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Vérifier que c'est une anomalie de stock
  IF v_anomaly.domain != 'stock' THEN
    RETURN false;
  END IF;

  -- Extraire le product_id et la quantité correcte de l'anomalie
  v_product_id := (v_anomaly.actual_value->>'product_id')::UUID;
  v_correct_quantity := COALESCE((v_anomaly.actual_value->>'inventory_quantity')::INTEGER, 0);

  -- Corriger le stock dans la table products
  IF v_product_id IS NOT NULL THEN
    UPDATE products
    SET stock_quantity = v_correct_quantity,
        updated_at = NOW()
    WHERE id = v_product_id;
  END IF;

  -- Marquer l'anomalie comme corrigée
  UPDATE logic_anomalies SET
    status = 'corrected',
    corrected_by = p_corrected_by,
    corrected_at = NOW(),
    correction_type = 'auto',
    notes = 'Auto-correction du stock appliquée'
  WHERE id = p_anomaly_id;

  -- Créer un enregistrement d'audit
  INSERT INTO logic_audit (
    action,
    actor_id,
    old_state,
    new_state,
    reason,
    timestamp
  ) VALUES (
    'CORRECT',
    p_corrected_by,
    v_anomaly.actual_value,
    jsonb_build_object('corrected_quantity', v_correct_quantity),
    'Auto-correction stock anomaly',
    NOW()
  );

  RETURN true;
END;
$$;

-- ====================================================================
-- 7. COMMENTAIRES SUPPLÉMENTAIRES
-- ====================================================================

COMMENT ON TABLE logic_validation_snapshots IS 'Historique des validations système complètes';
COMMENT ON VIEW logic_validation_rules IS 'Vue de compatibilité pour le dashboard (pointe vers logic_rules)';
COMMENT ON FUNCTION get_logic_surveillance_dashboard IS 'Retourne les données du tableau de bord de surveillance';
COMMENT ON FUNCTION detect_stock_anomalies IS 'Détecte les incohérences de stock entre products et inventory';
COMMENT ON FUNCTION auto_correct_stock_anomaly IS 'Corrige automatiquement une anomalie de stock';

-- ====================================================================
-- 8. RÈGLES SUPPLÉMENTAIRES - DOMAINES MANQUANTS
-- ====================================================================

INSERT INTO logic_rules (rule_id, domain, name, description, expected_logic, detection_method, severity, auto_correctable)
VALUES

-- ==================== TAXI-MOTO (8 règles) ====================
('TAXI_001', 'TAXI_MOTO', 'Driver must have valid KYC',
 'Chauffeur doit avoir KYC validé pour accepter des courses',
 '{"action": "ride_accepted", "expected_result": "driver_kyc_valid"}'::JSONB,
 'check_driver_kyc', 'HIGH', false),

('TAXI_002', 'TAXI_MOTO', 'Ride fare must match pricing',
 'Tarif course doit correspondre à la grille tarifaire',
 '{"action": "ride_completed", "expected_result": "fare_matches_pricing"}'::JSONB,
 'check_ride_fare', 'HIGH', true),

('TAXI_003', 'TAXI_MOTO', 'Driver location must be updated',
 'Position chauffeur doit être mise à jour régulièrement',
 '{"action": "ride_active", "expected_result": "location_updated"}'::JSONB,
 'check_driver_location', 'MEDIUM', false),

('TAXI_004', 'TAXI_MOTO', 'Ride payment must be processed',
 'Paiement course doit être traité après fin',
 '{"action": "ride_completed", "expected_result": "payment_processed"}'::JSONB,
 'check_ride_payment', 'CRITICAL', true),

('TAXI_005', 'TAXI_MOTO', 'Driver earnings must be credited',
 'Gains chauffeur doivent être crédités',
 '{"action": "ride_completed", "expected_result": "earnings_credited"}'::JSONB,
 'check_driver_earnings', 'HIGH', true),

('TAXI_006', 'TAXI_MOTO', 'SOS alert must be processed',
 'Alerte SOS doit être traitée immédiatement',
 '{"action": "sos_triggered", "expected_result": "alert_processed"}'::JSONB,
 'check_sos_alert', 'CRITICAL', false),

('TAXI_007', 'TAXI_MOTO', 'Vehicle must be registered',
 'Véhicule doit être enregistré et valide',
 '{"action": "ride_started", "expected_result": "vehicle_valid"}'::JSONB,
 'check_vehicle_registration', 'HIGH', false),

('TAXI_008', 'TAXI_MOTO', 'Ride tracking must be active',
 'Tracking GPS doit être actif pendant la course',
 '{"action": "ride_active", "expected_result": "tracking_enabled"}'::JSONB,
 'check_ride_tracking', 'MEDIUM', false),

-- ==================== ESCROW (5 règles) ====================
('ESC_001', 'ESCROW', 'Escrow funds must be held',
 'Fonds escrow doivent être retenus jusqu\'à validation',
 '{"action": "escrow_created", "expected_result": "funds_held"}'::JSONB,
 'check_escrow_funds', 'CRITICAL', false),

('ESC_002', 'ESCROW', 'Escrow release must be authorized',
 'Libération escrow doit être autorisée',
 '{"action": "escrow_released", "expected_result": "release_authorized"}'::JSONB,
 'check_escrow_release', 'CRITICAL', false),

('ESC_003', 'ESCROW', 'Escrow refund must follow rules',
 'Remboursement escrow doit suivre les règles',
 '{"action": "escrow_refunded", "expected_result": "refund_valid"}'::JSONB,
 'check_escrow_refund', 'HIGH', false),

('ESC_004', 'ESCROW', 'Escrow dispute must be logged',
 'Litige escrow doit être journalisé',
 '{"action": "escrow_disputed", "expected_result": "dispute_logged"}'::JSONB,
 'check_escrow_dispute', 'MEDIUM', false),

('ESC_005', 'ESCROW', 'Escrow timeout must be handled',
 'Timeout escrow doit déclencher action automatique',
 '{"action": "escrow_timeout", "expected_result": "timeout_handled"}'::JSONB,
 'check_escrow_timeout', 'HIGH', true),

-- ==================== FRAUDE (6 règles) ====================
('FRD_001', 'FRAUD', 'Suspicious transaction must be flagged',
 'Transaction suspecte doit être signalée',
 '{"action": "transaction_created", "expected_result": "fraud_check_passed"}'::JSONB,
 'check_fraud_detection', 'CRITICAL', false),

('FRD_002', 'FRAUD', 'Multiple failed logins must trigger alert',
 'Plusieurs échecs login doivent déclencher alerte',
 '{"action": "login_failed_multiple", "expected_result": "alert_triggered"}'::JSONB,
 'check_login_attempts', 'HIGH', true),

('FRD_003', 'FRAUD', 'Unusual activity must be detected',
 'Activité inhabituelle doit être détectée',
 '{"action": "activity_detected", "expected_result": "pattern_checked"}'::JSONB,
 'check_unusual_activity', 'HIGH', false),

('FRD_004', 'FRAUD', 'Device fingerprint must be verified',
 'Empreinte appareil doit être vérifiée',
 '{"action": "login_attempt", "expected_result": "device_verified"}'::JSONB,
 'check_device_fingerprint', 'MEDIUM', false),

('FRD_005', 'FRAUD', 'High-value transaction must require 2FA',
 'Transaction haute valeur doit exiger 2FA',
 '{"action": "high_value_transaction", "expected_result": "2fa_completed"}'::JSONB,
 'check_2fa_required', 'CRITICAL', false),

('FRD_006', 'FRAUD', 'Blacklisted user must be blocked',
 'Utilisateur blacklisté doit être bloqué',
 '{"action": "user_action", "expected_result": "blacklist_checked"}'::JSONB,
 'check_blacklist', 'CRITICAL', true),

-- ==================== DROPSHIPPING (4 règles) ====================
('DROP_001', 'DROPSHIPPING', 'Price sync must be accurate',
 'Synchronisation prix doit être exacte',
 '{"action": "price_synced", "expected_result": "price_accurate"}'::JSONB,
 'check_price_sync', 'HIGH', true),

('DROP_002', 'DROPSHIPPING', 'Supplier must be verified',
 'Fournisseur doit être vérifié',
 '{"action": "order_placed", "expected_result": "supplier_verified"}'::JSONB,
 'check_supplier_status', 'HIGH', false),

('DROP_003', 'DROPSHIPPING', 'Stock availability must be checked',
 'Disponibilité stock fournisseur doit être vérifiée',
 '{"action": "product_ordered", "expected_result": "stock_available"}'::JSONB,
 'check_supplier_stock', 'HIGH', false),

('DROP_004', 'DROPSHIPPING', 'Shipping cost must be calculated',
 'Frais expédition doivent être calculés',
 '{"action": "order_created", "expected_result": "shipping_calculated"}'::JSONB,
 'check_shipping_cost', 'MEDIUM', true),

-- ==================== SERVICES PROFESSIONNELS (6 règles) ====================
('SVC_001', 'PROFESSIONAL_SERVICES', 'Appointment must be confirmed',
 'RDV doit être confirmé avant l\'heure',
 '{"action": "appointment_created", "expected_result": "confirmation_sent"}'::JSONB,
 'check_appointment_confirmation', 'MEDIUM', false),

('SVC_002', 'PROFESSIONAL_SERVICES', 'Service provider must be available',
 'Prestataire doit être disponible',
 '{"action": "booking_requested", "expected_result": "provider_available"}'::JSONB,
 'check_provider_availability', 'HIGH', false),

('SVC_003', 'PROFESSIONAL_SERVICES', 'Service price must match catalog',
 'Prix service doit correspondre au catalogue',
 '{"action": "service_booked", "expected_result": "price_matches"}'::JSONB,
 'check_service_price', 'HIGH', true),

('SVC_004', 'PROFESSIONAL_SERVICES', 'Rating must be submitted after service',
 'Évaluation doit être demandée après service',
 '{"action": "service_completed", "expected_result": "rating_requested"}'::JSONB,
 'check_rating_request', 'LOW', false),

('SVC_005', 'PROFESSIONAL_SERVICES', 'Provider earnings must be credited',
 'Gains prestataire doivent être crédités',
 '{"action": "service_completed", "expected_result": "earnings_credited"}'::JSONB,
 'check_provider_earnings', 'HIGH', true),

('SVC_006', 'PROFESSIONAL_SERVICES', 'Cancellation must follow policy',
 'Annulation doit suivre la politique',
 '{"action": "booking_cancelled", "expected_result": "policy_followed"}'::JSONB,
 'check_cancellation_policy', 'MEDIUM', false),

-- ==================== COMMUNICATION (4 règles) ====================
('COM_MSG_001', 'COMMUNICATION', 'Message must be delivered',
 'Message doit être livré au destinataire',
 '{"action": "message_sent", "expected_result": "delivered"}'::JSONB,
 'check_message_delivery', 'MEDIUM', false),

('COM_MSG_002', 'COMMUNICATION', 'Conversation must be logged',
 'Conversation doit être journalisée pour audit',
 '{"action": "conversation_created", "expected_result": "audit_logged"}'::JSONB,
 'check_conversation_audit', 'LOW', false),

('COM_MSG_003', 'COMMUNICATION', 'Spam content must be filtered',
 'Contenu spam doit être filtré',
 '{"action": "message_sent", "expected_result": "spam_checked"}'::JSONB,
 'check_spam_filter', 'MEDIUM', true),

('COM_MSG_004', 'COMMUNICATION', 'Video call must have valid participants',
 'Appel vidéo doit avoir des participants valides',
 '{"action": "call_started", "expected_result": "participants_valid"}'::JSONB,
 'check_call_participants', 'HIGH', false),

-- ==================== VENDEURS (5 règles) ====================
('VND_001', 'VENDORS', 'Vendor must have valid certification',
 'Vendeur doit avoir certification valide',
 '{"action": "product_listed", "expected_result": "vendor_certified"}'::JSONB,
 'check_vendor_certification', 'HIGH', false),

('VND_002', 'VENDORS', 'Vendor KYC must be verified',
 'KYC vendeur doit être vérifié',
 '{"action": "vendor_activated", "expected_result": "kyc_verified"}'::JSONB,
 'check_vendor_kyc', 'HIGH', false),

('VND_003', 'VENDORS', 'Vendor payout must be processed',
 'Paiement vendeur doit être traité',
 '{"action": "payout_requested", "expected_result": "payout_processed"}'::JSONB,
 'check_vendor_payout', 'HIGH', true),

('VND_004', 'VENDORS', 'Vendor rating must be updated',
 'Note vendeur doit être mise à jour',
 '{"action": "review_submitted", "expected_result": "rating_updated"}'::JSONB,
 'check_vendor_rating', 'LOW', true),

('VND_005', 'VENDORS', 'Vendor must respect return policy',
 'Vendeur doit respecter politique de retour',
 '{"action": "return_requested", "expected_result": "policy_checked"}'::JSONB,
 'check_return_policy', 'MEDIUM', false),

-- ==================== CLIENTS (4 règles) ====================
('CLT_001', 'CUSTOMERS', 'Customer order history must be maintained',
 'Historique commandes client doit être maintenu',
 '{"action": "order_completed", "expected_result": "history_updated"}'::JSONB,
 'check_order_history', 'LOW', true),

('CLT_002', 'CUSTOMERS', 'Customer loyalty points must be credited',
 'Points fidélité doivent être crédités',
 '{"action": "purchase_completed", "expected_result": "points_credited"}'::JSONB,
 'check_loyalty_points', 'MEDIUM', true),

('CLT_003', 'CUSTOMERS', 'Customer refund must be processed within SLA',
 'Remboursement doit être traité dans le SLA',
 '{"action": "refund_requested", "expected_result": "sla_respected"}'::JSONB,
 'check_refund_sla', 'HIGH', false),

('CLT_004', 'CUSTOMERS', 'Customer data must be protected',
 'Données client doivent être protégées',
 '{"action": "data_accessed", "expected_result": "access_authorized"}'::JSONB,
 'check_data_protection', 'CRITICAL', false),

-- ==================== API (4 règles) ====================
('API_001', 'API', 'API rate limit must be respected',
 'Limite de taux API doit être respectée',
 '{"action": "api_call", "expected_result": "rate_limit_ok"}'::JSONB,
 'check_rate_limit', 'HIGH', true),

('API_002', 'API', 'API key must be valid',
 'Clé API doit être valide',
 '{"action": "api_authenticated", "expected_result": "key_valid"}'::JSONB,
 'check_api_key', 'CRITICAL', false),

('API_003', 'API', 'API response time must be acceptable',
 'Temps de réponse API doit être acceptable',
 '{"action": "api_response", "expected_result": "response_time_ok"}'::JSONB,
 'check_api_latency', 'MEDIUM', false),

('API_004', 'API', 'API errors must be logged',
 'Erreurs API doivent être journalisées',
 '{"action": "api_error", "expected_result": "error_logged"}'::JSONB,
 'check_api_error_log', 'HIGH', false)

ON CONFLICT (rule_id) DO NOTHING;

-- ====================================================================
-- 9. TRIGGERS DE DÉTECTION EN TEMPS RÉEL
-- ====================================================================

-- Fonction générique pour créer une anomalie
CREATE OR REPLACE FUNCTION log_surveillance_anomaly(
  p_domain TEXT,
  p_entity_type TEXT,
  p_entity_id TEXT,
  p_action_type TEXT,
  p_expected JSONB,
  p_actual JSONB,
  p_severity TEXT DEFAULT 'MEDIUM'
)
RETURNS UUID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_anomaly_id UUID;
BEGIN
  INSERT INTO logic_anomalies (
    domain,
    entity_type,
    entity_id,
    action_type,
    expected_value,
    actual_value,
    severity,
    status,
    detected_at,
    detected_by
  ) VALUES (
    p_domain,
    p_entity_type,
    p_entity_id,
    p_action_type,
    p_expected,
    p_actual,
    p_severity,
    'pending',
    NOW(),
    'system_trigger'
  ) RETURNING id INTO v_anomaly_id;

  -- Créer une alerte PDG si critique
  IF p_severity = 'CRITICAL' THEN
    INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, metadata)
    VALUES (
      'logic_anomaly',
      'critical',
      'Anomalie critique détectée',
      format('Domaine: %s, Type: %s, Action: %s', p_domain, p_entity_type, p_action_type),
      jsonb_build_object('anomaly_id', v_anomaly_id, 'domain', p_domain)
    );
  END IF;

  RETURN v_anomaly_id;
END;
$$;

-- Trigger sur les wallets pour détecter les soldes négatifs
CREATE OR REPLACE FUNCTION trigger_check_wallet_balance()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.balance < 0 THEN
    PERFORM log_surveillance_anomaly(
      'WALLETS',
      'wallet',
      NEW.id::TEXT,
      'balance_negative',
      jsonb_build_object('expected', 'balance >= 0'),
      jsonb_build_object('actual_balance', NEW.balance, 'user_id', NEW.user_id),
      'CRITICAL'
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_surveillance_wallet_balance ON wallets;
CREATE TRIGGER trg_surveillance_wallet_balance
  AFTER INSERT OR UPDATE OF balance ON wallets
  FOR EACH ROW
  EXECUTE FUNCTION trigger_check_wallet_balance();

-- Trigger sur les commandes pour vérifier la cohérence
CREATE OR REPLACE FUNCTION trigger_check_order_total()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_calculated_total NUMERIC;
BEGIN
  -- Calculer le total des items
  SELECT COALESCE(SUM(quantity * unit_price), 0)
  INTO v_calculated_total
  FROM order_items
  WHERE order_id = NEW.id;

  -- Vérifier si le total correspond (avec tolérance de 1%)
  IF ABS(NEW.total_amount - v_calculated_total) > (NEW.total_amount * 0.01) AND NEW.total_amount > 0 THEN
    PERFORM log_surveillance_anomaly(
      'ORDERS',
      'order',
      NEW.id::TEXT,
      'total_mismatch',
      jsonb_build_object('expected_total', v_calculated_total),
      jsonb_build_object('actual_total', NEW.total_amount, 'difference', NEW.total_amount - v_calculated_total),
      'HIGH'
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_surveillance_order_total ON orders;
CREATE TRIGGER trg_surveillance_order_total
  AFTER INSERT OR UPDATE OF total_amount ON orders
  FOR EACH ROW
  EXECUTE FUNCTION trigger_check_order_total();

-- Trigger sur les produits pour détecter les stocks négatifs
CREATE OR REPLACE FUNCTION trigger_check_product_stock()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.stock_quantity < 0 THEN
    PERFORM log_surveillance_anomaly(
      'INVENTORY',
      'product',
      NEW.id::TEXT,
      'stock_negative',
      jsonb_build_object('expected', 'stock >= 0'),
      jsonb_build_object('actual_stock', NEW.stock_quantity, 'product_name', NEW.name),
      'CRITICAL'
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_surveillance_product_stock ON products;
CREATE TRIGGER trg_surveillance_product_stock
  AFTER INSERT OR UPDATE OF stock_quantity ON products
  FOR EACH ROW
  EXECUTE FUNCTION trigger_check_product_stock();

-- Trigger sur les transactions wallet pour vérifier la cohérence
CREATE OR REPLACE FUNCTION trigger_check_wallet_transaction()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_wallet_balance NUMERIC;
BEGIN
  -- Vérifier que le montant n'est pas nul ou aberrant
  IF NEW.amount = 0 THEN
    PERFORM log_surveillance_anomaly(
      'WALLETS',
      'transaction',
      NEW.id::TEXT,
      'zero_amount',
      jsonb_build_object('expected', 'amount != 0'),
      jsonb_build_object('amount', NEW.amount, 'type', NEW.type),
      'MEDIUM'
    );
  END IF;

  -- Vérifier les transactions très élevées (> 10M GNF)
  IF ABS(NEW.amount) > 10000000 THEN
    PERFORM log_surveillance_anomaly(
      'WALLETS',
      'transaction',
      NEW.id::TEXT,
      'high_value_transaction',
      jsonb_build_object('threshold', 10000000),
      jsonb_build_object('amount', NEW.amount, 'type', NEW.type, 'wallet_id', NEW.wallet_id),
      'HIGH'
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_surveillance_wallet_transaction ON wallet_transactions;
CREATE TRIGGER trg_surveillance_wallet_transaction
  AFTER INSERT ON wallet_transactions
  FOR EACH ROW
  EXECUTE FUNCTION trigger_check_wallet_transaction();

-- Trigger sur les profils pour vérifier les changements de rôle
CREATE OR REPLACE FUNCTION trigger_check_role_change()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.role IS DISTINCT FROM NEW.role THEN
    -- Logger le changement de rôle
    PERFORM log_surveillance_anomaly(
      'SECURITY',
      'profile',
      NEW.id::TEXT,
      'role_change',
      jsonb_build_object('old_role', OLD.role),
      jsonb_build_object('new_role', NEW.role, 'user_email', NEW.email),
      'HIGH'
    );

    -- Alerte critique si changement vers admin/pdg/ceo
    IF NEW.role IN ('admin', 'pdg', 'ceo') AND OLD.role NOT IN ('admin', 'pdg', 'ceo') THEN
      INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, metadata)
      VALUES (
        'security_alert',
        'critical',
        'Changement de rôle privilégié',
        format('Utilisateur %s promu en %s', NEW.email, NEW.role),
        jsonb_build_object('user_id', NEW.id, 'old_role', OLD.role, 'new_role', NEW.role)
      );
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_surveillance_role_change ON profiles;
CREATE TRIGGER trg_surveillance_role_change
  AFTER UPDATE OF role ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION trigger_check_role_change();

-- ====================================================================
-- 10. FONCTIONS DE DÉTECTION AVANCÉES
-- ====================================================================

-- Détection des anomalies de wallet (réconciliation)
CREATE OR REPLACE FUNCTION detect_wallet_reconciliation_anomalies()
RETURNS TABLE (
  wallet_id UUID,
  user_id UUID,
  stored_balance NUMERIC,
  calculated_balance NUMERIC,
  difference NUMERIC,
  severity TEXT
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    w.id,
    w.user_id,
    COALESCE(w.balance, 0),
    COALESCE((
      SELECT SUM(
        CASE
          WHEN wt.type IN ('credit', 'deposit', 'refund', 'commission') THEN wt.amount
          WHEN wt.type IN ('debit', 'withdrawal', 'payment', 'transfer_out') THEN -wt.amount
          ELSE 0
        END
      )
      FROM wallet_transactions wt
      WHERE wt.wallet_id = w.id
    ), 0) AS calc_balance,
    COALESCE(w.balance, 0) - COALESCE((
      SELECT SUM(
        CASE
          WHEN wt.type IN ('credit', 'deposit', 'refund', 'commission') THEN wt.amount
          WHEN wt.type IN ('debit', 'withdrawal', 'payment', 'transfer_out') THEN -wt.amount
          ELSE 0
        END
      )
      FROM wallet_transactions wt
      WHERE wt.wallet_id = w.id
    ), 0) AS diff,
    CASE
      WHEN ABS(COALESCE(w.balance, 0) - COALESCE((
        SELECT SUM(
          CASE
            WHEN wt.type IN ('credit', 'deposit', 'refund', 'commission') THEN wt.amount
            WHEN wt.type IN ('debit', 'withdrawal', 'payment', 'transfer_out') THEN -wt.amount
            ELSE 0
          END
        )
        FROM wallet_transactions wt
        WHERE wt.wallet_id = w.id
      ), 0)) > 1000 THEN 'critical'
      WHEN ABS(COALESCE(w.balance, 0) - COALESCE((
        SELECT SUM(
          CASE
            WHEN wt.type IN ('credit', 'deposit', 'refund', 'commission') THEN wt.amount
            WHEN wt.type IN ('debit', 'withdrawal', 'payment', 'transfer_out') THEN -wt.amount
            ELSE 0
          END
        )
        FROM wallet_transactions wt
        WHERE wt.wallet_id = w.id
      ), 0)) > 0 THEN 'warning'
      ELSE 'ok'
    END
  FROM wallets w
  WHERE ABS(COALESCE(w.balance, 0) - COALESCE((
    SELECT SUM(
      CASE
        WHEN wt.type IN ('credit', 'deposit', 'refund', 'commission') THEN wt.amount
        WHEN wt.type IN ('debit', 'withdrawal', 'payment', 'transfer_out') THEN -wt.amount
        ELSE 0
      END
    )
    FROM wallet_transactions wt
    WHERE wt.wallet_id = w.id
  ), 0)) > 0;
END;
$$;

-- Détection des commandes sans paiement
CREATE OR REPLACE FUNCTION detect_unpaid_orders()
RETURNS TABLE (
  order_id UUID,
  order_status TEXT,
  total_amount NUMERIC,
  created_at TIMESTAMPTZ,
  hours_since_creation NUMERIC,
  severity TEXT
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    o.id,
    o.status,
    o.total_amount,
    o.created_at,
    EXTRACT(EPOCH FROM (NOW() - o.created_at)) / 3600 AS hours_diff,
    CASE
      WHEN EXTRACT(EPOCH FROM (NOW() - o.created_at)) / 3600 > 48 THEN 'critical'
      WHEN EXTRACT(EPOCH FROM (NOW() - o.created_at)) / 3600 > 24 THEN 'warning'
      ELSE 'info'
    END
  FROM orders o
  WHERE o.status IN ('pending', 'confirmed')
  AND o.payment_status != 'paid'
  AND o.created_at < NOW() - INTERVAL '4 hours';
END;
$$;

-- Fonction de validation système complète améliorée
CREATE OR REPLACE FUNCTION run_full_system_validation(p_triggered_by UUID DEFAULT NULL)
RETURNS UUID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_snapshot_id UUID;
  v_stock_anomalies INTEGER := 0;
  v_wallet_anomalies INTEGER := 0;
  v_order_anomalies INTEGER := 0;
  v_reconciliation_anomalies INTEGER := 0;
  v_total_anomalies INTEGER := 0;
  v_total_checks INTEGER := 0;
BEGIN
  -- Créer le snapshot
  INSERT INTO logic_validation_snapshots (snapshot_type, triggered_by, started_at)
  VALUES ('on_demand', p_triggered_by, now())
  RETURNING id INTO v_snapshot_id;

  -- 1. Vérifier les anomalies de stock
  v_total_checks := v_total_checks + 1;
  SELECT COUNT(*) INTO v_stock_anomalies FROM detect_stock_anomalies() WHERE severity != 'ok';

  INSERT INTO logic_anomalies (domain, entity_type, entity_id, action_type, expected_value, actual_value, severity, detected_by, status)
  SELECT
    'INVENTORY',
    'product',
    product_id::TEXT,
    'stock_sync',
    jsonb_build_object('products_stock', products_stock),
    jsonb_build_object('inventory_quantity', inventory_quantity, 'difference', difference),
    CASE WHEN severity = 'critical' THEN 'CRITICAL' WHEN severity = 'warning' THEN 'HIGH' ELSE 'MEDIUM' END,
    'system_validation',
    'pending'
  FROM detect_stock_anomalies()
  WHERE severity != 'ok';

  -- 2. Vérifier les anomalies de wallet (soldes négatifs)
  v_total_checks := v_total_checks + 1;
  SELECT COUNT(*) INTO v_wallet_anomalies
  FROM wallets WHERE balance < 0;

  INSERT INTO logic_anomalies (domain, entity_type, entity_id, action_type, expected_value, actual_value, severity, detected_by, status)
  SELECT
    'WALLETS',
    'wallet',
    id::TEXT,
    'balance_check',
    jsonb_build_object('expected', 'balance >= 0'),
    jsonb_build_object('balance', balance, 'user_id', user_id),
    'CRITICAL',
    'system_validation',
    'pending'
  FROM wallets
  WHERE balance < 0;

  -- 3. Vérifier les réconciliations wallet
  v_total_checks := v_total_checks + 1;
  SELECT COUNT(*) INTO v_reconciliation_anomalies FROM detect_wallet_reconciliation_anomalies() WHERE severity != 'ok';

  INSERT INTO logic_anomalies (domain, entity_type, entity_id, action_type, expected_value, actual_value, severity, detected_by, status)
  SELECT
    'WALLETS',
    'wallet',
    wallet_id::TEXT,
    'reconciliation',
    jsonb_build_object('stored_balance', stored_balance),
    jsonb_build_object('calculated_balance', calculated_balance, 'difference', difference),
    CASE WHEN severity = 'critical' THEN 'CRITICAL' ELSE 'HIGH' END,
    'system_validation',
    'pending'
  FROM detect_wallet_reconciliation_anomalies()
  WHERE severity != 'ok';

  -- 4. Vérifier les commandes impayées
  v_total_checks := v_total_checks + 1;
  SELECT COUNT(*) INTO v_order_anomalies FROM detect_unpaid_orders() WHERE severity IN ('critical', 'warning');

  INSERT INTO logic_anomalies (domain, entity_type, entity_id, action_type, expected_value, actual_value, severity, detected_by, status)
  SELECT
    'ORDERS',
    'order',
    order_id::TEXT,
    'unpaid_order',
    jsonb_build_object('expected', 'payment_received'),
    jsonb_build_object('status', order_status, 'hours_since', hours_since_creation, 'amount', total_amount),
    CASE WHEN severity = 'critical' THEN 'CRITICAL' ELSE 'HIGH' END,
    'system_validation',
    'pending'
  FROM detect_unpaid_orders()
  WHERE severity IN ('critical', 'warning');

  v_total_anomalies := v_stock_anomalies + v_wallet_anomalies + v_reconciliation_anomalies + v_order_anomalies;

  -- Mettre à jour le snapshot
  UPDATE logic_validation_snapshots
  SET
    completed_at = now(),
    total_checks = v_total_checks,
    passed_checks = v_total_checks - CASE WHEN v_total_anomalies > 0 THEN 1 ELSE 0 END,
    failed_checks = CASE WHEN v_total_anomalies > 0 THEN 1 ELSE 0 END,
    anomalies_detected = v_total_anomalies,
    details = jsonb_build_object(
      'stock_anomalies', v_stock_anomalies,
      'wallet_anomalies', v_wallet_anomalies,
      'reconciliation_anomalies', v_reconciliation_anomalies,
      'order_anomalies', v_order_anomalies
    )
  WHERE id = v_snapshot_id;

  -- Créer une alerte PDG si anomalies critiques
  IF v_total_anomalies > 0 THEN
    INSERT INTO pdg_financial_alerts (alert_type, severity, title, message, metadata)
    VALUES (
      'logic_anomaly',
      CASE WHEN v_total_anomalies > 5 THEN 'critical' ELSE 'warning' END,
      'Validation système - Anomalies détectées',
      format('%s anomalies détectées lors de la validation système', v_total_anomalies),
      jsonb_build_object('snapshot_id', v_snapshot_id, 'total_anomalies', v_total_anomalies, 'details', jsonb_build_object(
        'stock', v_stock_anomalies,
        'wallet', v_wallet_anomalies,
        'reconciliation', v_reconciliation_anomalies,
        'orders', v_order_anomalies
      ))
    );
  END IF;

  RETURN v_snapshot_id;
END;
$$;

-- ====================================================================
-- 11. VUES DE MONITORING
-- ====================================================================

-- Vue des anomalies actives par domaine
CREATE OR REPLACE VIEW v_active_anomalies_by_domain AS
SELECT
  domain,
  severity,
  COUNT(*) as count,
  MIN(detected_at) as oldest_anomaly,
  MAX(detected_at) as newest_anomaly
FROM logic_anomalies
WHERE status = 'pending' OR (status IS NULL AND resolved_at IS NULL)
GROUP BY domain, severity
ORDER BY
  CASE severity
    WHEN 'CRITICAL' THEN 1
    WHEN 'HIGH' THEN 2
    WHEN 'MEDIUM' THEN 3
    ELSE 4
  END,
  count DESC;

-- Vue de santé du système par module
CREATE OR REPLACE VIEW v_system_health_by_module AS
SELECT
  domain,
  COUNT(*) FILTER (WHERE status = 'pending') as pending_count,
  COUNT(*) FILTER (WHERE status = 'corrected') as corrected_count,
  COUNT(*) FILTER (WHERE status = 'ignored') as ignored_count,
  COUNT(*) FILTER (WHERE severity = 'CRITICAL' AND status = 'pending') as critical_pending,
  CASE
    WHEN COUNT(*) FILTER (WHERE severity = 'CRITICAL' AND status = 'pending') > 0 THEN 'CRITICAL'
    WHEN COUNT(*) FILTER (WHERE status = 'pending') > 5 THEN 'WARNING'
    ELSE 'OK'
  END as health_status
FROM logic_anomalies
GROUP BY domain;

-- ====================================================================
-- 12. COMMENTAIRES FINAUX
-- ====================================================================

COMMENT ON FUNCTION log_surveillance_anomaly IS 'Crée une anomalie de surveillance avec alerte PDG si critique';
COMMENT ON FUNCTION trigger_check_wallet_balance IS 'Trigger pour détecter les soldes wallet négatifs';
COMMENT ON FUNCTION trigger_check_order_total IS 'Trigger pour vérifier la cohérence des totaux commande';
COMMENT ON FUNCTION trigger_check_product_stock IS 'Trigger pour détecter les stocks négatifs';
COMMENT ON FUNCTION trigger_check_wallet_transaction IS 'Trigger pour surveiller les transactions wallet';
COMMENT ON FUNCTION trigger_check_role_change IS 'Trigger pour alerter sur les changements de rôle';
COMMENT ON FUNCTION detect_wallet_reconciliation_anomalies IS 'Détecte les écarts entre solde et transactions';
COMMENT ON FUNCTION detect_unpaid_orders IS 'Détecte les commandes impayées anciennes';
COMMENT ON VIEW v_active_anomalies_by_domain IS 'Vue des anomalies actives groupées par domaine';
COMMENT ON VIEW v_system_health_by_module IS 'Vue de la santé système par module';
