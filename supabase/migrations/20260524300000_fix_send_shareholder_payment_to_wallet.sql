-- ============================================================================
-- Fix: send_shareholder_payment_to_wallet
-- Problèmes corrigés:
--   1. v_wallet_id UUID → BIGINT (wallets.id est BIGINT)
--   2. v_tx_id UUID → BIGINT (wallet_transactions.id est BIGINT)
--   3. INSERT wallet_transactions: colonnes correctes (receiver_wallet_id, etc.)
--   4. shareholder_payments.wallet_transaction_id UUID → BIGINT
-- ============================================================================

-- Étape 1 : corriger le type de wallet_transaction_id dans shareholder_payments
ALTER TABLE public.shareholder_payments
  ALTER COLUMN wallet_transaction_id TYPE BIGINT
  USING NULL;

-- Étape 2 : remplacer la fonction avec les bons types
CREATE OR REPLACE FUNCTION public.send_shareholder_payment_to_wallet(
  p_payment_id UUID,
  p_actor_id   UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_payment          RECORD;
  v_shareholder      RECORD;
  v_wallet_id        BIGINT;
  v_wallet_currency  TEXT;
  v_payment_currency TEXT;
  v_credited_amount  NUMERIC;
  v_fx_rate          NUMERIC;
  v_tx_id            BIGINT;
BEGIN
  -- Récupérer le paiement + devise du revenue associé
  SELECT sp.*, sr.currency
  INTO v_payment
  FROM public.shareholder_payments sp
  JOIN public.shareholder_revenues sr ON sr.id = sp.revenue_id
  WHERE sp.id = p_payment_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Paiement introuvable');
  END IF;

  IF v_payment.status = 'sent_to_wallet' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Déjà envoyé au wallet');
  END IF;

  IF v_payment.status != 'approved' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Le paiement doit être approuvé avant envoi');
  END IF;

  -- Récupérer l'actionnaire
  SELECT s.*
  INTO v_shareholder
  FROM public.shareholders s
  WHERE s.id = v_payment.shareholder_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Actionnaire introuvable');
  END IF;

  -- Récupérer le wallet et sa devise
  SELECT id, COALESCE(currency::TEXT, 'GNF')
  INTO v_wallet_id, v_wallet_currency
  FROM public.wallets
  WHERE user_id = v_shareholder.user_id
  LIMIT 1;

  IF v_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet actionnaire introuvable');
  END IF;

  v_payment_currency := COALESCE(v_payment.currency, 'GNF');
  v_credited_amount  := v_payment.amount;

  -- Conversion FX si le wallet n'est pas dans la même devise que le paiement
  IF v_wallet_currency != v_payment_currency THEN
    SELECT rate_internal
    INTO v_fx_rate
    FROM public.exchange_rates
    WHERE from_currency = v_payment_currency
      AND to_currency   = v_wallet_currency
      AND is_active     = true
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_fx_rate IS NULL THEN
      SELECT 1.0 / NULLIF(rate_internal, 0)
      INTO v_fx_rate
      FROM public.exchange_rates
      WHERE from_currency = v_wallet_currency
        AND to_currency   = v_payment_currency
        AND is_active     = true
      ORDER BY created_at DESC
      LIMIT 1;
    END IF;

    IF v_fx_rate IS NULL THEN
      RETURN jsonb_build_object(
        'success', false,
        'error',   'Taux de change introuvable: ' || v_payment_currency
                   || ' → ' || v_wallet_currency
                   || '. Veuillez mettre à jour les taux de change.'
      );
    END IF;

    v_credited_amount := ROUND(v_payment.amount * v_fx_rate, 2);
  END IF;

  -- Créditer le wallet (colonnes réelles de wallet_transactions)
  INSERT INTO public.wallet_transactions (
    transaction_id,
    receiver_wallet_id,
    receiver_user_id,
    amount,
    fee,
    net_amount,
    currency,
    transaction_type,
    status,
    description,
    reference_id,
    metadata,
    created_at
  ) VALUES (
    'SH-' || LEFT(p_payment_id::TEXT, 8) || '-' || TO_CHAR(now(), 'YYYYMMDDHH24MISS'),
    v_wallet_id,
    v_shareholder.user_id,
    v_credited_amount,
    0,
    v_credited_amount,
    v_wallet_currency,
    'commission',
    'completed',
    'Revenus actionnaire - ' || v_payment.shareholder_id::TEXT,
    p_payment_id::TEXT,
    jsonb_build_object(
      'source',      'shareholder_revenue',
      'revenue_id',  v_payment.revenue_id,
      'original_amount',   v_payment.amount,
      'payment_currency',  v_payment_currency,
      'fx_rate',           v_fx_rate
    ),
    now()
  )
  RETURNING id INTO v_tx_id;

  -- Mettre à jour le solde wallet
  UPDATE public.wallets
  SET balance    = balance + v_credited_amount,
      updated_at = now()
  WHERE id = v_wallet_id;

  -- Mettre à jour le statut du paiement
  UPDATE public.shareholder_payments
  SET status                = 'sent_to_wallet',
      wallet_transaction_id = v_tx_id,
      sent_to_wallet_at     = now(),
      updated_at            = now()
  WHERE id = p_payment_id;

  -- Mettre à jour le statut du revenu
  UPDATE public.shareholder_revenues
  SET payment_status = 'sent_to_wallet', updated_at = now()
  WHERE id = v_payment.revenue_id;

  -- Audit log
  INSERT INTO public.shareholder_audit_logs (
    actor_id, action, entity_type, entity_id, new_value
  ) VALUES (
    p_actor_id, 'send_payment_to_wallet', 'payment', p_payment_id,
    jsonb_build_object(
      'original_amount',  v_payment.amount,
      'payment_currency', v_payment_currency,
      'credited_amount',  v_credited_amount,
      'wallet_currency',  v_wallet_currency,
      'fx_rate',          v_fx_rate,
      'wallet_tx_id',     v_tx_id,
      'shareholder_id',   v_payment.shareholder_id
    )
  );

  -- Notification à l'actionnaire
  INSERT INTO public.notifications (user_id, title, message, type, read)
  VALUES (
    v_shareholder.user_id,
    'Paiement reçu',
    'Un paiement de ' || v_credited_amount::TEXT || ' ' || v_wallet_currency
    || CASE WHEN v_wallet_currency != v_payment_currency
       THEN ' (converti depuis ' || v_payment.amount::TEXT || ' ' || v_payment_currency || ')'
       ELSE ''
    END
    || ' a été crédité sur votre wallet.',
    'shareholder_payment',
    false
  );

  RETURN jsonb_build_object(
    'success',          true,
    'wallet_tx_id',     v_tx_id,
    'original_amount',  v_payment.amount,
    'payment_currency', v_payment_currency,
    'credited_amount',  v_credited_amount,
    'wallet_currency',  v_wallet_currency
  );
END;
$$;
