
-- =============================================
-- 🌍 INTERNATIONAL TRANSFER SUPPORT FOR RPC FUNCTIONS
-- Ajoute la détection de pays et les frais internationaux
-- =============================================

-- 1. Recréer preview_wallet_transfer_by_code avec logique internationale
CREATE OR REPLACE FUNCTION preview_wallet_transfer_by_code(
  p_sender_code TEXT,
  p_receiver_code TEXT,
  p_amount NUMERIC,
  p_currency VARCHAR DEFAULT 'GNF'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_sender_wallet RECORD;
  v_receiver_wallet RECORD;
  v_sender_info JSONB;
  v_receiver_info JSONB;
  v_fee_percent NUMERIC;
  v_fee_amount NUMERIC;
  v_total_debit NUMERIC;
  v_sender_country TEXT;
  v_receiver_country TEXT;
  v_sender_currency TEXT;
  v_receiver_currency TEXT;
  v_is_international BOOLEAN;
  v_commission_conversion NUMERIC := 0;
  v_frais_international NUMERIC := 0;
  v_rate NUMERIC := 1;
  v_amount_received NUMERIC;
  v_rate_lock_seconds NUMERIC := 60;
  v_commission_percent NUMERIC := 10;
  v_frais_percent NUMERIC := 2;
  v_setting RECORD;
BEGIN
  -- Trouver le wallet expéditeur
  SELECT * INTO v_sender_wallet
  FROM find_wallet_by_code(p_sender_code, p_currency);
  
  IF v_sender_wallet.wallet_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Expéditeur introuvable: ' || p_sender_code);
  END IF;
  
  -- Trouver le wallet destinataire
  SELECT * INTO v_receiver_wallet
  FROM find_wallet_by_code(p_receiver_code, p_currency);
  
  IF v_receiver_wallet.wallet_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Destinataire introuvable: ' || p_receiver_code);
  END IF;
  
  IF v_sender_wallet.wallet_id = v_receiver_wallet.wallet_id THEN
    RETURN json_build_object('success', false, 'error', 'Impossible de transférer vers votre propre compte');
  END IF;
  
  -- 🌍 Détection pays/devise depuis profiles
  SELECT COALESCE(detected_country, 'GN'), COALESCE(detected_currency, 'GNF')
  INTO v_sender_country, v_sender_currency
  FROM profiles WHERE id = v_sender_wallet.owner_id;
  
  IF v_sender_country IS NULL THEN
    v_sender_country := 'GN';
    v_sender_currency := 'GNF';
  END IF;
  
  SELECT COALESCE(detected_country, 'GN'), COALESCE(detected_currency, 'GNF')
  INTO v_receiver_country, v_receiver_currency
  FROM profiles WHERE id = v_receiver_wallet.owner_id;
  
  IF v_receiver_country IS NULL THEN
    v_receiver_country := 'GN';
    v_receiver_currency := 'GNF';
  END IF;
  
  v_is_international := (v_sender_country IS DISTINCT FROM v_receiver_country);
  
  -- Charger les paramètres internationaux
  FOR v_setting IN SELECT setting_key, setting_value FROM international_transfer_settings LOOP
    CASE v_setting.setting_key
      WHEN 'commission_conversion_percent' THEN v_commission_percent := v_setting.setting_value;
      WHEN 'frais_transaction_international_percent' THEN v_frais_percent := v_setting.setting_value;
      WHEN 'delai_verrouillage_taux_seconds' THEN v_rate_lock_seconds := v_setting.setting_value;
      ELSE NULL;
    END CASE;
  END LOOP;
  
  -- Récupérer infos expéditeur
  IF v_sender_wallet.wallet_type = 'bureau' THEN
    SELECT jsonb_build_object('id', b.id, 'name', b.bureau_code || ' - ' || b.prefecture, 'email', COALESCE(b.president_email, 'N/A'), 'phone', COALESCE(b.president_phone, 'N/A'), 'custom_id', b.bureau_code, 'type', 'bureau')
    INTO v_sender_info FROM bureau_syndicats b WHERE b.id = v_sender_wallet.owner_id;
  ELSIF v_sender_wallet.wallet_type = 'agent' THEN
    SELECT jsonb_build_object('id', a.id, 'name', a.name, 'email', COALESCE(a.email, 'N/A'), 'phone', COALESCE(a.phone, 'N/A'), 'custom_id', a.agent_code, 'type', 'agent')
    INTO v_sender_info FROM agents_management a WHERE a.id = v_sender_wallet.owner_id;
  ELSE
    SELECT jsonb_build_object('id', p.id, 'name', COALESCE(p.first_name || ' ' || p.last_name, 'Non renseigné'), 'email', COALESCE(p.email, 'N/A'), 'phone', COALESCE(p.phone, 'N/A'), 'custom_id', COALESCE(p.custom_id, p.public_id), 'type', 'user')
    INTO v_sender_info FROM profiles p WHERE p.id = v_sender_wallet.owner_id;
  END IF;
  
  -- Récupérer infos destinataire
  IF v_receiver_wallet.wallet_type = 'bureau' THEN
    SELECT jsonb_build_object('id', b.id, 'name', b.bureau_code || ' - ' || b.prefecture, 'email', COALESCE(b.president_email, 'N/A'), 'phone', COALESCE(b.president_phone, 'N/A'), 'custom_id', b.bureau_code, 'type', 'bureau')
    INTO v_receiver_info FROM bureau_syndicats b WHERE b.id = v_receiver_wallet.owner_id;
  ELSIF v_receiver_wallet.wallet_type = 'agent' THEN
    SELECT jsonb_build_object('id', a.id, 'name', a.name, 'email', COALESCE(a.email, 'N/A'), 'phone', COALESCE(a.phone, 'N/A'), 'custom_id', a.agent_code, 'type', 'agent')
    INTO v_receiver_info FROM agents_management a WHERE a.id = v_receiver_wallet.owner_id;
  ELSE
    SELECT jsonb_build_object('id', p.id, 'name', COALESCE(p.first_name || ' ' || p.last_name, 'Non renseigné'), 'email', COALESCE(p.email, 'N/A'), 'phone', COALESCE(p.phone, 'N/A'), 'custom_id', COALESCE(p.custom_id, p.public_id), 'type', 'user')
    INTO v_receiver_info FROM profiles p WHERE p.id = v_receiver_wallet.owner_id;
  END IF;
  
  -- Calculer frais
  IF v_is_international THEN
    v_commission_conversion := ROUND(p_amount * v_commission_percent / 100, 0);
    v_frais_international := ROUND(p_amount * v_frais_percent / 100, 0);
    v_fee_amount := v_commission_conversion + v_frais_international;
    v_fee_percent := v_commission_percent + v_frais_percent;
    v_total_debit := p_amount;  -- Pour international: frais déduits du montant
    
    -- Taux de change si devises différentes
    IF v_sender_currency IS DISTINCT FROM v_receiver_currency THEN
      SELECT rate INTO v_rate FROM currency_exchange_rates 
      WHERE from_currency = v_sender_currency AND to_currency = v_receiver_currency AND is_active = true
      LIMIT 1;
      IF v_rate IS NULL OR v_rate <= 0 THEN v_rate := 1; END IF;
    END IF;
    
    v_amount_received := ROUND((p_amount - v_fee_amount) * v_rate, 0);
  ELSE
    v_fee_percent := get_transfer_fee_percent();
    v_fee_amount := ROUND((p_amount * v_fee_percent) / 100, 0);
    v_total_debit := p_amount + v_fee_amount;
    v_amount_received := p_amount;
  END IF;
  
  -- Vérifier le solde
  IF v_sender_wallet.balance < v_total_debit THEN
    RETURN json_build_object('success', false, 'error', 'Solde insuffisant');
  END IF;
  
  IF v_sender_wallet.wallet_status != 'active' THEN
    RETURN json_build_object('success', false, 'error', 'Wallet expéditeur inactif');
  END IF;
  
  IF v_receiver_wallet.wallet_status != 'active' THEN
    RETURN json_build_object('success', false, 'error', 'Wallet destinataire inactif');
  END IF;
  
  RETURN json_build_object(
    'success', true,
    'sender', v_sender_info,
    'receiver', v_receiver_info,
    'amount', p_amount,
    'fee_percent', v_fee_percent,
    'fee_amount', v_fee_amount,
    'total_debit', v_total_debit,
    'amount_received', v_amount_received,
    'current_balance', v_sender_wallet.balance,
    'balance_after', v_sender_wallet.balance - v_total_debit,
    'currency', p_currency,
    'is_international', v_is_international,
    'sender_country', v_sender_country,
    'receiver_country', v_receiver_country,
    'sender_currency', v_sender_currency,
    'receiver_currency', v_receiver_currency,
    'commission_conversion', v_commission_conversion,
    'frais_international', v_frais_international,
    'rate_displayed', v_rate,
    'rate_lock_seconds', CASE WHEN v_is_international THEN v_rate_lock_seconds ELSE NULL END,
    'sender_wallet_id', v_sender_wallet.wallet_id,
    'sender_wallet_type', v_sender_wallet.wallet_type,
    'receiver_wallet_id', v_receiver_wallet.wallet_id,
    'receiver_wallet_type', v_receiver_wallet.wallet_type
  );
END;
$$;

-- 2. Recréer process_wallet_transfer_with_fees avec logique internationale
CREATE OR REPLACE FUNCTION process_wallet_transfer_with_fees(
  p_sender_code TEXT,
  p_receiver_code TEXT,
  p_amount NUMERIC,
  p_currency VARCHAR DEFAULT 'GNF',
  p_description TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_sender_id UUID;
  v_receiver_id UUID;
  v_fee_percent NUMERIC;
  v_fee_amount NUMERIC;
  v_total_debit NUMERIC;
  v_amount_to_credit NUMERIC;
  v_transaction_id UUID;
  v_sender_balance NUMERIC;
  v_sender_country TEXT;
  v_receiver_country TEXT;
  v_sender_currency TEXT;
  v_receiver_currency TEXT;
  v_is_international BOOLEAN;
  v_commission_conversion NUMERIC := 0;
  v_frais_international NUMERIC := 0;
  v_rate NUMERIC := 1;
  v_commission_percent NUMERIC := 10;
  v_frais_percent NUMERIC := 2;
  v_daily_limit NUMERIC := 50000000;
  v_daily_total NUMERIC;
  v_setting RECORD;
BEGIN
  -- Trouver l'expéditeur
  v_sender_id := find_user_by_code(p_sender_code);
  IF v_sender_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Expéditeur introuvable');
  END IF;
  
  -- Trouver le destinataire
  v_receiver_id := find_user_by_code(p_receiver_code);
  IF v_receiver_id IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Destinataire introuvable');
  END IF;
  
  IF v_sender_id = v_receiver_id THEN
    RETURN json_build_object('success', false, 'error', 'Auto-transfert impossible');
  END IF;
  
  -- 🌍 Détection pays/devise
  SELECT COALESCE(detected_country, 'GN'), COALESCE(detected_currency, 'GNF')
  INTO v_sender_country, v_sender_currency
  FROM profiles WHERE id = v_sender_id;
  
  IF v_sender_country IS NULL THEN v_sender_country := 'GN'; v_sender_currency := 'GNF'; END IF;
  
  SELECT COALESCE(detected_country, 'GN'), COALESCE(detected_currency, 'GNF')
  INTO v_receiver_country, v_receiver_currency
  FROM profiles WHERE id = v_receiver_id;
  
  IF v_receiver_country IS NULL THEN v_receiver_country := 'GN'; v_receiver_currency := 'GNF'; END IF;
  
  v_is_international := (v_sender_country IS DISTINCT FROM v_receiver_country);
  
  -- Charger les paramètres
  FOR v_setting IN SELECT setting_key, setting_value FROM international_transfer_settings LOOP
    CASE v_setting.setting_key
      WHEN 'commission_conversion_percent' THEN v_commission_percent := v_setting.setting_value;
      WHEN 'frais_transaction_international_percent' THEN v_frais_percent := v_setting.setting_value;
      WHEN 'limite_transfert_quotidien' THEN v_daily_limit := v_setting.setting_value;
      ELSE NULL;
    END CASE;
  END LOOP;
  
  -- Vérifier limite quotidienne si international
  IF v_is_international THEN
    SELECT COALESCE(SUM(amount), 0) INTO v_daily_total
    FROM enhanced_transactions
    WHERE sender_id = v_sender_id
      AND status = 'completed'
      AND created_at >= CURRENT_DATE::timestamptz;
    
    IF v_daily_total + p_amount > v_daily_limit THEN
      RETURN json_build_object('success', false, 'error', 'Limite quotidienne de transfert international atteinte');
    END IF;
  END IF;
  
  -- Calculer frais
  IF v_is_international THEN
    v_commission_conversion := ROUND(p_amount * v_commission_percent / 100, 0);
    v_frais_international := ROUND(p_amount * v_frais_percent / 100, 0);
    v_fee_amount := v_commission_conversion + v_frais_international;
    v_fee_percent := v_commission_percent + v_frais_percent;
    v_total_debit := p_amount;
    
    IF v_sender_currency IS DISTINCT FROM v_receiver_currency THEN
      SELECT rate INTO v_rate FROM currency_exchange_rates
      WHERE from_currency = v_sender_currency AND to_currency = v_receiver_currency AND is_active = true
      LIMIT 1;
      IF v_rate IS NULL OR v_rate <= 0 THEN v_rate := 1; END IF;
    END IF;
    
    v_amount_to_credit := ROUND((p_amount - v_fee_amount) * v_rate, 0);
  ELSE
    v_fee_percent := get_transfer_fee_percent();
    v_fee_amount := ROUND((p_amount * v_fee_percent) / 100, 0);
    v_total_debit := p_amount + v_fee_amount;
    v_amount_to_credit := p_amount;
  END IF;
  
  -- Vérifier le solde
  SELECT balance INTO v_sender_balance 
  FROM wallets 
  WHERE user_id = v_sender_id AND currency = p_currency;
  
  IF v_sender_balance IS NULL THEN
    RETURN json_build_object('success', false, 'error', 'Wallet expéditeur introuvable');
  END IF;
  
  IF v_sender_balance < v_total_debit THEN
    RETURN json_build_object('success', false, 'error', 'Solde insuffisant', 'required', v_total_debit, 'current', v_sender_balance);
  END IF;
  
  -- Créer la transaction
  INSERT INTO enhanced_transactions (
    sender_id, receiver_id, amount, currency, method, metadata, status
  )
  VALUES (
    v_sender_id, v_receiver_id, p_amount, p_currency, 'wallet',
    jsonb_build_object(
      'description', COALESCE(p_description, ''),
      'fee_amount', v_fee_amount,
      'fee_percent', v_fee_percent,
      'total_debit', v_total_debit,
      'is_international', v_is_international,
      'sender_country', v_sender_country,
      'receiver_country', v_receiver_country,
      'sender_currency', v_sender_currency,
      'receiver_currency', v_receiver_currency,
      'commission_conversion', v_commission_conversion,
      'frais_international', v_frais_international,
      'rate_used', v_rate,
      'amount_credited', v_amount_to_credit
    ),
    'pending'
  )
  RETURNING id INTO v_transaction_id;
  
  -- Débiter l'expéditeur
  UPDATE wallets 
  SET balance = balance - v_total_debit, updated_at = now()
  WHERE user_id = v_sender_id AND currency = p_currency;
  
  -- Créditer le destinataire
  IF v_is_international AND v_sender_currency IS DISTINCT FROM v_receiver_currency THEN
    -- International avec conversion: créditer dans la devise du destinataire
    INSERT INTO wallets (user_id, balance, currency, status)
    VALUES (v_receiver_id, v_amount_to_credit, v_receiver_currency, 'active')
    ON CONFLICT (user_id, currency) 
    DO UPDATE SET balance = wallets.balance + v_amount_to_credit, updated_at = now();
  ELSE
    -- Local ou même devise: créditer normalement
    INSERT INTO wallets (user_id, balance, currency, status)
    VALUES (v_receiver_id, v_amount_to_credit, p_currency, 'active')
    ON CONFLICT (user_id, currency) 
    DO UPDATE SET balance = wallets.balance + v_amount_to_credit, updated_at = now();
  END IF;
  
  -- Marquer comme complétée
  UPDATE enhanced_transactions 
  SET status = 'completed', updated_at = now()
  WHERE id = v_transaction_id;
  
  RETURN json_build_object(
    'success', true,
    'transaction_id', v_transaction_id,
    'amount', p_amount,
    'fee_amount', v_fee_amount,
    'total_debit', v_total_debit,
    'amount_received', v_amount_to_credit,
    'is_international', v_is_international,
    'sender_country', v_sender_country,
    'receiver_country', v_receiver_country,
    'rate_used', v_rate,
    'currency_sent', v_sender_currency,
    'currency_received', CASE WHEN v_is_international AND v_sender_currency IS DISTINCT FROM v_receiver_currency THEN v_receiver_currency ELSE p_currency END
  );
END;
$$;

-- Permissions
GRANT EXECUTE ON FUNCTION preview_wallet_transfer_by_code(TEXT, TEXT, NUMERIC, VARCHAR) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION process_wallet_transfer_with_fees(TEXT, TEXT, NUMERIC, VARCHAR, TEXT) TO authenticated, anon;
