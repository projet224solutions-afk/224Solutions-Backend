-- ============================================================================
-- 💸 PRIMITIF DE TRANSFERT : qui porte la commission (arbitrage PDG 08/08/2026)
-- ----------------------------------------------------------------------------
-- CONTEXTE : le prélèvement sous mandat exige que le partenaire soit débité du
-- montant EXACT qu'il a autorisé — frais compris. Or la branche LOCALE du
-- primitif ajoutait les frais au débit de l'expéditeur.
--
-- Deux règles se contredisaient : « un seul primitif pour tout le monde » et
-- « le partenaire ne paie jamais les frais d'un prélèvement qu'il subit ».
-- Arbitrage rendu : ÉTENDRE le primitif d'un paramètre, plutôt que créer un
-- second chemin d'argent.
--
-- `p_commission_bearer` :
--   'sender'    (DÉFAUT) → comportement historique, INCHANGÉ pour tous les
--                appelants existants qui ne passent pas le paramètre ;
--   'recipient' → débit = montant exact, crédit = converti − commission.
--
-- ⚠️ CONSTAT en lisant le code : la branche INTERNATIONALE fait DÉJÀ porter les
-- frais au destinataire (`v_total_debit := p_amount`, crédit net de frais). Le
-- conflit ne concernait donc que les transferts LOCAUX. Une seule branche
-- change ; l'international n'est pas touché, ce qui écarte tout risque de
-- régression sur les corridors existants.
--
-- Le DROP est nécessaire : ajouter un paramètre crée sinon une SURCHARGE, et
-- les appels à 5 arguments deviendraient ambigus (erreur PostgreSQL).
-- La définition ci-dessous est la définition EXACTE extraite de la base, à
-- laquelle seules les 4 modifications décrites ont été appliquées.
-- ============================================================================

DROP FUNCTION IF EXISTS public.process_wallet_transfer_with_fees_core(text, text, numeric, character varying, text);

CREATE OR REPLACE FUNCTION public.process_wallet_transfer_with_fees_core(p_sender_code text, p_receiver_code text, p_amount numeric, p_currency character varying DEFAULT 'GNF'::character varying, p_description text DEFAULT NULL::text, p_commission_bearer text DEFAULT 'sender'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
  IF p_commission_bearer NOT IN ('sender', 'recipient') THEN
    RETURN json_build_object('success', false, 'error', 'commission_bearer invalide',
                             'error_code', 'BAD_COMMISSION_BEARER');
  END IF;

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
    -- 💡 Qui porte la commission (arbitrage PDG 08/08/2026) :
    --   'sender'    (DÉFAUT) → débit = montant + frais, crédit = montant.
    --                Comportement historique, inchangé pour tous les appelants.
    --   'recipient' → débit = montant EXACT, crédit = montant − frais.
    --                Indispensable au prélèvement sous mandat : le partenaire
    --                ne doit jamais être débité d'un centime de plus que ce
    --                qu'il a autorisé, frais compris.
    -- NB : la branche INTERNATIONALE ci-dessus fait déjà porter les frais au
    -- destinataire (v_total_debit := p_amount) — elle n'a donc pas à changer.
    IF p_commission_bearer = 'recipient' THEN
      v_total_debit      := p_amount;
      v_amount_to_credit := p_amount - v_fee_amount;
    ELSE
      v_total_debit      := p_amount + v_fee_amount;
      v_amount_to_credit := p_amount;
    END IF;
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
      'amount_credited', v_amount_to_credit,
      'commission_bearer', p_commission_bearer
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
$function$;

REVOKE ALL ON FUNCTION public.process_wallet_transfer_with_fees_core(text, text, numeric, character varying, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_wallet_transfer_with_fees_core(text, text, numeric, character varying, text, text) TO authenticated, service_role;

SELECT 'Primitif étendu : p_commission_bearer (défaut sender = comportement inchangé).' AS status;
