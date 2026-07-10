-- ============================================================================
-- 🔴 CORRECTIF — RPC de retrait cassées : INSERT wallet_transactions sur colonnes INEXISTANTES.
-- ----------------------------------------------------------------------------
-- request_bank_withdrawal + admin_process_withdrawal (migration 20260326221437) insèrent dans
-- wallet_transactions avec (wallet_id, type, reference_type, balance_after) + type='debit'/'credit'
-- — colonnes ABSENTES du schéma canonique (id BIGSERIAL, transaction_id, sender_user_id,
-- receiver_user_id, transaction_type ENUM, fee, net_amount CHECK(net=amount-fee), currency, status,
-- reference_id, metadata) et valeurs 'debit'/'credit' HORS enum transaction_type.
-- → toute demande de retrait / traitement admin échouait ("column wallet_id does not exist").
-- On réécrit les 2 RPC sur le schéma canonique (comme le fait le flux escrow) + minimum par devise
-- + verrouillage service_role. Logique métier INCHANGEE (réserve, restauration, finalisation).
-- ============================================================================

-- ── request_bank_withdrawal : réserve des fonds + ligne d'historique canonique ────────────────
CREATE OR REPLACE FUNCTION public.request_bank_withdrawal(
  p_user_id UUID,
  p_amount NUMERIC,
  p_currency TEXT,
  p_fee_rate NUMERIC,
  p_bank_account_name TEXT,
  p_bank_account_number TEXT,
  p_bank_details JSONB DEFAULT '{}'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet RECORD;
  v_fee NUMERIC;
  v_net NUMERIC;
  v_new_balance NUMERIC;
  v_withdrawal_id UUID;
  v_tx_ref TEXT;
  v_min NUMERIC;
BEGIN
  SELECT id, balance, currency INTO v_wallet
  FROM wallets WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet non trouvé');
  END IF;

  -- Minimum par devise
  v_min := CASE UPPER(COALESCE(p_currency, 'GNF'))
             WHEN 'GNF' THEN 50000 WHEN 'XOF' THEN 5000 WHEN 'USD' THEN 10 WHEN 'EUR' THEN 10 ELSE 50000 END;
  IF p_amount < v_min THEN
    RETURN jsonb_build_object('success', false, 'error', 'Montant inférieur au minimum pour ' || UPPER(COALESCE(p_currency, 'GNF')));
  END IF;

  IF COALESCE(v_wallet.balance, 0) < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Solde insuffisant. Disponible: ' || COALESCE(v_wallet.balance, 0)::TEXT || ' ' || COALESCE(p_currency, 'GNF'));
  END IF;

  v_fee := ROUND(p_amount * (p_fee_rate / 100));
  v_net := p_amount - v_fee;
  v_new_balance := COALESCE(v_wallet.balance, 0) - p_amount;

  -- Réservation : débit du wallet
  UPDATE wallets SET balance = v_new_balance, updated_at = NOW() WHERE id = v_wallet.id;

  v_withdrawal_id := gen_random_uuid();
  v_tx_ref := 'wdr-' || left(replace(v_withdrawal_id::text, '-', ''), 40);

  -- Ligne d'historique (SCHÉMA CANONIQUE) : sortie de fonds réservée, en attente de validation.
  -- amount > 0 (CHECK), net = amount - fee (CHECK), transaction_type='withdrawal' (enum), status='pending'.
  INSERT INTO wallet_transactions (
    transaction_id, sender_user_id, receiver_user_id, transaction_type,
    amount, fee, net_amount, currency, status, description, reference_id, metadata
  ) VALUES (
    v_tx_ref, p_user_id, NULL, 'withdrawal',
    p_amount, v_fee, v_net, UPPER(COALESCE(p_currency, 'GNF')), 'pending',
    'Retrait bancaire en attente de validation — Fonds réservés. Frais: ' || v_fee || ' ' || COALESCE(p_currency, 'GNF'),
    v_withdrawal_id::text,
    jsonb_build_object('withdrawal_id', v_withdrawal_id, 'fee', v_fee, 'reference_type', 'withdrawal_reserve')
  );

  -- Enregistrement de la demande
  INSERT INTO stripe_withdrawals (
    id, user_id, wallet_id, amount, fee, net_amount,
    currency, status, bank_account_name, bank_account_number,
    bank_details, fee_rate, created_at, updated_at
  ) VALUES (
    v_withdrawal_id, p_user_id, v_wallet.id, p_amount, v_fee, v_net,
    UPPER(COALESCE(p_currency, 'GNF')), 'pending_review',
    p_bank_account_name, p_bank_account_number, p_bank_details, p_fee_rate, NOW(), NOW()
  );

  RETURN jsonb_build_object(
    'success', true, 'withdrawal_id', v_withdrawal_id, 'transaction_id', v_tx_ref,
    'amount', p_amount, 'fee', v_fee, 'net_amount', v_net,
    'new_balance', v_new_balance, 'status', 'pending_review'
  );
EXCEPTION WHEN OTHERS THEN
  RAISE;
END;
$$;

-- ── admin_process_withdrawal : transitions + restauration/finalisation (ledger canonique) ──────
CREATE OR REPLACE FUNCTION public.admin_process_withdrawal(
  p_admin_id UUID,
  p_withdrawal_id UUID,
  p_action TEXT,
  p_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_withdrawal RECORD;
  v_wallet RECORD;
  v_new_status TEXT;
BEGIN
  SELECT * INTO v_withdrawal FROM stripe_withdrawals WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Retrait non trouvé');
  END IF;

  CASE p_action
    WHEN 'approve' THEN
      IF v_withdrawal.status != 'pending_review' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Statut incompatible: ' || v_withdrawal.status);
      END IF;
      v_new_status := 'approved';
    WHEN 'reject' THEN
      IF v_withdrawal.status NOT IN ('pending_review', 'approved') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Statut incompatible: ' || v_withdrawal.status);
      END IF;
      v_new_status := 'rejected';
    WHEN 'mark_sent' THEN
      IF v_withdrawal.status != 'approved' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Doit être approuvé avant envoi');
      END IF;
      v_new_status := 'processing';
    WHEN 'complete' THEN
      IF v_withdrawal.status NOT IN ('approved', 'processing') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Statut incompatible: ' || v_withdrawal.status);
      END IF;
      v_new_status := 'completed';
    WHEN 'fail' THEN
      IF v_withdrawal.status NOT IN ('approved', 'processing') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Statut incompatible: ' || v_withdrawal.status);
      END IF;
      v_new_status := 'failed';
    ELSE
      RETURN jsonb_build_object('success', false, 'error', 'Action invalide: ' || p_action);
  END CASE;

  UPDATE stripe_withdrawals
  SET status = v_new_status,
      admin_notes = COALESCE(p_notes, admin_notes),
      reviewed_by = p_admin_id,
      reviewed_at = CASE WHEN v_new_status IN ('approved', 'rejected') THEN NOW() ELSE reviewed_at END,
      processed_at = CASE WHEN v_new_status IN ('completed', 'failed') THEN NOW() ELSE processed_at END,
      updated_at = NOW()
  WHERE id = p_withdrawal_id;

  -- Rejeté/échoué → RESTAURER les fonds réservés (crédit canonique).
  IF v_new_status IN ('rejected', 'failed') THEN
    SELECT * INTO v_wallet FROM wallets WHERE id = v_withdrawal.wallet_id FOR UPDATE;
    IF FOUND THEN
      UPDATE wallets SET balance = COALESCE(balance, 0) + v_withdrawal.amount, updated_at = NOW()
      WHERE id = v_wallet.id;

      INSERT INTO wallet_transactions (
        transaction_id, sender_user_id, receiver_user_id, transaction_type,
        amount, fee, net_amount, currency, status, description, reference_id, metadata
      ) VALUES (
        'wdrev-' || left(replace(gen_random_uuid()::text, '-', ''), 38),
        NULL, v_withdrawal.user_id, 'refund',
        v_withdrawal.amount, 0, v_withdrawal.amount, COALESCE(v_withdrawal.currency, 'GNF'), 'completed',
        'Retrait bancaire ' || CASE WHEN v_new_status = 'rejected' THEN 'rejeté' ELSE 'échoué' END || ' — Fonds restaurés. ' || COALESCE(p_notes, ''),
        p_withdrawal_id::text,
        jsonb_build_object('withdrawal_id', p_withdrawal_id, 'reference_type', 'withdrawal_reversal')
      );
    END IF;
  END IF;

  -- Complété → finaliser la ligne de réserve (par reference_id = withdrawal_id).
  IF v_new_status = 'completed' THEN
    UPDATE wallet_transactions
    SET status = 'completed',
        description = 'Retrait bancaire complété — Virement effectué'
    WHERE reference_id = p_withdrawal_id::text
      AND transaction_type = 'withdrawal'
      AND status = 'pending';
  END IF;

  RETURN jsonb_build_object(
    'success', true, 'withdrawal_id', p_withdrawal_id, 'new_status', v_new_status,
    'funds_restored', v_new_status IN ('rejected', 'failed')
  );
EXCEPTION WHEN OTHERS THEN
  RAISE;
END;
$$;

-- ── Verrouillage : service_role uniquement (idempotent) ────────────────────────
REVOKE EXECUTE ON FUNCTION public.request_bank_withdrawal(UUID, NUMERIC, TEXT, NUMERIC, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.request_bank_withdrawal(UUID, NUMERIC, TEXT, NUMERIC, TEXT, TEXT, JSONB) TO service_role;
REVOKE EXECUTE ON FUNCTION public.admin_process_withdrawal(UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.admin_process_withdrawal(UUID, UUID, TEXT, TEXT) TO service_role;

SELECT 'RPC retrait réécrites sur le schéma canonique wallet_transactions + minimum par devise + verrouillage.' AS status;
