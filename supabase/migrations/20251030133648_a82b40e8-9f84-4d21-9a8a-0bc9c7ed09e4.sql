-- Insérer les revenus manquants pour les transactions existantes avec frais
INSERT INTO platform_revenue (revenue_type, amount, source_transaction_id, metadata, created_at)
SELECT 
  'transfer_fee',
  (metadata->>'fee_amount')::DECIMAL,
  id,
  jsonb_build_object(
    'sender_id', sender_id,
    'receiver_id', receiver_id,
    'transfer_amount', amount,
    'fee_percent', (metadata->>'fee_percent')::DECIMAL
  ),
  created_at
FROM enhanced_transactions
WHERE method = 'wallet'
  AND status = 'completed'
  AND metadata ? 'fee_amount'
  AND id NOT IN (SELECT source_transaction_id FROM platform_revenue WHERE source_transaction_id IS NOT NULL)
ON CONFLICT DO NOTHING;

-- Corriger le trigger pour utiliser le bon nom de colonne
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
    INSERT INTO platform_revenue (revenue_type, amount, source_transaction_id, metadata)
    VALUES (
      'transfer_fee',
      v_fee_amount,
      NEW.id,
      jsonb_build_object(
        'sender_id', NEW.sender_id,
        'receiver_id', NEW.receiver_id,
        'transfer_amount', NEW.amount,
        'fee_percent', (NEW.metadata->>'fee_percent')::DECIMAL
      )
    )
    ON CONFLICT DO NOTHING;
  END IF;
  
  RETURN NEW;
END;
$$;