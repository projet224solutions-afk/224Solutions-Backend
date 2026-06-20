-- =====================================================
-- FIX: Correction du nom de colonne dans calculate_payment_trust_score
-- =====================================================
-- Date: 2026-01-06
-- Fix: payment_status -> status
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
    AND status = 'SUCCEEDED';
  
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
    AND status = 'SUCCEEDED'
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
    v_score := 0;
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

COMMENT ON FUNCTION calculate_payment_trust_score IS 'Calcule le Trust Score (0-100) base sur 5 facteurs: age utilisateur, historique carte, KYC vendeur, montant normal, pas de chargeback';

-- =====================================================
-- FIN DU FIX
-- =====================================================
