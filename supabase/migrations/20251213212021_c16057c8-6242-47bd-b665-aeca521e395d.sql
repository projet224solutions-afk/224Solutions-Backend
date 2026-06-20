-- =====================================================
-- CORRECTIFS SÉCURITÉ SYSTÈME WALLET/PAIEMENTS
-- =====================================================

-- 1. Recréer les vues financières avec SECURITY INVOKER
DROP VIEW IF EXISTS escrow_dashboard CASCADE;
CREATE VIEW escrow_dashboard WITH (security_invoker = true) AS
SELECT 
  et.id,
  et.order_id,
  et.amount,
  et.currency,
  et.status,
  et.created_at,
  et.available_to_release_at,
  et.commission_percent,
  et.commission_amount,
  payer.email AS payer_email,
  COALESCE((payer.first_name || ' ' || payer.last_name), payer.email) AS payer_name,
  receiver.email AS receiver_email,
  COALESCE((receiver.first_name || ' ' || receiver.last_name), receiver.email) AS receiver_name,
  (SELECT count(*) FROM escrow_logs WHERE escrow_logs.escrow_id = et.id) AS log_count
FROM escrow_transactions et
LEFT JOIN profiles payer ON et.payer_id = payer.id
LEFT JOIN profiles receiver ON et.receiver_id = receiver.id
ORDER BY et.created_at DESC;

-- 2. Accorder les permissions sur la vue
GRANT SELECT ON escrow_dashboard TO authenticated;

-- 3. Supprimer les doublons de fonctions wallet (garder la plus récente)
-- D'abord identifier et supprimer les anciennes versions

-- Nettoyer process_wallet_transfer_with_fees si doublon existe
DROP FUNCTION IF EXISTS process_wallet_transfer_with_fees(text, text, numeric, text) CASCADE;

-- 4. Créer une fonction de validation d'intégrité des transactions
CREATE OR REPLACE FUNCTION validate_transaction_integrity(p_transaction_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ledger_record RECORD;
  v_calculated_hash TEXT;
  v_is_valid BOOLEAN := true;
  v_issues TEXT[] := ARRAY[]::TEXT[];
BEGIN
  -- Récupérer l'enregistrement du ledger
  SELECT * INTO v_ledger_record 
  FROM financial_ledger 
  WHERE transaction_id::text = p_transaction_id;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'valid', false,
      'error', 'Transaction non trouvée dans le ledger'
    );
  END IF;
  
  -- Vérifier le hash
  v_calculated_hash := generate_ledger_hash(
    v_ledger_record.transaction_id::text,
    v_ledger_record.actor_id,
    v_ledger_record.amount,
    v_ledger_record.debit_account::uuid,
    v_ledger_record.credit_account::uuid,
    v_ledger_record.previous_hash
  );
  
  IF v_ledger_record.ledger_hash IS NOT NULL AND v_calculated_hash != v_ledger_record.ledger_hash THEN
    v_is_valid := false;
    v_issues := array_append(v_issues, 'Hash invalide - intégrité compromise');
  END IF;
  
  -- Vérifier les balances
  IF v_ledger_record.balance_after_debit < 0 THEN
    v_is_valid := false;
    v_issues := array_append(v_issues, 'Balance négative détectée');
  END IF;
  
  RETURN jsonb_build_object(
    'valid', v_is_valid,
    'transaction_id', p_transaction_id,
    'amount', v_ledger_record.amount,
    'status', v_ledger_record.validation_status,
    'issues', v_issues,
    'verified_at', now()
  );
END;
$$;

-- 5. Créer une fonction pour audit quotidien automatique
CREATE OR REPLACE FUNCTION run_daily_wallet_audit()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total_wallets INTEGER;
  v_total_balance NUMERIC;
  v_discrepancies INTEGER := 0;
  v_wallet RECORD;
  v_calculated_balance NUMERIC;
BEGIN
  SELECT COUNT(*), COALESCE(SUM(balance), 0) 
  INTO v_total_wallets, v_total_balance
  FROM wallets WHERE status = 'active';
  
  -- Vérifier chaque wallet contre le ledger
  FOR v_wallet IN SELECT id, user_id, balance FROM wallets WHERE status = 'active' LOOP
    SELECT COALESCE(
      SUM(CASE WHEN credit_account::uuid = v_wallet.user_id THEN amount ELSE 0 END) -
      SUM(CASE WHEN debit_account::uuid = v_wallet.user_id THEN amount ELSE 0 END),
      0
    ) INTO v_calculated_balance
    FROM financial_ledger
    WHERE (debit_account::uuid = v_wallet.user_id OR credit_account::uuid = v_wallet.user_id)
    AND is_valid = true;
    
    IF ABS(v_wallet.balance - v_calculated_balance) > 0.01 THEN
      v_discrepancies := v_discrepancies + 1;
      
      -- Enregistrer l'alerte
      INSERT INTO pdg_financial_alerts (
        alert_type, severity, title, message, amount, is_read
      ) VALUES (
        'balance_discrepancy', 
        CASE WHEN ABS(v_wallet.balance - v_calculated_balance) > 10000 THEN 'critical' ELSE 'warning' END,
        'Écart de balance détecté',
        format('Wallet %s: stocké=%s, calculé=%s', v_wallet.id, v_wallet.balance, v_calculated_balance),
        ABS(v_wallet.balance - v_calculated_balance),
        false
      );
    END IF;
  END LOOP;
  
  RETURN jsonb_build_object(
    'audit_date', now(),
    'total_wallets', v_total_wallets,
    'total_balance', v_total_balance,
    'discrepancies_found', v_discrepancies,
    'status', CASE WHEN v_discrepancies = 0 THEN 'HEALTHY' ELSE 'NEEDS_ATTENTION' END
  );
END;
$$;

-- 6. Accorder les permissions
GRANT EXECUTE ON FUNCTION validate_transaction_integrity(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION run_daily_wallet_audit() TO authenticated;