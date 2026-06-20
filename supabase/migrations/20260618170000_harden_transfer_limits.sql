-- ============================================================================
-- 🛡️ DURCISSEMENT TRANSFERTS — limites cumulées (jour/mois) par rôle × palier KYC,
--    journalisation des transferts (vélocité réelle), blocage atomique.
-- ----------------------------------------------------------------------------
-- Audit : le cœur du transfert (national + FX) est atomique + idempotent, MAIS :
--   • la détection de vélocité lisait `wallet_logs` que les transferts n'alimentaient PAS,
--   • aucune limite CUMULÉE jour/mois (seul un plafond par transaction de 50 M GNF).
-- Ici : config `transfer_limits` (par rôle × tier), `transfer_effective_limits()`,
-- `enforce_transfer_limit()` (vérifie le cumul converti en GNF AVANT le débit, lève si dépassé),
-- et les 2 RPC de transfert appellent l'enforce + journalisent dans `wallet_logs` (montant GNF).
-- Tout reste ATOMIQUE (même transaction) et idempotent. Signatures INCHANGÉES.
-- ============================================================================

-- 1) ── Config des limites de transfert (cumul jour/mois en GNF, par rôle × tier) ──
INSERT INTO public.pdg_settings (setting_key, setting_value)
VALUES ('transfer_limits', jsonb_build_object(
  'default',     jsonb_build_object('t0', jsonb_build_object('daily',10000000,'monthly',100000000),  't1', jsonb_build_object('daily',100000000,'monthly',1000000000),  't2', jsonb_build_object('daily',null,'monthly',null)),
  'client',      jsonb_build_object('t0', jsonb_build_object('daily',10000000,'monthly',100000000),  't1', jsonb_build_object('daily',100000000,'monthly',1000000000),  't2', jsonb_build_object('daily',null,'monthly',null)),
  'vendeur',     jsonb_build_object('t0', jsonb_build_object('daily',20000000,'monthly',200000000),  't1', jsonb_build_object('daily',200000000,'monthly',2000000000),  't2', jsonb_build_object('daily',null,'monthly',null)),
  'prestataire', jsonb_build_object('t0', jsonb_build_object('daily',20000000,'monthly',200000000),  't1', jsonb_build_object('daily',200000000,'monthly',2000000000),  't2', jsonb_build_object('daily',null,'monthly',null)),
  'agent',       jsonb_build_object('t0', jsonb_build_object('daily',20000000,'monthly',200000000),  't1', jsonb_build_object('daily',200000000,'monthly',2000000000),  't2', jsonb_build_object('daily',null,'monthly',null)),
  'taxi',        jsonb_build_object('t0', jsonb_build_object('daily',10000000,'monthly',100000000),  't1', jsonb_build_object('daily',100000000,'monthly',1000000000),  't2', jsonb_build_object('daily',null,'monthly',null)),
  'livreur',     jsonb_build_object('t0', jsonb_build_object('daily',10000000,'monthly',100000000),  't1', jsonb_build_object('daily',100000000,'monthly',1000000000),  't2', jsonb_build_object('daily',null,'monthly',null))
))
ON CONFLICT (setting_key) DO NOTHING;

-- 2) ── Limites effectives d'un utilisateur (NULL = illimité ; pdg/admin exemptés) ──
CREATE OR REPLACE FUNCTION public.transfer_effective_limits(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_role text; v_kyc int; v_cfg jsonb; v_tier text; v_node jsonb;
BEGIN
  SELECT role, COALESCE(kyc_level,0) INTO v_role, v_kyc FROM public.profiles WHERE id = p_user_id;
  IF v_role IS NULL THEN RETURN jsonb_build_object('daily', null, 'monthly', null); END IF;
  IF v_role IN ('pdg','ceo','admin') THEN RETURN jsonb_build_object('daily', null, 'monthly', null); END IF;

  SELECT setting_value INTO v_cfg FROM public.pdg_settings WHERE setting_key = 'transfer_limits' LIMIT 1;
  IF v_cfg IS NULL THEN RETURN jsonb_build_object('daily', null, 'monthly', null); END IF;
  IF v_cfg ? 'value' THEN v_cfg := v_cfg->'value'; END IF;

  v_tier := 't' || LEAST(GREATEST(v_kyc,0),2)::text;
  v_node := COALESCE(v_cfg->v_role->v_tier, v_cfg->'default'->v_tier);
  IF v_node IS NULL THEN RETURN jsonb_build_object('daily', null, 'monthly', null); END IF;
  RETURN jsonb_build_object('daily', v_node->'daily', 'monthly', v_node->'monthly');
END;
$$;
REVOKE ALL ON FUNCTION public.transfer_effective_limits(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transfer_effective_limits(uuid) TO authenticated, service_role;

-- 3) ── Enforce : lève si le transfert dépasse le cumul jour/mois (en GNF) ───────
-- Appelé DANS la transaction du RPC (après verrou wallet) → atomique.
CREATE OR REPLACE FUNCTION public.enforce_transfer_limit(p_user_id uuid, p_amount_gnf numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_lim jsonb; v_daily numeric; v_monthly numeric; v_used_day numeric; v_used_month numeric;
BEGIN
  IF p_amount_gnf IS NULL OR p_amount_gnf <= 0 THEN RETURN; END IF;
  v_lim := public.transfer_effective_limits(p_user_id);
  v_daily   := NULLIF(v_lim->>'daily','')::numeric;
  v_monthly := NULLIF(v_lim->>'monthly','')::numeric;
  IF v_daily IS NULL AND v_monthly IS NULL THEN RETURN; END IF;  -- illimité

  -- Cumul des transferts ENVOYÉS déjà complétés (converti en GNF), aujourd'hui / ce mois.
  IF v_daily IS NOT NULL THEN
    SELECT COALESCE(SUM(public.convert_to_gnf(amount, currency)), 0) INTO v_used_day
    FROM public.enhanced_transactions
    WHERE sender_id = p_user_id AND status = 'completed'
      AND metadata->>'transaction_type' = 'transfer'
      AND created_at >= date_trunc('day', now());
    IF v_used_day + p_amount_gnf > v_daily THEN
      RAISE EXCEPTION 'DAILY_TRANSFER_LIMIT_EXCEEDED: cumul jour % + % > plafond % GNF', round(v_used_day), round(p_amount_gnf), v_daily;
    END IF;
  END IF;

  IF v_monthly IS NOT NULL THEN
    SELECT COALESCE(SUM(public.convert_to_gnf(amount, currency)), 0) INTO v_used_month
    FROM public.enhanced_transactions
    WHERE sender_id = p_user_id AND status = 'completed'
      AND metadata->>'transaction_type' = 'transfer'
      AND created_at >= date_trunc('month', now());
    IF v_used_month + p_amount_gnf > v_monthly THEN
      RAISE EXCEPTION 'MONTHLY_TRANSFER_LIMIT_EXCEEDED: cumul mois % + % > plafond % GNF', round(v_used_month), round(p_amount_gnf), v_monthly;
    END IF;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.enforce_transfer_limit(uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.enforce_transfer_limit(uuid, numeric) TO authenticated, service_role;

-- 4) ── RPC national : ajoute enforce + journalisation wallet_logs (GNF) ────────
CREATE OR REPLACE FUNCTION public.execute_atomic_wallet_transfer(
  p_sender_id uuid, p_receiver_id uuid, p_amount numeric, p_description text,
  p_sender_wallet_id bigint, p_recipient_wallet_id bigint,
  p_sender_balance_before numeric, p_recipient_balance_before numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_tx_id uuid := gen_random_uuid();
  v_sender_balance numeric; v_recipient_balance numeric; v_sender_blocked boolean;
  v_recipient_cur text; v_sender_cur text; v_credited numeric; v_amount_gnf numeric;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Montant invalide'; END IF;

  IF p_sender_wallet_id <= p_recipient_wallet_id THEN
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
  ELSE
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
  END IF;

  SELECT balance, COALESCE(is_blocked,false), currency INTO v_sender_balance, v_sender_blocked, v_sender_cur
  FROM wallets WHERE id = p_sender_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sender wallet not found'; END IF;
  IF v_sender_blocked THEN RAISE EXCEPTION 'Sender wallet blocked'; END IF;

  SELECT balance, currency INTO v_recipient_balance, v_recipient_cur FROM wallets WHERE id = p_recipient_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recipient wallet not found'; END IF;

  IF v_sender_balance < p_amount THEN RAISE EXCEPTION 'Solde insuffisant'; END IF;

  -- 🛡️ LIMITE CUMULÉE jour/mois (équivalent GNF) — lève si dépassée (atomique).
  v_amount_gnf := public.convert_to_gnf(p_amount, COALESCE(v_sender_cur,'GNF'));
  PERFORM public.enforce_transfer_limit(p_sender_id, v_amount_gnf);

  v_credited := public.apply_wallet_cap_split(p_receiver_id, p_recipient_wallet_id, v_recipient_balance, p_amount, v_recipient_cur, 'transfer_in', v_tx_id::text);

  UPDATE wallets SET balance = v_sender_balance - p_amount, updated_at = now() WHERE id = p_sender_wallet_id;
  UPDATE wallets SET balance = v_recipient_balance + v_credited, updated_at = now() WHERE id = p_recipient_wallet_id;

  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, metadata)
  VALUES (v_tx_id, p_sender_id, p_receiver_id, p_amount, 'wallet', 'completed', v_sender_cur,
    jsonb_build_object('description', p_description, 'atomic', true, 'transaction_type', 'transfer',
      'credited', v_credited, 'quarantined', (p_amount - v_credited)));

  -- 📊 Journal vélocité (montant en GNF) — best-effort.
  BEGIN
    INSERT INTO public.wallet_logs (user_id, action, amount, currency, transaction_id, status, metadata)
    VALUES (p_sender_id, 'transfer', v_amount_gnf, 'GNF', v_tx_id, 'completed', jsonb_build_object('atomic', true, 'national', true));
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id, 'quarantined', (p_amount - v_credited));
END;
$function$;
REVOKE ALL ON FUNCTION public.execute_atomic_wallet_transfer(uuid, uuid, numeric, text, bigint, bigint, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.execute_atomic_wallet_transfer(uuid, uuid, numeric, text, bigint, bigint, numeric, numeric) TO service_role;

-- 5) ── RPC FX : ajoute enforce (sur le DÉBIT en GNF) + journalisation ──────────
CREATE OR REPLACE FUNCTION public.execute_atomic_wallet_transfer_fx(
  p_sender_id uuid, p_receiver_id uuid, p_debit_amount numeric, p_credit_amount numeric,
  p_description text, p_sender_wallet_id bigint, p_recipient_wallet_id bigint,
  p_sender_balance_before numeric, p_recipient_balance_before numeric,
  p_sender_currency text, p_receiver_currency text, p_rate_used numeric,
  p_fee_amount numeric DEFAULT 0
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_tx_id uuid := gen_random_uuid();
  v_sender_balance numeric; v_recipient_balance numeric; v_sender_blocked boolean;
  v_fee numeric := COALESCE(p_fee_amount, 0); v_credited numeric; v_amount_gnf numeric;
BEGIN
  IF p_debit_amount IS NULL OR p_debit_amount <= 0 THEN RAISE EXCEPTION 'Montants invalides'; END IF;
  IF p_credit_amount IS NULL OR p_credit_amount <= 0 THEN RAISE EXCEPTION 'Montants invalides'; END IF;
  IF v_fee < 0 THEN RAISE EXCEPTION 'Commission invalide'; END IF;

  IF p_sender_wallet_id <= p_recipient_wallet_id THEN
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
  ELSE
    PERFORM 1 FROM wallets WHERE id = p_recipient_wallet_id FOR UPDATE;
    PERFORM 1 FROM wallets WHERE id = p_sender_wallet_id FOR UPDATE;
  END IF;

  SELECT balance, COALESCE(is_blocked,false) INTO v_sender_balance, v_sender_blocked
  FROM wallets WHERE id = p_sender_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sender wallet not found'; END IF;
  IF v_sender_blocked THEN RAISE EXCEPTION 'Sender wallet blocked'; END IF;

  SELECT balance INTO v_recipient_balance FROM wallets WHERE id = p_recipient_wallet_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recipient wallet not found'; END IF;

  IF v_sender_balance < p_debit_amount THEN RAISE EXCEPTION 'Solde insuffisant'; END IF;

  -- 🛡️ LIMITE CUMULÉE jour/mois sur le DÉBIT (montant + commission), converti en GNF.
  v_amount_gnf := public.convert_to_gnf(p_debit_amount, COALESCE(p_sender_currency,'GNF'));
  PERFORM public.enforce_transfer_limit(p_sender_id, v_amount_gnf);

  v_credited := public.apply_wallet_cap_split(p_receiver_id, p_recipient_wallet_id, v_recipient_balance, p_credit_amount, p_receiver_currency, 'transfer_in', v_tx_id::text);

  UPDATE wallets SET balance = v_sender_balance - p_debit_amount, updated_at = now() WHERE id = p_sender_wallet_id;
  UPDATE wallets SET balance = v_recipient_balance + v_credited, updated_at = now() WHERE id = p_recipient_wallet_id;

  INSERT INTO enhanced_transactions (id, sender_id, receiver_id, amount, method, status, currency, metadata)
  VALUES (v_tx_id, p_sender_id, p_receiver_id, p_debit_amount, 'wallet', 'completed', p_sender_currency,
    jsonb_build_object('description', p_description, 'atomic', true, 'fx', true, 'transaction_type', 'transfer',
      'amount_sent', (p_debit_amount - v_fee), 'amount_received', p_credit_amount, 'credit_amount', p_credit_amount,
      'credited', v_credited, 'quarantined', (p_credit_amount - v_credited),
      'fee_amount', v_fee, 'sender_currency', p_sender_currency, 'receiver_currency', p_receiver_currency, 'rate_used', p_rate_used));

  BEGIN
    INSERT INTO public.wallet_logs (user_id, action, amount, currency, transaction_id, status, metadata)
    VALUES (p_sender_id, 'transfer', v_amount_gnf, 'GNF', v_tx_id, 'completed', jsonb_build_object('atomic', true, 'fx', true));
  EXCEPTION WHEN OTHERS THEN NULL; END;

  IF v_fee > 0 THEN
    INSERT INTO platform_fx_commissions (transaction_id, sender_id, receiver_id, amount, currency, rate_used)
    VALUES (v_tx_id, p_sender_id, p_receiver_id, v_fee, p_sender_currency, p_rate_used);
  END IF;

  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx_id, 'quarantined', (p_credit_amount - v_credited));
END;
$function$;
REVOKE ALL ON FUNCTION public.execute_atomic_wallet_transfer_fx(uuid, uuid, numeric, numeric, text, bigint, bigint, numeric, numeric, text, text, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.execute_atomic_wallet_transfer_fx(uuid, uuid, numeric, numeric, text, bigint, bigint, numeric, numeric, text, text, numeric, numeric) TO service_role;

SELECT 'Transferts durcis : limites cumulées jour/mois par rôle×KYC (enforce atomique) + journalisation wallet_logs (GNF) → vélocité réelle.' AS status;
