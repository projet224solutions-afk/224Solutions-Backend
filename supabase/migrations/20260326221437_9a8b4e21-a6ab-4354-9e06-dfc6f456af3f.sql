-- =====================================================
-- FIX: Withdrawal flow — Option A (Manual Admin)
-- =====================================================

-- 1. Add missing columns to stripe_withdrawals
ALTER TABLE public.stripe_withdrawals 
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'pending_review',
  ADD COLUMN IF NOT EXISTS wallet_id INTEGER REFERENCES public.wallets(id),
  ADD COLUMN IF NOT EXISTS admin_notes TEXT,
  ADD COLUMN IF NOT EXISTS reviewed_by UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS fee_rate NUMERIC,
  ADD COLUMN IF NOT EXISTS bank_details JSONB;

-- Make stripe_wallet_id nullable (we use regular wallets)
ALTER TABLE public.stripe_withdrawals 
  ALTER COLUMN stripe_wallet_id DROP NOT NULL;

-- 2. Create atomic RPC for withdrawal request
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
  v_tx_id UUID;
BEGIN
  -- 1. Lock the wallet row to prevent race conditions
  SELECT id, balance, currency
  INTO v_wallet
  FROM wallets
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet non trouvé');
  END IF;

  -- 2. Validate minimum amount
  IF p_amount < 50000 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Montant minimum: 50 000 ' || COALESCE(p_currency, 'GNF'));
  END IF;

  -- 3. Check balance
  IF COALESCE(v_wallet.balance, 0) < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 
      'Solde insuffisant. Disponible: ' || COALESCE(v_wallet.balance, 0)::TEXT || ' ' || COALESCE(p_currency, 'GNF'));
  END IF;

  -- 4. Calculate fee
  v_fee := ROUND(p_amount * (p_fee_rate / 100));
  v_net := p_amount - v_fee;
  v_new_balance := COALESCE(v_wallet.balance, 0) - p_amount;

  -- 5. Reserve funds: debit wallet
  UPDATE wallets
  SET balance = v_new_balance,
      updated_at = NOW()
  WHERE id = v_wallet.id;

  -- 6. Create wallet transaction (reserved funds)
  v_tx_id := gen_random_uuid();
  INSERT INTO wallet_transactions (
    id, wallet_id, amount, type, description, 
    reference_type, status, balance_after, created_at
  ) VALUES (
    v_tx_id,
    v_wallet.id,
    -p_amount,
    'debit',
    'Retrait bancaire en attente de validation — Fonds réservés. Frais: ' || v_fee || ' ' || COALESCE(p_currency, 'GNF'),
    'withdrawal_reserve',
    'pending',
    v_new_balance,
    NOW()
  );

  -- 7. Create withdrawal record
  v_withdrawal_id := gen_random_uuid();
  INSERT INTO stripe_withdrawals (
    id, user_id, wallet_id, amount, fee, net_amount,
    currency, status, bank_account_name, bank_account_number,
    bank_details, fee_rate, created_at, updated_at
  ) VALUES (
    v_withdrawal_id,
    p_user_id,
    v_wallet.id,
    p_amount,
    v_fee,
    v_net,
    UPPER(COALESCE(p_currency, 'GNF')),
    'pending_review',
    p_bank_account_name,
    p_bank_account_number,
    p_bank_details,
    p_fee_rate,
    NOW(),
    NOW()
  );

  RETURN jsonb_build_object(
    'success', true,
    'withdrawal_id', v_withdrawal_id,
    'transaction_id', v_tx_id,
    'amount', p_amount,
    'fee', v_fee,
    'net_amount', v_net,
    'new_balance', v_new_balance,
    'status', 'pending_review'
  );

EXCEPTION WHEN OTHERS THEN
  RAISE;
END;
$$;

-- 3. Admin RPC: approve, reject, complete, fail
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
  SELECT * INTO v_withdrawal
  FROM stripe_withdrawals
  WHERE id = p_withdrawal_id
  FOR UPDATE;

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

  -- If rejected or failed: RESTORE funds
  IF v_new_status IN ('rejected', 'failed') THEN
    SELECT * INTO v_wallet FROM wallets WHERE id = v_withdrawal.wallet_id FOR UPDATE;
    
    IF FOUND THEN
      UPDATE wallets
      SET balance = COALESCE(balance, 0) + v_withdrawal.amount,
          updated_at = NOW()
      WHERE id = v_wallet.id;

      INSERT INTO wallet_transactions (
        id, wallet_id, amount, type, description,
        reference_type, status, balance_after, created_at
      ) VALUES (
        gen_random_uuid(),
        v_wallet.id,
        v_withdrawal.amount,
        'credit',
        'Retrait bancaire ' || CASE WHEN v_new_status = 'rejected' THEN 'rejeté' ELSE 'échoué' END || ' — Fonds restaurés. ' || COALESCE(p_notes, ''),
        'withdrawal_reversal',
        COALESCE(v_wallet.balance, 0) + v_withdrawal.amount,
        NOW()
      );
    END IF;
  END IF;

  -- If completed: finalize wallet_transaction
  IF v_new_status = 'completed' THEN
    UPDATE wallet_transactions
    SET status = 'completed',
        description = REPLACE(description, 'en attente de validation — Fonds réservés', 'complété — Virement effectué')
    WHERE wallet_id = v_withdrawal.wallet_id
      AND reference_type = 'withdrawal_reserve'
      AND status = 'pending'
      AND amount = -v_withdrawal.amount;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'withdrawal_id', p_withdrawal_id,
    'new_status', v_new_status,
    'funds_restored', v_new_status IN ('rejected', 'failed')
  );

EXCEPTION WHEN OTHERS THEN
  RAISE;
END;
$$;

-- 4. RLS on stripe_withdrawals
ALTER TABLE public.stripe_withdrawals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own withdrawals" ON public.stripe_withdrawals;
CREATE POLICY "Users can view own withdrawals"
  ON public.stripe_withdrawals FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Service role manages withdrawals" ON public.stripe_withdrawals;
CREATE POLICY "Service role manages withdrawals"
  ON public.stripe_withdrawals FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);