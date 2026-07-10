-- ============================================================================
-- 🏦 VOLET 4A — le versement actionnaire DÉBITE le coffre (fin du mint ex nihilo)
-- ----------------------------------------------------------------------------
-- AVANT : send_shareholder_payment_to_wallet CRÉDITAIT le wallet actionnaire (avec FX)
-- SANS débiter aucun coffre → chaque versement gonflait la masse monétaire.
-- APRÈS (pattern credit_agent_commission) : le coffre GNF PDG est DÉBITÉ du montant en
-- GNF, le crédit actionnaire garde sa conversion FX. Idempotence DURE en base + fail-closed
-- SOLDE_PDG_INSUFFISANT. Tout ou rien (une seule transaction plpgsql).
--
-- Idempotence : credit = 'shareholder_payment:'||id, debit = 'shareholder_payout:'||id —
-- l'index UNIQUE sur wallet_transactions.transaction_id bloque tout rejeu (en plus de la
-- garde applicative status='sent_to_wallet').
--
-- Migration livrée — NON exécutée.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.send_shareholder_payment_to_wallet(
  p_payment_id UUID,
  p_actor_id   UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
  v_credit_txn_key   TEXT := 'shareholder_payment:' || p_payment_id::text;
  v_debit_txn_key    TEXT := 'shareholder_payout:'  || p_payment_id::text;
  -- Débit coffre
  v_pdg_user_id      UUID;
  v_pdg_wallet_id    BIGINT;
  v_pdg_balance      NUMERIC;
  v_debit_gnf        NUMERIC;
BEGIN
  SELECT sp.*, sr.currency INTO v_payment
  FROM public.shareholder_payments sp
  JOIN public.shareholder_revenues sr ON sr.id = sp.revenue_id
  WHERE sp.id = p_payment_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Paiement introuvable'); END IF;
  IF v_payment.status = 'sent_to_wallet' THEN RETURN jsonb_build_object('success', false, 'error', 'Déjà envoyé au wallet'); END IF;
  IF v_payment.status != 'approved' THEN RETURN jsonb_build_object('success', false, 'error', 'Le paiement doit être approuvé avant envoi'); END IF;

  -- Idempotence DURE : si le débit du coffre existe déjà pour ce versement → déjà traité.
  IF EXISTS (SELECT 1 FROM public.wallet_transactions WHERE transaction_id = v_debit_txn_key) THEN
    RETURN jsonb_build_object('success', true, 'already_processed', true);
  END IF;

  SELECT s.* INTO v_shareholder FROM public.shareholders s WHERE s.id = v_payment.shareholder_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Actionnaire introuvable'); END IF;

  SELECT id, COALESCE(currency::TEXT, 'GNF') INTO v_wallet_id, v_wallet_currency
  FROM public.wallets WHERE user_id = v_shareholder.user_id LIMIT 1;
  IF v_wallet_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Wallet actionnaire introuvable'); END IF;

  v_payment_currency := COALESCE(v_payment.currency, 'GNF');
  v_credited_amount  := v_payment.amount;

  -- Conversion FX vers la devise de l'actionnaire (crédit) — inchangée.
  IF v_wallet_currency != v_payment_currency THEN
    SELECT rate_internal INTO v_fx_rate FROM public.exchange_rates
    WHERE from_currency = v_payment_currency AND to_currency = v_wallet_currency AND is_active = true
    ORDER BY created_at DESC LIMIT 1;
    IF v_fx_rate IS NULL THEN
      SELECT 1.0 / NULLIF(rate_internal, 0) INTO v_fx_rate FROM public.exchange_rates
      WHERE from_currency = v_wallet_currency AND to_currency = v_payment_currency AND is_active = true
      ORDER BY created_at DESC LIMIT 1;
    END IF;
    IF v_fx_rate IS NULL THEN
      RETURN jsonb_build_object('success', false,
        'error', 'Taux de change introuvable: ' || v_payment_currency || ' → ' || v_wallet_currency);
    END IF;
    v_credited_amount := ROUND(v_payment.amount * v_fx_rate, 2);
  END IF;

  -- ═══ DÉBIT DU COFFRE (en GNF) — fin du mint ═══
  -- Coût plateforme en GNF = valeur GNF du versement (indépendant de la devise actionnaire).
  v_debit_gnf := CASE WHEN v_payment_currency = 'GNF'
                      THEN v_payment.amount
                      ELSE public.convert_to_gnf(v_payment.amount, v_payment_currency) END;

  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management
  WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  IF v_pdg_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PDG_INTROUVABLE');
  END IF;
  SELECT id, COALESCE(balance,0) INTO v_pdg_wallet_id, v_pdg_balance FROM public.wallets
  WHERE user_id = v_pdg_user_id AND currency = 'GNF' FOR UPDATE;
  IF v_pdg_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PDG_WALLET_GNF_INTROUVABLE');
  END IF;
  IF v_debit_gnf > v_pdg_balance THEN
    -- Fail-closed + notification PDG (non bloquant), pattern credit_agent_commission.
    BEGIN
      PERFORM public.create_notification(
        v_pdg_user_id, 'pdg_shareholder_blocked', '⛔ Versement actionnaire bloqué',
        format('Un versement actionnaire (%s GNF) n''a pas pu être envoyé : solde du coffre insuffisant. Approvisionnez le coffre.',
               ROUND(v_debit_gnf, 2)),
        jsonb_build_object('needed', ROUND(v_debit_gnf,2), 'balance', ROUND(v_pdg_balance,2), 'payment_id', p_payment_id));
    EXCEPTION WHEN OTHERS THEN NULL; END;
    RETURN jsonb_build_object('success', false, 'error', 'SOLDE_PDG_INSUFFISANT');
  END IF;

  -- Débit coffre + trace (idempotent par v_debit_txn_key).
  UPDATE public.wallets SET balance = balance - v_debit_gnf, updated_at = now() WHERE id = v_pdg_wallet_id;
  INSERT INTO public.wallet_transactions (
    transaction_id, sender_wallet_id, sender_user_id, amount, fee, net_amount, currency,
    transaction_type, status, description, reference_id, metadata)
  VALUES (
    v_debit_txn_key, v_pdg_wallet_id, v_pdg_user_id, v_debit_gnf, 0, v_debit_gnf, 'GNF',
    'withdrawal', 'completed', 'Versement actionnaire (débit coffre) - ' || v_payment.shareholder_id::text,
    p_payment_id::text,
    jsonb_build_object('source', 'shareholder_payout', 'payment_id', p_payment_id,
      'credited_amount', v_credited_amount, 'credited_currency', v_wallet_currency,
      'payment_currency', v_payment_currency, 'fx_rate', v_fx_rate, 'debit_gnf', v_debit_gnf));

  -- Crédit actionnaire + trace (idempotent par v_credit_txn_key).
  INSERT INTO public.wallet_transactions (
    transaction_id, receiver_wallet_id, receiver_user_id, amount, fee, net_amount, currency,
    transaction_type, status, description, reference_id, metadata)
  VALUES (
    v_credit_txn_key, v_wallet_id, v_shareholder.user_id, v_credited_amount, 0, v_credited_amount, v_wallet_currency,
    'commission', 'completed', 'Revenus actionnaire - ' || v_payment.shareholder_id::text, p_payment_id::text,
    jsonb_build_object('source', 'shareholder_revenue', 'revenue_id', v_payment.revenue_id,
      'original_amount', v_payment.amount, 'payment_currency', v_payment_currency,
      'fx_rate', v_fx_rate, 'debit_gnf', v_debit_gnf))
  RETURNING id INTO v_tx_id;

  UPDATE public.wallets SET balance = balance + v_credited_amount, updated_at = now() WHERE id = v_wallet_id;

  UPDATE public.shareholder_payments
  SET status = 'sent_to_wallet', wallet_transaction_id = v_tx_id, sent_to_wallet_at = now(), updated_at = now()
  WHERE id = p_payment_id;
  UPDATE public.shareholder_revenues SET payment_status = 'sent_to_wallet', updated_at = now()
  WHERE id = v_payment.revenue_id;

  INSERT INTO public.shareholder_audit_logs (actor_id, action, entity_type, entity_id, new_value)
  VALUES (p_actor_id, 'send_payment_to_wallet', 'payment', p_payment_id,
    jsonb_build_object('original_amount', v_payment.amount, 'payment_currency', v_payment_currency,
      'credited_amount', v_credited_amount, 'wallet_currency', v_wallet_currency, 'fx_rate', v_fx_rate,
      'debit_gnf', v_debit_gnf, 'wallet_tx_id', v_tx_id, 'shareholder_id', v_payment.shareholder_id));

  INSERT INTO public.notifications (user_id, title, message, type, read)
  VALUES (v_shareholder.user_id, 'Paiement reçu',
    'Un paiement de ' || v_credited_amount::text || ' ' || v_wallet_currency || ' a été crédité sur votre wallet.',
    'shareholder_payment', false);

  RETURN jsonb_build_object('success', true, 'wallet_tx_id', v_tx_id,
    'original_amount', v_payment.amount, 'payment_currency', v_payment_currency,
    'credited_amount', v_credited_amount, 'wallet_currency', v_wallet_currency,
    'treasury_debit_gnf', v_debit_gnf);
END;
$$;

REVOKE ALL ON FUNCTION public.send_shareholder_payment_to_wallet(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.send_shareholder_payment_to_wallet(uuid, uuid) TO service_role;

SELECT CASE WHEN pg_get_functiondef('public.send_shareholder_payment_to_wallet(uuid,uuid)'::regprocedure) LIKE '%shareholder_payout:%'
  THEN '✅ versement actionnaire débite le coffre (idempotent, fail-closed)' ELSE '❌ ÉCHEC' END AS status;
