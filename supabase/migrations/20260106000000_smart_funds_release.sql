-- =====================================================
-- SYSTEME DE DEBLOCAGE DE FONDS INTELLIGENT - 224SOLUTIONS
-- =====================================================
-- Date: 2026-01-06
-- Description: Implementation d'un systeme de Trust Score et de liberation
--              progressive des fonds avec validation hybride (auto + admin)
-- =====================================================

-- 1. ENUMS POUR LE SYSTEME
-- =====================================================

CREATE TYPE risk_level_enum AS ENUM ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL');
CREATE TYPE decision_enum AS ENUM ('AUTO_APPROVED', 'ADMIN_REVIEW', 'BLOCKED');
CREATE TYPE release_status_enum AS ENUM ('PENDING', 'SCHEDULED', 'RELEASED', 'REJECTED', 'DISPUTED');
CREATE TYPE fraud_signal_enum AS ENUM (
  'UNUSUAL_AMOUNT',
  'NEW_SELLER',
  'HIGH_VELOCITY',
  'RISKY_COUNTRY',
  'SUSPICIOUS_PATTERN',
  'CARD_TESTING',
  'DEVICE_MISMATCH'
);

-- 2. TABLE : EVALUATION DES RISQUES DE PAIEMENT
-- =====================================================

CREATE TABLE IF NOT EXISTS payment_risk_assessments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES stripe_transactions(id) ON DELETE CASCADE,
  
  -- Trust Score (0-100)
  trust_score INTEGER NOT NULL CHECK (trust_score >= 0 AND trust_score <= 100),
  risk_level risk_level_enum NOT NULL,
  
  -- Facteurs de score detailles
  user_age_days INTEGER,
  user_age_score INTEGER DEFAULT 0,
  
  card_usage_count INTEGER,
  card_history_score INTEGER DEFAULT 0,
  
  kyc_verified BOOLEAN DEFAULT false,
  kyc_score INTEGER DEFAULT 0,
  
  amount_deviation DECIMAL(5,2),
  amount_risk_score INTEGER DEFAULT 0,
  
  chargeback_history INTEGER DEFAULT 0,
  chargeback_score INTEGER DEFAULT 0,
  
  -- Blocages automatiques
  auto_blocked BOOLEAN DEFAULT false,
  block_reasons TEXT[] DEFAULT ARRAY[]::TEXT[],
  
  -- Decision finale
  decision decision_enum NOT NULL,
  decision_made_at TIMESTAMPTZ DEFAULT NOW(),
  decision_expires_at TIMESTAMPTZ,
  
  -- Controle aleatoire (1-5%)
  random_review BOOLEAN DEFAULT false,
  random_seed DECIMAL(5,4),
  
  -- Metadonnees
  assessment_version TEXT DEFAULT '1.0.0',
  details JSONB DEFAULT '{}'::jsonb,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index pour performance
CREATE INDEX idx_risk_assessments_transaction ON payment_risk_assessments(transaction_id);
CREATE INDEX idx_risk_assessments_decision ON payment_risk_assessments(decision);
CREATE INDEX idx_risk_assessments_risk_level ON payment_risk_assessments(risk_level);
CREATE INDEX idx_risk_assessments_created ON payment_risk_assessments(created_at DESC);

-- 3. TABLE : PLANIFICATION DU DEBLOCAGE DES FONDS
-- =====================================================

CREATE TABLE IF NOT EXISTS funds_release_schedule (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES stripe_transactions(id) ON DELETE CASCADE,
  wallet_id UUID NOT NULL REFERENCES wallets(id),
  
  -- Montants en centimes
  amount_held INTEGER NOT NULL,
  amount_to_release INTEGER NOT NULL,
  
  -- Planification temporelle
  held_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  scheduled_release_at TIMESTAMPTZ NOT NULL,
  released_at TIMESTAMPTZ,
  
  -- Statut de liberation
  status release_status_enum DEFAULT 'PENDING',
  
  -- Override manuel par admin
  approved_by UUID REFERENCES profiles(id),
  approved_at TIMESTAMPTZ,
  
  rejected_by UUID REFERENCES profiles(id),
  rejected_at TIMESTAMPTZ,
  rejection_reason TEXT,
  
  -- Metadonnees
  release_type TEXT DEFAULT 'AUTO', -- AUTO, MANUAL, FORCED
  notes TEXT,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index pour performance
CREATE INDEX idx_release_schedule_transaction ON funds_release_schedule(transaction_id);
CREATE INDEX idx_release_schedule_wallet ON funds_release_schedule(wallet_id);
CREATE INDEX idx_release_schedule_status ON funds_release_schedule(status);
CREATE INDEX idx_release_schedule_scheduled ON funds_release_schedule(scheduled_release_at);
CREATE INDEX idx_release_schedule_pending ON funds_release_schedule(status, scheduled_release_at) 
  WHERE status = 'SCHEDULED';

-- 4. TABLE : SIGNAUX DE FRAUDE
-- =====================================================

CREATE TABLE IF NOT EXISTS payment_fraud_signals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id UUID NOT NULL REFERENCES stripe_transactions(id) ON DELETE CASCADE,
  
  -- Type de signal
  signal_type fraud_signal_enum NOT NULL,
  severity INTEGER CHECK (severity BETWEEN 1 AND 10),
  
  -- Details du signal
  description TEXT NOT NULL,
  details JSONB DEFAULT '{}'::jsonb,
  
  -- Resolution
  resolved BOOLEAN DEFAULT false,
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES profiles(id),
  resolution_notes TEXT,
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index pour performance
CREATE INDEX idx_fraud_signals_transaction ON payment_fraud_signals(transaction_id);
CREATE INDEX idx_fraud_signals_type ON payment_fraud_signals(signal_type);
CREATE INDEX idx_fraud_signals_unresolved ON payment_fraud_signals(resolved, created_at DESC) 
  WHERE NOT resolved;

-- 5. TABLE : HISTORIQUE DES CHARGEBACKS
-- =====================================================

CREATE TABLE IF NOT EXISTS chargeback_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_charge_id TEXT NOT NULL,
  buyer_id UUID REFERENCES profiles(id),
  seller_id UUID REFERENCES profiles(id),
  
  amount INTEGER NOT NULL,
  currency TEXT DEFAULT 'XOF',
  
  reason TEXT,
  status TEXT NOT NULL, -- pending, won, lost
  
  disputed_at TIMESTAMPTZ NOT NULL,
  resolved_at TIMESTAMPTZ,
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index
CREATE INDEX idx_chargeback_buyer ON chargeback_history(buyer_id);
CREATE INDEX idx_chargeback_seller ON chargeback_history(seller_id);
CREATE INDEX idx_chargeback_status ON chargeback_history(status);

-- 6. FONCTION : CALCULER LE TRUST SCORE
-- =====================================================

DROP FUNCTION IF EXISTS calculate_payment_trust_score CASCADE;

CREATE OR REPLACE FUNCTION calculate_payment_trust_score(
  p_transaction_id UUID,
  p_buyer_id UUID,
  p_seller_id UUID,
  p_amount INTEGER,
  p_card_last4 TEXT
) RETURNS JSONB AS $$
DECLARE
  v_score INTEGER := 0;
  v_user_age_days INTEGER;
  v_user_age_score INTEGER := 0;
  v_card_usage_count INTEGER;
  v_card_history_score INTEGER := 0;
  v_kyc_verified BOOLEAN;
  v_kyc_score INTEGER := 0;
  v_seller_avg_amount DECIMAL;
  v_amount_deviation DECIMAL;
  v_amount_risk_score INTEGER := 0;
  v_chargeback_count INTEGER;
  v_chargeback_score INTEGER := 0;
  v_seller_age_days INTEGER;
  v_risk_level risk_level_enum;
  v_decision decision_enum;
  v_auto_blocked BOOLEAN := false;
  v_block_reasons TEXT[] := ARRAY[]::TEXT[];
  v_random_seed DECIMAL;
  v_random_review BOOLEAN := false;
BEGIN
  -- 1. AGE DE L'UTILISATEUR ACHETEUR (0-20 points)
  SELECT EXTRACT(DAY FROM NOW() - created_at)
  INTO v_user_age_days
  FROM profiles
  WHERE id = p_buyer_id;
  
  IF v_user_age_days > 90 THEN
    v_user_age_score := 20;
  ELSIF v_user_age_days > 30 THEN
    v_user_age_score := 15;
  ELSIF v_user_age_days > 7 THEN
    v_user_age_score := 10;
  ELSE
    v_user_age_score := 5;
  END IF;
  
  v_score := v_score + v_user_age_score;
  
  -- 2. HISTORIQUE DE LA CARTE (0-20 points)
  SELECT COUNT(*)
  INTO v_card_usage_count
  FROM stripe_transactions
  WHERE buyer_id = p_buyer_id
    AND last4 = p_card_last4
    AND payment_status = 'SUCCEEDED';
  
  IF v_card_usage_count > 10 THEN
    v_card_history_score := 20;
  ELSIF v_card_usage_count > 5 THEN
    v_card_history_score := 15;
  ELSIF v_card_usage_count > 2 THEN
    v_card_history_score := 10;
  ELSE
    v_card_history_score := 5;
  END IF;
  
  v_score := v_score + v_card_history_score;
  
  -- 3. KYC VENDEUR VERIFIE (0-30 points)
  SELECT (status = 'verified')
  INTO v_kyc_verified
  FROM vendor_kyc
  WHERE vendor_id = p_seller_id
  LIMIT 1;
  
  IF COALESCE(v_kyc_verified, false) THEN
    v_kyc_score := 30;
  END IF;
  
  v_score := v_score + v_kyc_score;
  
  -- 4. MONTANT DANS LA MOYENNE (0-20 points)
  SELECT AVG(amount), STDDEV(amount)
  INTO v_seller_avg_amount
  FROM stripe_transactions
  WHERE seller_id = p_seller_id
    AND payment_status = 'SUCCEEDED'
    AND created_at > NOW() - INTERVAL '30 days';
  
  IF v_seller_avg_amount IS NOT NULL AND v_seller_avg_amount > 0 THEN
    v_amount_deviation := ABS(p_amount - v_seller_avg_amount) / v_seller_avg_amount;
    
    IF v_amount_deviation < 0.5 THEN
      v_amount_risk_score := 20;
    ELSIF v_amount_deviation < 1.0 THEN
      v_amount_risk_score := 15;
    ELSIF v_amount_deviation < 2.0 THEN
      v_amount_risk_score := 10;
    ELSE
      v_amount_risk_score := 5;
    END IF;
  ELSE
    v_amount_risk_score := 10; -- Premiere vente, score moyen
  END IF;
  
  v_score := v_score + v_amount_risk_score;
  
  -- 5. AUCUN CHARGEBACK (0-10 points)
  SELECT COUNT(*)
  INTO v_chargeback_count
  FROM chargeback_history
  WHERE seller_id = p_seller_id;
  
  IF v_chargeback_count = 0 THEN
    v_chargeback_score := 10;
  ELSIF v_chargeback_count <= 2 THEN
    v_chargeback_score := 5;
  ELSE
    v_chargeback_score := 0;
  END IF;
  
  v_score := v_score + v_chargeback_score;
  
  -- VERIFICATIONS DE BLOCAGE AUTOMATIQUE
  
  -- Blocage 1: Vendeur trop recent (<7 jours)
  SELECT EXTRACT(DAY FROM NOW() - created_at)
  INTO v_seller_age_days
  FROM profiles
  WHERE id = p_seller_id;
  
  IF v_seller_age_days < 7 THEN
    v_auto_blocked := true;
    v_block_reasons := array_append(v_block_reasons, 'Vendeur cree il y a moins de 7 jours');
    v_score := 0; -- Score force a 0
  END IF;
  
  -- Blocage 2: Montant anormalement eleve (>5x moyenne)
  IF v_seller_avg_amount IS NOT NULL AND p_amount > v_seller_avg_amount * 5 THEN
    v_auto_blocked := true;
    v_block_reasons := array_append(v_block_reasons, 'Montant 5x superieur a la moyenne du vendeur');
    v_score := 0;
  END IF;
  
  -- DETERMINATION DU NIVEAU DE RISQUE
  IF v_auto_blocked OR v_score < 50 THEN
    v_risk_level := 'CRITICAL';
  ELSIF v_score < 70 THEN
    v_risk_level := 'HIGH';
  ELSIF v_score < 85 THEN
    v_risk_level := 'MEDIUM';
  ELSE
    v_risk_level := 'LOW';
  END IF;
  
  -- DECISION FINALE
  IF v_auto_blocked THEN
    v_decision := 'BLOCKED';
  ELSIF v_score >= 80 THEN
    v_decision := 'AUTO_APPROVED';
  ELSE
    v_decision := 'ADMIN_REVIEW';
  END IF;
  
  -- CONTROLE ALEATOIRE (3% des AUTO_APPROVED)
  IF v_decision = 'AUTO_APPROVED' THEN
    v_random_seed := random();
    IF v_random_seed < 0.03 THEN -- 3%
      v_random_review := true;
      v_decision := 'ADMIN_REVIEW';
    END IF;
  END IF;
  
  -- RETOURNER TOUTES LES DONNEES
  RETURN jsonb_build_object(
    'trust_score', v_score,
    'risk_level', v_risk_level,
    'decision', v_decision,
    'auto_blocked', v_auto_blocked,
    'block_reasons', v_block_reasons,
    'random_review', v_random_review,
    'random_seed', v_random_seed,
    'factors', jsonb_build_object(
      'user_age_days', v_user_age_days,
      'user_age_score', v_user_age_score,
      'card_usage_count', v_card_usage_count,
      'card_history_score', v_card_history_score,
      'kyc_verified', COALESCE(v_kyc_verified, false),
      'kyc_score', v_kyc_score,
      'amount_deviation', v_amount_deviation,
      'amount_risk_score', v_amount_risk_score,
      'chargeback_count', v_chargeback_count,
      'chargeback_score', v_chargeback_score,
      'seller_age_days', v_seller_age_days
    )
  );
END;
$$ LANGUAGE plpgsql;

-- 7. FONCTION : PLANIFIER LA LIBERATION DES FONDS
-- =====================================================

DROP FUNCTION IF EXISTS schedule_funds_release CASCADE;

CREATE OR REPLACE FUNCTION schedule_funds_release(
  p_transaction_id UUID,
  p_wallet_id UUID,
  p_amount INTEGER,
  p_trust_score INTEGER
) RETURNS UUID AS $$
DECLARE
  v_delay_minutes INTEGER;
  v_release_id UUID;
BEGIN
  -- Determiner le delai selon le trust score
  IF p_trust_score >= 90 THEN
    v_delay_minutes := 30;  -- 30 minutes pour scores tres eleves
  ELSIF p_trust_score >= 80 THEN
    v_delay_minutes := 60;  -- 1 heure pour scores eleves
  ELSIF p_trust_score >= 70 THEN
    v_delay_minutes := 90;  -- 1h30 pour scores moyens
  ELSE
    v_delay_minutes := 120; -- 2 heures pour scores faibles
  END IF;
  
  -- Creer l'entree de planification
  INSERT INTO funds_release_schedule (
    transaction_id,
    wallet_id,
    amount_held,
    amount_to_release,
    held_at,
    scheduled_release_at,
    status,
    release_type
  ) VALUES (
    p_transaction_id,
    p_wallet_id,
    p_amount,
    p_amount,
    NOW(),
    NOW() + (v_delay_minutes || ' minutes')::INTERVAL,
    'SCHEDULED',
    'AUTO'
  )
  RETURNING id INTO v_release_id;
  
  RETURN v_release_id;
END;
$$ LANGUAGE plpgsql;

-- 8. FONCTION : LIBERER LES FONDS PLANIFIES
-- =====================================================

DROP FUNCTION IF EXISTS release_scheduled_funds CASCADE;

CREATE OR REPLACE FUNCTION release_scheduled_funds(
  p_release_id UUID
) RETURNS BOOLEAN AS $$
DECLARE
  v_schedule funds_release_schedule%ROWTYPE;
  v_transaction stripe_transactions%ROWTYPE;
BEGIN
  -- Recuperer le schedule avec verrou
  SELECT * INTO v_schedule
  FROM funds_release_schedule
  WHERE id = p_release_id
  FOR UPDATE;
  
  -- Verifications
  IF v_schedule.status != 'SCHEDULED' THEN
    RAISE EXCEPTION 'Release already processed: %', v_schedule.status;
  END IF;
  
  IF v_schedule.scheduled_release_at > NOW() THEN
    RAISE EXCEPTION 'Release not yet scheduled: %', v_schedule.scheduled_release_at;
  END IF;
  
  -- Recuperer la transaction
  SELECT * INTO v_transaction
  FROM stripe_transactions
  WHERE id = v_schedule.transaction_id;
  
  -- Transferer de pending_balance vers available_balance
  UPDATE wallets
  SET 
    pending_balance = pending_balance - v_schedule.amount_to_release,
    available_balance = available_balance + v_schedule.amount_to_release,
    updated_at = NOW()
  WHERE id = v_schedule.wallet_id;
  
  -- Creer une entree wallet_transactions
  INSERT INTO wallet_transactions (
    wallet_id,
    type,
    amount,
    balance_before,
    balance_after,
    description,
    metadata,
    stripe_transaction_id
  )
  SELECT
    v_schedule.wallet_id,
    'CREDIT',
    v_schedule.amount_to_release,
    w.available_balance - v_schedule.amount_to_release,
    w.available_balance,
    'Liberation automatique des fonds (Trust Score valide)',
    jsonb_build_object(
      'release_id', v_schedule.id,
      'transaction_id', v_schedule.transaction_id,
      'release_type', 'AUTO'
    ),
    v_schedule.transaction_id
  FROM wallets w
  WHERE w.id = v_schedule.wallet_id;
  
  -- Mettre a jour le schedule
  UPDATE funds_release_schedule
  SET
    status = 'RELEASED',
    released_at = NOW(),
    updated_at = NOW()
  WHERE id = p_release_id;
  
  RETURN true;
END;
$$ LANGUAGE plpgsql;

-- 9. FONCTION : APPROUVER MANUELLEMENT (ADMIN)
-- =====================================================

DROP FUNCTION IF EXISTS admin_approve_payment CASCADE;

CREATE OR REPLACE FUNCTION admin_approve_payment(
  p_release_id UUID,
  p_admin_id UUID,
  p_notes TEXT DEFAULT NULL
) RETURNS BOOLEAN AS $$
BEGIN
  -- Mettre a jour le schedule
  UPDATE funds_release_schedule
  SET
    status = 'SCHEDULED',
    scheduled_release_at = NOW(), -- Liberation immediate
    approved_by = p_admin_id,
    approved_at = NOW(),
    notes = p_notes,
    release_type = 'MANUAL',
    updated_at = NOW()
  WHERE id = p_release_id
    AND status = 'PENDING';
  
  -- Appeler la fonction de liberation
  PERFORM release_scheduled_funds(p_release_id);
  
  RETURN true;
END;
$$ LANGUAGE plpgsql;

-- 10. FONCTION : REJETER UN PAIEMENT (ADMIN)
-- =====================================================

DROP FUNCTION IF EXISTS admin_reject_payment CASCADE;

CREATE OR REPLACE FUNCTION admin_reject_payment(
  p_release_id UUID,
  p_admin_id UUID,
  p_reason TEXT
) RETURNS BOOLEAN AS $$
BEGIN
  UPDATE funds_release_schedule
  SET
    status = 'REJECTED',
    rejected_by = p_admin_id,
    rejected_at = NOW(),
    rejection_reason = p_reason,
    updated_at = NOW()
  WHERE id = p_release_id
    AND status IN ('PENDING', 'SCHEDULED');
  
  -- TODO: Initier le remboursement via Stripe API
  
  RETURN true;
END;
$$ LANGUAGE plpgsql;

-- 11. VUE : FILE D'ATTENTE ADMIN
-- =====================================================

CREATE OR REPLACE VIEW admin_payment_review_queue AS
SELECT
  st.id AS transaction_id,
  st.stripe_payment_intent_id,
  st.amount,
  st.seller_net_amount,
  st.created_at AS payment_created_at,
  
  pra.trust_score,
  pra.risk_level,
  pra.decision,
  pra.random_review,
  pra.auto_blocked,
  pra.block_reasons,
  
  frs.id AS release_id,
  frs.scheduled_release_at,
  frs.status AS release_status,
  
  seller.email AS seller_email,
  seller.full_name AS seller_name,
  buyer.email AS buyer_email,
  buyer.full_name AS buyer_name,
  
  vk.status AS seller_kyc_status,
  
  COALESCE(
    (SELECT COUNT(*) FROM payment_fraud_signals 
     WHERE transaction_id = st.id AND NOT resolved),
    0
  ) AS unresolved_fraud_signals
  
FROM stripe_transactions st
LEFT JOIN payment_risk_assessments pra ON pra.transaction_id = st.id
LEFT JOIN funds_release_schedule frs ON frs.transaction_id = st.id
LEFT JOIN profiles seller ON seller.id = st.seller_id
LEFT JOIN profiles buyer ON buyer.id = st.buyer_id
LEFT JOIN vendor_kyc vk ON vk.vendor_id = st.seller_id
WHERE pra.decision = 'ADMIN_REVIEW'
  AND frs.status = 'PENDING'
ORDER BY st.created_at DESC;

-- 12. RLS POLICIES
-- =====================================================

-- RLS pour payment_risk_assessments
ALTER TABLE payment_risk_assessments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Les admins peuvent tout voir" ON payment_risk_assessments
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role = 'admin'
    )
  );

CREATE POLICY "Les vendeurs voient leurs propres evaluations" ON payment_risk_assessments
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM stripe_transactions st
      WHERE st.id = payment_risk_assessments.transaction_id
        AND st.seller_id = auth.uid()
    )
  );

-- RLS pour funds_release_schedule
ALTER TABLE funds_release_schedule ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Les admins peuvent tout voir" ON funds_release_schedule
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role = 'admin'
    )
  );

CREATE POLICY "Les vendeurs voient leurs propres liberations" ON funds_release_schedule
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM wallets w
      WHERE w.id = funds_release_schedule.wallet_id
        AND w.user_id = auth.uid()
    )
  );

-- RLS pour payment_fraud_signals
ALTER TABLE payment_fraud_signals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Seuls les admins peuvent voir les signaux de fraude" ON payment_fraud_signals
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role = 'admin'
    )
  );

-- 13. COMMENTAIRES
-- =====================================================

COMMENT ON TABLE payment_risk_assessments IS 'Evaluation du risque pour chaque transaction Stripe avec Trust Score (0-100)';
COMMENT ON TABLE funds_release_schedule IS 'Planification du deblocage progressif des fonds avec smart delay';
COMMENT ON TABLE payment_fraud_signals IS 'Signaux de fraude detectes automatiquement ou manuellement';
COMMENT ON TABLE chargeback_history IS 'Historique des litiges/chargebacks pour calcul du Trust Score';

COMMENT ON FUNCTION calculate_payment_trust_score IS 'Calcule le Trust Score (0-100) base sur 5 facteurs: age utilisateur, historique carte, KYC vendeur, montant normal, pas de chargeback';
COMMENT ON FUNCTION schedule_funds_release IS 'Planifie la liberation des fonds avec delai intelligent (30min-2h) selon le Trust Score';
COMMENT ON FUNCTION release_scheduled_funds IS 'Libere automatiquement les fonds planifies (appele par CRON job)';
COMMENT ON FUNCTION admin_approve_payment IS 'Permet a un admin d''approuver manuellement une transaction en attente de review';
COMMENT ON FUNCTION admin_reject_payment IS 'Permet a un admin de rejeter une transaction et d''initier un remboursement';

-- =====================================================
-- FIN DE LA MIGRATION
-- =====================================================
