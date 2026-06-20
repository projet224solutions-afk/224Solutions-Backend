-- =============================================
-- PAYMENT CORE SYSTEM - MIGRATION COMPLÈTE
-- Système centralisé pour tous types de paiements
-- =============================================

-- 1. Extension djomy_transactions pour le Payment Core
ALTER TABLE djomy_transactions 
ADD COLUMN IF NOT EXISTS payment_type TEXT DEFAULT 'ORDER_PAYMENT',
ADD COLUMN IF NOT EXISTS reference_id TEXT,
ADD COLUMN IF NOT EXISTS trust_score INTEGER,
ADD COLUMN IF NOT EXISTS score_breakdown JSONB,
ADD COLUMN IF NOT EXISTS release_type TEXT,
ADD COLUMN IF NOT EXISTS auto_released BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS blocked_until TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS reviewed_by UUID,
ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ;

-- 2. Contrainte sur payment_type
DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'djomy_transactions_payment_type_check') THEN
    ALTER TABLE djomy_transactions ADD CONSTRAINT djomy_transactions_payment_type_check 
    CHECK (payment_type IN ('ORDER_PAYMENT', 'SUBSCRIPTION', 'BOOST', 'DELIVERY', 'COMMISSION', 'WALLET_TOPUP', 'TRANSFER'));
  END IF;
END $$;

-- 3. Index pour performance
CREATE INDEX IF NOT EXISTS idx_djomy_transactions_payment_type ON djomy_transactions(payment_type);
CREATE INDEX IF NOT EXISTS idx_djomy_transactions_reference_id ON djomy_transactions(reference_id);
CREATE INDEX IF NOT EXISTS idx_djomy_transactions_trust_score ON djomy_transactions(trust_score);
CREATE INDEX IF NOT EXISTS idx_djomy_transactions_release_type ON djomy_transactions(release_type);

-- 4. Table de configuration du scoring
CREATE TABLE IF NOT EXISTS payment_score_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  config_key TEXT UNIQUE NOT NULL,
  config_value NUMERIC NOT NULL,
  description TEXT,
  category TEXT DEFAULT 'scoring',
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  updated_by UUID
);

-- 5. Valeurs de configuration par défaut
INSERT INTO payment_score_config (config_key, config_value, description, category) VALUES
  ('auto_release_threshold', 80, 'Score minimum pour auto-déblocage', 'thresholds'),
  ('temp_block_threshold', 50, 'Score minimum pour blocage temporaire', 'thresholds'),
  ('manual_review_threshold', 50, 'Score sous lequel admin obligatoire', 'thresholds'),
  ('temp_block_hours', 2, 'Heures de blocage temporaire', 'timing'),
  ('max_auto_release_amount', 5000000, 'Montant max auto-déblocage (GNF)', 'limits'),
  ('weight_djomy_confirmed', 40, 'Points pour confirmation Djomy', 'weights'),
  ('weight_user_age_30days', 10, 'Points utilisateur > 30 jours', 'weights'),
  ('weight_phone_known', 10, 'Points téléphone déjà utilisé', 'weights'),
  ('weight_vendor_kyc', 20, 'Points vendeur KYC validé', 'weights'),
  ('weight_low_amount', 10, 'Points montant sous seuil', 'weights'),
  ('weight_no_fraud', 10, 'Points aucune fraude passée', 'weights')
ON CONFLICT (config_key) DO UPDATE SET config_value = EXCLUDED.config_value, updated_at = NOW();

-- 6. Table pour logs détaillés du scoring
CREATE TABLE IF NOT EXISTS payment_score_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES djomy_transactions(id),
  total_score INTEGER NOT NULL,
  breakdown JSONB NOT NULL,
  decision TEXT NOT NULL,
  config_snapshot JSONB,
  calculated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payment_score_logs_transaction ON payment_score_logs(transaction_id);
CREATE INDEX IF NOT EXISTS idx_payment_score_logs_decision ON payment_score_logs(decision);

-- 7. Table des abonnements activés par paiement
CREATE TABLE IF NOT EXISTS payment_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID REFERENCES djomy_transactions(id),
  vendor_id UUID NOT NULL,
  plan_type TEXT NOT NULL,
  amount NUMERIC NOT NULL,
  currency TEXT DEFAULT 'GNF',
  starts_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  auto_renew BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payment_subscriptions_vendor ON payment_subscriptions(vendor_id);
CREATE INDEX IF NOT EXISTS idx_payment_subscriptions_active ON payment_subscriptions(is_active) WHERE is_active = TRUE;

-- 8. Table des boosts activés par paiement
CREATE TABLE IF NOT EXISTS payment_boosts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID REFERENCES djomy_transactions(id),
  vendor_id UUID,
  product_id UUID,
  boost_type TEXT NOT NULL,
  amount NUMERIC NOT NULL,
  currency TEXT DEFAULT 'GNF',
  starts_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  impressions_target INTEGER,
  impressions_delivered INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payment_boosts_vendor ON payment_boosts(vendor_id);
CREATE INDEX IF NOT EXISTS idx_payment_boosts_product ON payment_boosts(product_id);
CREATE INDEX IF NOT EXISTS idx_payment_boosts_active ON payment_boosts(is_active) WHERE is_active = TRUE;

-- 9. Table des livraisons payées
CREATE TABLE IF NOT EXISTS payment_deliveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID REFERENCES djomy_transactions(id),
  delivery_id UUID NOT NULL,
  driver_id UUID NOT NULL,
  amount NUMERIC NOT NULL,
  currency TEXT DEFAULT 'GNF',
  status TEXT DEFAULT 'PENDING',
  credited_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payment_deliveries_driver ON payment_deliveries(driver_id);
CREATE INDEX IF NOT EXISTS idx_payment_deliveries_delivery ON payment_deliveries(delivery_id);

-- 10. Table des commissions plateforme
CREATE TABLE IF NOT EXISTS payment_commissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID REFERENCES djomy_transactions(id),
  source_type TEXT NOT NULL,
  source_id UUID,
  amount NUMERIC NOT NULL,
  rate NUMERIC,
  currency TEXT DEFAULT 'GNF',
  credited_at TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payment_commissions_source ON payment_commissions(source_type, source_id);

-- 11. Vue unifiée des paiements (avec business_name au lieu de store_name)
CREATE OR REPLACE VIEW payment_core_view AS
SELECT 
  t.id,
  t.order_id,
  t.payment_type,
  t.reference_id,
  t.user_id,
  t.vendor_id,
  t.amount,
  t.currency,
  t.payment_method,
  t.status,
  t.trust_score,
  t.release_type,
  t.auto_released,
  t.payer_phone,
  t.created_at,
  t.updated_at,
  p.full_name as user_name,
  v.business_name as vendor_name
FROM djomy_transactions t
LEFT JOIN profiles p ON t.user_id = p.id
LEFT JOIN vendors v ON t.vendor_id = v.id;

-- 12. Fonction pour calculer et enregistrer le score
CREATE OR REPLACE FUNCTION calculate_payment_trust_score(
  p_transaction_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tx RECORD;
  v_config JSONB;
  v_score INTEGER := 0;
  v_breakdown JSONB := '{}';
  v_decision TEXT;
  v_user_age INTEGER;
  v_phone_count INTEGER;
  v_vendor_kyc TEXT;
  v_fraud_count INTEGER;
  v_weight_djomy INTEGER;
  v_weight_user_age INTEGER;
  v_weight_phone INTEGER;
  v_weight_kyc INTEGER;
  v_weight_amount INTEGER;
  v_weight_fraud INTEGER;
  v_threshold_auto INTEGER;
  v_threshold_temp INTEGER;
  v_max_auto_amount NUMERIC;
BEGIN
  SELECT * INTO v_tx FROM djomy_transactions WHERE id = p_transaction_id;
  IF v_tx IS NULL THEN
    RETURN jsonb_build_object('error', 'Transaction not found');
  END IF;

  SELECT jsonb_object_agg(config_key, config_value) INTO v_config FROM payment_score_config;

  v_weight_djomy := COALESCE((v_config->>'weight_djomy_confirmed')::INTEGER, 40);
  v_weight_user_age := COALESCE((v_config->>'weight_user_age_30days')::INTEGER, 10);
  v_weight_phone := COALESCE((v_config->>'weight_phone_known')::INTEGER, 10);
  v_weight_kyc := COALESCE((v_config->>'weight_vendor_kyc')::INTEGER, 20);
  v_weight_amount := COALESCE((v_config->>'weight_low_amount')::INTEGER, 10);
  v_weight_fraud := COALESCE((v_config->>'weight_no_fraud')::INTEGER, 10);
  v_threshold_auto := COALESCE((v_config->>'auto_release_threshold')::INTEGER, 80);
  v_threshold_temp := COALESCE((v_config->>'temp_block_threshold')::INTEGER, 50);
  v_max_auto_amount := COALESCE((v_config->>'max_auto_release_amount')::NUMERIC, 5000000);

  -- 1. Confirmation Djomy (40 points si SUCCESS)
  IF v_tx.status = 'SUCCESS' THEN
    v_score := v_score + v_weight_djomy;
    v_breakdown := v_breakdown || jsonb_build_object('djomy_confirmed', jsonb_build_object('score', v_weight_djomy, 'max', v_weight_djomy, 'details', 'Transaction confirmée'));
  ELSE
    v_breakdown := v_breakdown || jsonb_build_object('djomy_confirmed', jsonb_build_object('score', 0, 'max', v_weight_djomy, 'details', 'Transaction non confirmée'));
  END IF;

  -- 2. Ancienneté utilisateur (10 points si > 30 jours)
  IF v_tx.user_id IS NOT NULL THEN
    SELECT EXTRACT(DAY FROM NOW() - created_at)::INTEGER INTO v_user_age FROM profiles WHERE id = v_tx.user_id;
    IF v_user_age > 30 THEN
      v_score := v_score + v_weight_user_age;
      v_breakdown := v_breakdown || jsonb_build_object('user_age', jsonb_build_object('score', v_weight_user_age, 'max', v_weight_user_age, 'details', format('Compte créé il y a %s jours', v_user_age)));
    ELSE
      v_breakdown := v_breakdown || jsonb_build_object('user_age', jsonb_build_object('score', 0, 'max', v_weight_user_age, 'details', format('Compte récent (%s jours)', COALESCE(v_user_age, 0))));
    END IF;
  ELSE
    v_breakdown := v_breakdown || jsonb_build_object('user_age', jsonb_build_object('score', 0, 'max', v_weight_user_age, 'details', 'Utilisateur non identifié'));
  END IF;

  -- 3. Téléphone déjà utilisé (10 points)
  SELECT COUNT(*) INTO v_phone_count FROM djomy_transactions WHERE payer_phone = v_tx.payer_phone AND status = 'SUCCESS' AND id != p_transaction_id;
  IF v_phone_count >= 1 THEN
    v_score := v_score + v_weight_phone;
    v_breakdown := v_breakdown || jsonb_build_object('phone_history', jsonb_build_object('score', v_weight_phone, 'max', v_weight_phone, 'details', format('%s transaction(s) réussie(s)', v_phone_count)));
  ELSE
    v_breakdown := v_breakdown || jsonb_build_object('phone_history', jsonb_build_object('score', 0, 'max', v_weight_phone, 'details', 'Nouveau numéro'));
  END IF;

  -- 4. Vendeur KYC validé (20 points)
  IF v_tx.vendor_id IS NOT NULL THEN
    SELECT COALESCE(kyc_status, 'pending') INTO v_vendor_kyc FROM vendors WHERE id = v_tx.vendor_id;
    IF v_vendor_kyc = 'verified' THEN
      v_score := v_score + v_weight_kyc;
      v_breakdown := v_breakdown || jsonb_build_object('vendor_kyc', jsonb_build_object('score', v_weight_kyc, 'max', v_weight_kyc, 'details', 'Vendeur KYC validé'));
    ELSE
      v_breakdown := v_breakdown || jsonb_build_object('vendor_kyc', jsonb_build_object('score', 0, 'max', v_weight_kyc, 'details', format('KYC: %s', v_vendor_kyc)));
    END IF;
  ELSE
    v_score := v_score + (v_weight_kyc / 2);
    v_breakdown := v_breakdown || jsonb_build_object('vendor_kyc', jsonb_build_object('score', v_weight_kyc / 2, 'max', v_weight_kyc, 'details', 'Paiement direct'));
  END IF;

  -- 5. Montant sous seuil (10 points)
  IF v_tx.amount <= v_max_auto_amount THEN
    v_score := v_score + v_weight_amount;
    v_breakdown := v_breakdown || jsonb_build_object('amount_check', jsonb_build_object('score', v_weight_amount, 'max', v_weight_amount, 'details', format('Montant %s GNF <= seuil', v_tx.amount)));
  ELSE
    v_breakdown := v_breakdown || jsonb_build_object('amount_check', jsonb_build_object('score', 0, 'max', v_weight_amount, 'details', format('Montant %s GNF > seuil', v_tx.amount)));
  END IF;

  -- 6. Aucune fraude passée (10 points) - gestion si table n'existe pas
  BEGIN
    SELECT COUNT(*) INTO v_fraud_count FROM fraud_alerts WHERE (user_id = v_tx.user_id OR vendor_id = v_tx.vendor_id) AND severity IN ('high', 'critical');
  EXCEPTION WHEN undefined_table THEN
    v_fraud_count := 0;
  END;
  
  IF v_fraud_count = 0 THEN
    v_score := v_score + v_weight_fraud;
    v_breakdown := v_breakdown || jsonb_build_object('no_fraud', jsonb_build_object('score', v_weight_fraud, 'max', v_weight_fraud, 'details', 'Aucune alerte fraude'));
  ELSE
    v_breakdown := v_breakdown || jsonb_build_object('no_fraud', jsonb_build_object('score', 0, 'max', v_weight_fraud, 'details', format('%s alerte(s)', v_fraud_count)));
  END IF;

  -- Décision
  IF v_score >= v_threshold_auto AND v_tx.amount <= v_max_auto_amount THEN
    v_decision := 'AUTO_RELEASE';
  ELSIF v_score >= v_threshold_temp THEN
    v_decision := 'TEMP_BLOCKED';
  ELSE
    v_decision := 'MANUAL_REVIEW';
  END IF;

  INSERT INTO payment_score_logs (transaction_id, total_score, breakdown, decision, config_snapshot)
  VALUES (p_transaction_id, v_score, v_breakdown, v_decision, v_config);

  UPDATE djomy_transactions SET 
    trust_score = v_score, 
    score_breakdown = v_breakdown,
    release_type = v_decision,
    auto_released = (v_decision = 'AUTO_RELEASE'),
    blocked_until = CASE WHEN v_decision = 'TEMP_BLOCKED' THEN NOW() + INTERVAL '2 hours' ELSE NULL END,
    updated_at = NOW()
  WHERE id = p_transaction_id;

  RETURN jsonb_build_object('score', v_score, 'breakdown', v_breakdown, 'decision', v_decision);
END;
$$;

-- 13. Fonction pour traiter le paiement selon son type
CREATE OR REPLACE FUNCTION process_payment_by_type(p_transaction_id UUID) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tx RECORD;
  v_result JSONB := '{}';
BEGIN
  SELECT * INTO v_tx FROM djomy_transactions WHERE id = p_transaction_id;
  IF v_tx IS NULL OR v_tx.status != 'SUCCESS' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Transaction non valide');
  END IF;

  CASE v_tx.payment_type
    WHEN 'ORDER_PAYMENT' THEN
      IF v_tx.auto_released THEN
        UPDATE wallets SET balance = balance + v_tx.amount WHERE user_id = v_tx.vendor_id;
      ELSE
        INSERT INTO vendor_blocked_funds (vendor_id, order_id, amount, currency, status, transaction_id)
        VALUES (v_tx.vendor_id, v_tx.reference_id, v_tx.amount, v_tx.currency, 'blocked', p_transaction_id)
        ON CONFLICT DO NOTHING;
      END IF;
      v_result := jsonb_build_object('action', 'vendor_credit', 'auto_released', v_tx.auto_released);
    WHEN 'SUBSCRIPTION' THEN
      INSERT INTO payment_subscriptions (transaction_id, vendor_id, plan_type, amount, currency, expires_at)
      VALUES (p_transaction_id, v_tx.vendor_id, COALESCE(v_tx.metadata->>'plan_type', 'premium'), v_tx.amount, v_tx.currency, NOW() + INTERVAL '30 days');
      UPDATE vendors SET subscription_plan = COALESCE(v_tx.metadata->>'plan_type', 'premium'), subscription_expires_at = NOW() + INTERVAL '30 days' WHERE id = v_tx.vendor_id;
      v_result := jsonb_build_object('action', 'subscription_activated');
    WHEN 'BOOST' THEN
      INSERT INTO payment_boosts (transaction_id, vendor_id, product_id, boost_type, amount, currency, expires_at, impressions_target)
      VALUES (p_transaction_id, v_tx.vendor_id, (v_tx.metadata->>'product_id')::UUID, COALESCE(v_tx.metadata->>'boost_type', 'standard'), v_tx.amount, v_tx.currency, NOW() + INTERVAL '7 days', COALESCE((v_tx.metadata->>'impressions')::INTEGER, 1000));
      v_result := jsonb_build_object('action', 'boost_activated');
    WHEN 'DELIVERY' THEN
      INSERT INTO payment_deliveries (transaction_id, delivery_id, driver_id, amount, currency, status, credited_at)
      VALUES (p_transaction_id, (v_tx.reference_id)::UUID, (v_tx.metadata->>'driver_id')::UUID, v_tx.amount, v_tx.currency, 'CREDITED', NOW());
      UPDATE wallets SET balance = balance + v_tx.amount WHERE user_id = (v_tx.metadata->>'driver_id')::UUID;
      v_result := jsonb_build_object('action', 'driver_credited');
    WHEN 'COMMISSION' THEN
      INSERT INTO payment_commissions (transaction_id, source_type, source_id, amount, rate, currency)
      VALUES (p_transaction_id, COALESCE(v_tx.metadata->>'source_type', 'order'), (v_tx.reference_id)::UUID, v_tx.amount, (v_tx.metadata->>'rate')::NUMERIC, v_tx.currency);
      v_result := jsonb_build_object('action', 'commission_credited');
    WHEN 'WALLET_TOPUP' THEN
      UPDATE wallets SET balance = balance + v_tx.amount WHERE user_id = v_tx.user_id;
      v_result := jsonb_build_object('action', 'wallet_topped_up');
    ELSE
      v_result := jsonb_build_object('action', 'unknown_type');
  END CASE;

  RETURN jsonb_build_object('success', TRUE, 'result', v_result);
END;
$$;

-- 14. RLS Policies
ALTER TABLE payment_score_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_score_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_boosts ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_commissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin full access on payment_score_config" ON payment_score_config;
CREATE POLICY "Admin full access on payment_score_config" ON payment_score_config FOR ALL USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo')));

DROP POLICY IF EXISTS "Admin full access on payment_score_logs" ON payment_score_logs;
CREATE POLICY "Admin full access on payment_score_logs" ON payment_score_logs FOR ALL USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('admin', 'ceo')));

DROP POLICY IF EXISTS "Vendors view own subscriptions" ON payment_subscriptions;
CREATE POLICY "Vendors view own subscriptions" ON payment_subscriptions FOR SELECT USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS "Vendors view own boosts" ON payment_boosts;
CREATE POLICY "Vendors view own boosts" ON payment_boosts FOR SELECT USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS "Drivers view own deliveries" ON payment_deliveries;
CREATE POLICY "Drivers view own deliveries" ON payment_deliveries FOR SELECT USING (driver_id = auth.uid());

-- 15. Notification admin pour review manuelle
CREATE OR REPLACE FUNCTION notify_payment_review_needed() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.release_type = 'MANUAL_REVIEW' AND (OLD.release_type IS NULL OR OLD.release_type != 'MANUAL_REVIEW') THEN
    INSERT INTO admin_notifications (notification_type, title, message, priority, related_entity_type, related_entity_id, metadata)
    VALUES ('payment_review', 'Paiement nécessite révision', format('Transaction %s - %s GNF - Score: %s', NEW.order_id, NEW.amount, NEW.trust_score), 'high', 'djomy_transaction', NEW.id::TEXT, jsonb_build_object('score', NEW.trust_score, 'breakdown', NEW.score_breakdown));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_payment_review ON djomy_transactions;
CREATE TRIGGER trigger_notify_payment_review AFTER UPDATE ON djomy_transactions FOR EACH ROW EXECUTE FUNCTION notify_payment_review_needed();