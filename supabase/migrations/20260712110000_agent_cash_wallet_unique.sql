-- ════════════════════════════════════════════════════════════════════════════
-- AGENT CASH v2 — LE WALLET DE L'AGENT EST SON CAPITAL (suppression du float séparé)
-- ════════════════════════════════════════════════════════════════════════════
-- Décision PDG : l'agent cash n'a qu'UN solde = son wallet. Multi-devises : l'agent opère
-- automatiquement dans la devise de SON wallet ; les montants côté client sont convertis au
-- taux du jour (currency_exchange_rates, MÊME source que le garde FX), commission versée
-- dans la devise de l'agent.
--
-- ⚠️ À APPLIQUER APRÈS 20260712100000_agent_cash_hardening.sql (dont tous les gardes sont
--    CONSERVÉS ici : CHECK COMMISSION_MANQUANTE, plafond max_client_withdrawal_daily,
--    invariant count(ops)=count(commissions), idempotence, verrous déterministes).
-- ⚠️ Money-critical : TESTER EN STAGING avant prod. Livrée en fichier, non exécutée.
-- Repart des définitions LIVE (20260710120000 + 20260711120000 + 20260712100000).
-- ════════════════════════════════════════════════════════════════════════════

-- ── 0) Ledger : traçage FX + nouvelles legs (wallet agent, merge) ──
ALTER TABLE public.agent_cash_ledger
  ADD COLUMN IF NOT EXISTS fx_rate    numeric,        -- taux appliqué (NULL si même devise)
  ADD COLUMN IF NOT EXISTS fx_rate_at timestamptz,    -- horodatage du taux utilisé
  ADD COLUMN IF NOT EXISTS fx_source  text;           -- source du taux (currency_exchange_rates)

-- Étendre le CHECK des legs (garde les anciennes valeurs pour l'historique float).
ALTER TABLE public.agent_cash_ledger DROP CONSTRAINT IF EXISTS agent_cash_ledger_leg_check;
ALTER TABLE public.agent_cash_ledger ADD CONSTRAINT agent_cash_ledger_leg_check CHECK (leg IN (
  'client_debit','client_credit',
  'agent_wallet_debit','agent_wallet_credit',                    -- v2 : mouvements sur le wallet agent
  'agent_float_credit','agent_float_debit',                      -- historique (déprécié)
  'pdg_fee_credit','pdg_commission_debit',
  'agent_commission_credit','agent_commission_debit','agent_personal_credit',
  'float_merge_to_wallet','commission_merge_to_wallet'           -- v2 : fusion des soldes
));

-- ── 1) Config : plancher sur le SOLDE WALLET (reprend min_float_for_operations) ──
ALTER TABLE public.agent_cash_config
  ADD COLUMN IF NOT EXISTS min_wallet_balance_for_cash_ops numeric NOT NULL DEFAULT 100000;
-- Reporter la valeur active de l'ancien plancher float (sans écraser un réglage PDG déjà fait).
UPDATE public.agent_cash_config
SET min_wallet_balance_for_cash_ops = min_float_for_operations
WHERE is_active = true AND min_wallet_balance_for_cash_ops = 100000 AND min_float_for_operations <> 100000;
COMMENT ON COLUMN public.agent_cash_config.min_float_for_operations IS
  'DÉPRÉCIÉ (agent cash v2 : plancher = min_wallet_balance_for_cash_ops sur le solde wallet). Conservé pour historique.';
COMMENT ON COLUMN public.agent_cash_config.activation_float_threshold IS
  'DÉPRÉCIÉ (agent cash v2 : plus de float séparé ; recharge = dépôt normal du wallet).';

-- ── 2) Helper FX : conversion p_from → p_to via currency_exchange_rates, garde de fraîcheur 24h ──
-- Renvoie { converted (arrondi entier, half-up), rate, rate_at, source, remainder }. Même-devise = chemin court (aucun appel de taux).
CREATE OR REPLACE FUNCTION public._acash_fx(p_amount numeric, p_from text, p_to text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_rate numeric; v_at timestamptz;
  v_from_usd numeric; v_usd_to numeric; v_at1 timestamptz; v_at2 timestamptz;
  v_conv numeric;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR upper(p_from) = upper(p_to) THEN
    RETURN jsonb_build_object('converted', round(p_amount), 'rate', 1, 'rate_at', now(), 'source', 'same', 'remainder', 0);
  END IF;

  -- Direct / inverse
  SELECT CASE WHEN cer.from_currency = p_from THEN cer.rate ELSE 1.0 / NULLIF(cer.rate,0) END, cer.retrieved_at
  INTO v_rate, v_at
  FROM public.currency_exchange_rates cer
  WHERE ((cer.from_currency = p_from AND cer.to_currency = p_to)
      OR (cer.from_currency = p_to AND cer.to_currency = p_from))
    AND cer.is_active = true
  ORDER BY cer.retrieved_at DESC LIMIT 1;

  -- Cross USD si paire directe absente
  IF v_rate IS NULL OR v_rate <= 0 THEN
    SELECT CASE WHEN cer.from_currency = p_from THEN cer.rate ELSE 1.0 / NULLIF(cer.rate,0) END, cer.retrieved_at
    INTO v_from_usd, v_at1 FROM public.currency_exchange_rates cer
    WHERE ((cer.from_currency = p_from AND cer.to_currency = 'USD') OR (cer.from_currency = 'USD' AND cer.to_currency = p_from))
      AND cer.is_active = true ORDER BY cer.retrieved_at DESC LIMIT 1;
    SELECT CASE WHEN cer.from_currency = 'USD' THEN cer.rate ELSE 1.0 / NULLIF(cer.rate,0) END, cer.retrieved_at
    INTO v_usd_to, v_at2 FROM public.currency_exchange_rates cer
    WHERE ((cer.from_currency = 'USD' AND cer.to_currency = p_to) OR (cer.from_currency = p_to AND cer.to_currency = 'USD'))
      AND cer.is_active = true ORDER BY cer.retrieved_at DESC LIMIT 1;
    IF v_from_usd IS NOT NULL AND v_from_usd > 0 AND v_usd_to IS NOT NULL AND v_usd_to > 0 THEN
      v_rate := v_from_usd * v_usd_to;
      v_at := least(v_at1, v_at2);
    END IF;
  END IF;

  IF v_rate IS NULL OR v_rate <= 0 THEN
    RAISE EXCEPTION 'TAUX_INDISPONIBLE: taux introuvable % → %', p_from, p_to;
  END IF;
  -- Garde de fraîcheur : jamais d'opération à un taux périmé (> 24h), aligné sur la surveillance BCRG.
  IF v_at IS NULL OR v_at < now() - interval '24 hours' THEN
    RAISE EXCEPTION 'TAUX_INDISPONIBLE: taux périmé % → % (> 24h)', p_from, p_to;
  END IF;

  v_conv := round(p_amount * v_rate);   -- arrondi half-up à l'unité de la devise cible
  RETURN jsonb_build_object('converted', v_conv, 'rate', v_rate, 'rate_at', v_at,
    'source', 'currency_exchange_rates', 'remainder', (p_amount * v_rate) - v_conv);
END $$;
REVOKE ALL ON FUNCTION public._acash_fx(numeric, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public._acash_fx(numeric, text, text) TO service_role;

-- Helper : wallet OPÉRATIONNEL de l'agent (GNF prioritaire, sinon son wallet principal). Verrou inclus.
CREATE OR REPLACE FUNCTION public._acash_agent_wallet(p_user_id uuid)
RETURNS TABLE(wallet_id bigint, currency text, balance numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN QUERY
  SELECT w.id, w.currency, w.balance FROM public.wallets w
  WHERE w.user_id = p_user_id
  ORDER BY (w.currency = 'GNF') DESC, w.balance DESC, w.updated_at DESC
  LIMIT 1 FOR UPDATE;
END $$;
REVOKE ALL ON FUNCTION public._acash_agent_wallet(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public._acash_agent_wallet(uuid) TO service_role;

-- ── 3) MERGE des soldes float + commission → wallet GNF de l'agent (idempotent, tracé) ──
-- Idempotence : la présence d'un leg 'float_merge_to_wallet'/'commission_merge_to_wallet' pour
-- l'agent bloque le re-crédit. Agent avec solde > 0 mais SANS wallet GNF → skip + audit (report).
DO $$
DECLARE r RECORD; v_wallet bigint; v_pid uuid;
BEGIN
  FOR r IN SELECT id, user_id, cash_float_balance, cash_commission_balance
           FROM public.agents_management
           WHERE COALESCE(cash_float_balance,0) > 0 OR COALESCE(cash_commission_balance,0) > 0
  LOOP
    SELECT id INTO v_wallet FROM public.wallets WHERE user_id = r.user_id AND currency = 'GNF' LIMIT 1;
    IF v_wallet IS NULL THEN
      PERFORM public.agent_audit_log_safe('critical', 'agent_cash_merge_no_gnf_wallet',
        jsonb_build_object('agent_id', r.id, 'float', r.cash_float_balance, 'commission', r.cash_commission_balance,
          'note', 'STOP : agent avec solde float/commission mais aucun wallet GNF — verser manuellement (décision PDG).'));
      CONTINUE;
    END IF;

    -- Float → wallet (si pas déjà fait)
    IF COALESCE(r.cash_float_balance,0) > 0
       AND NOT EXISTS (SELECT 1 FROM public.agent_cash_ledger WHERE agent_id = r.id AND leg = 'float_merge_to_wallet') THEN
      v_pid := gen_random_uuid();
      PERFORM public._acash_credit_wallet(v_wallet, r.cash_float_balance);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount, currency)
      VALUES (v_pid, 'merge', 'float_merge_to_wallet', r.id, r.cash_float_balance, 'GNF');
    END IF;

    -- Commission → wallet (si pas déjà fait)
    IF COALESCE(r.cash_commission_balance,0) > 0
       AND NOT EXISTS (SELECT 1 FROM public.agent_cash_ledger WHERE agent_id = r.id AND leg = 'commission_merge_to_wallet') THEN
      v_pid := gen_random_uuid();
      PERFORM public._acash_credit_wallet(v_wallet, r.cash_commission_balance);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount, currency)
      VALUES (v_pid, 'merge', 'commission_merge_to_wallet', r.id, r.cash_commission_balance, 'GNF');
    END IF;

    -- Solder les colonnes float/commission (dépréciées ensuite).
    UPDATE public.agents_management
    SET cash_float_balance = 0, cash_commission_balance = 0, updated_at = now()
    WHERE id = r.id
      AND EXISTS (SELECT 1 FROM public.agent_cash_ledger WHERE agent_id = r.id AND leg = 'float_merge_to_wallet')
      ;   -- ne solde que si le float a bien été fusionné (les agents skippés gardent leur solde)
  END LOOP;
END $$;
COMMENT ON COLUMN public.agents_management.cash_float_balance IS 'DÉPRÉCIÉ (agent cash v2 : capital = wallet). Fusionné dans le wallet GNF via migration 20260712110000.';
COMMENT ON COLUMN public.agents_management.cash_commission_balance IS 'DÉPRÉCIÉ (agent cash v2 : commissions créditées directement au wallet). Fusionné via migration 20260712110000.';

-- ── 4) RPC agent_cash_deposit v2 (wallet agent → wallet client, multi-devises) ──
-- p_amount est exprimé dans la devise du CLIENT (montant crédité au client). L'agent est débité
-- de l'équivalent dans SA devise. Commission (payée PDG) versée dans la devise de l'agent.
CREATE OR REPLACE FUNCTION public.agent_cash_deposit(
  p_agent_id uuid, p_client_user_id uuid, p_amount numeric, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent uuid; v_agent RECORD; v_cfg public.agent_cash_config;
  v_aw_id bigint; v_aw_cur text; v_aw_bal numeric;
  v_client_cur text; v_amount_client numeric;
  v_fx jsonb; v_agent_debit numeric; v_floor_agent numeric;
  v_commission_gnf numeric; v_comm_agent numeric; v_comm_fx jsonb;
  v_pdg_wallet bigint; v_pdg_bal numeric; v_paid boolean := false;
  v_credit_res jsonb; v_has_commission boolean;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_client_user_id IS NULL THEN RAISE EXCEPTION 'CLIENT_INTROUVABLE'; END IF;
  v_cfg := public.agent_cash_active_config();

  INSERT INTO public.agent_cash_operations (idempotency_key, operation, agent_id, client_user_id, amount)
  VALUES (p_idempotency_key, 'deposit', p_agent_id, p_client_user_id, p_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.agent_cash_operations WHERE idempotency_key = p_idempotency_key);
  END IF;

  -- Verrous ordre déterministe : agent → (wallet agent) → client → PDG.
  SELECT * INTO v_agent FROM public.agents_management WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_INTROUVABLE'; END IF;
  IF NOT v_agent.cash_agent_active OR v_agent.cash_agent_suspended THEN RAISE EXCEPTION 'AGENT_INACTIF'; END IF;

  -- Wallet opérationnel de l'agent (verrou).
  SELECT wallet_id, currency, balance INTO v_aw_id, v_aw_cur, v_aw_bal FROM public._acash_agent_wallet(v_agent.user_id);
  IF v_aw_id IS NULL THEN RAISE EXCEPTION 'WALLET_AGENT_INTROUVABLE'; END IF;

  -- Plancher : min_wallet_balance_for_cash_ops (GNF) converti dans la devise de l'agent.
  v_floor_agent := (public._acash_fx(v_cfg.min_wallet_balance_for_cash_ops, 'GNF', v_aw_cur)->>'converted')::numeric;
  IF v_aw_bal < v_floor_agent THEN RAISE EXCEPTION 'SOLDE_AGENT_INSUFFISANT'; END IF;

  -- Montant côté client = p_amount dans la devise du client (le client est crédité de ce montant).
  SELECT currency INTO v_client_cur FROM public.wallets WHERE user_id = p_client_user_id AND currency IS NOT NULL
    ORDER BY (currency = 'GNF') DESC, updated_at DESC LIMIT 1;
  v_client_cur := COALESCE(v_client_cur, 'GNF');
  v_amount_client := p_amount;

  -- Débit agent = équivalent de p_amount (devise client) dans la devise de l'agent.
  v_fx := public._acash_fx(v_amount_client, v_client_cur, v_aw_cur);
  v_agent_debit := (v_fx->>'converted')::numeric;
  IF v_aw_bal < v_agent_debit THEN RAISE EXCEPTION 'SOLDE_AGENT_INSUFFISANT'; END IF;

  -- 1) Wallet agent -= équivalent (verrou déjà pris)
  PERFORM public._acash_debit_wallet(v_aw_id, v_agent_debit, 'SOLDE_AGENT_INSUFFISANT');
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, fx_rate, fx_rate_at, fx_source)
  VALUES (v_parent, 'deposit', 'agent_wallet_debit', p_agent_id, p_client_user_id, v_agent_debit, v_aw_cur,
          (v_fx->>'rate')::numeric, (v_fx->>'rate_at')::timestamptz, v_fx->>'source');

  -- 2) Client crédité du montant EXACT dans SA devise (credit_user_wallet_safe gère FX + AML).
  v_credit_res := public.credit_user_wallet_safe(p_client_user_id, v_amount_client, v_client_cur, 'agent_cash_deposit', v_parent::text);
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
  VALUES (v_parent, 'deposit', 'client_credit', p_agent_id, p_client_user_id, v_amount_client, v_client_cur);

  -- 3) Commission (0.2% du montant, base GNF) → versée à l'agent DANS SA devise. Payée par le PDG (GNF).
  v_commission_gnf := round( ((public._acash_fx(v_amount_client, v_client_cur, 'GNF'))->>'converted')::numeric * v_cfg.deposit_agent_commission_percent / 100.0 );
  v_comm_fx := public._acash_fx(v_commission_gnf, 'GNF', v_aw_cur);
  v_comm_agent := (v_comm_fx->>'converted')::numeric;

  IF v_commission_gnf > 0 THEN
    v_pdg_wallet := public.get_pdg_gnf_wallet_id();
    IF v_pdg_wallet IS NOT NULL AND NOT v_agent.cash_agent_suspended THEN
      SELECT balance INTO v_pdg_bal FROM public.wallets WHERE id = v_pdg_wallet FOR UPDATE;
      IF v_pdg_bal >= v_commission_gnf THEN
        PERFORM public._acash_debit_wallet(v_pdg_wallet, v_commission_gnf, 'PDG_INSUFFISANT');
        PERFORM public._acash_credit_wallet(v_aw_id, v_comm_agent);
        INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
        VALUES (v_parent, 'deposit', 'pdg_commission_debit', p_agent_id, p_client_user_id, v_commission_gnf, 'GNF');
        INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, fx_rate, fx_rate_at, fx_source)
        VALUES (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, v_comm_agent, v_aw_cur,
                (v_comm_fx->>'rate')::numeric, (v_comm_fx->>'rate_at')::timestamptz, v_comm_fx->>'source');
        v_paid := true;
      END IF;
    END IF;
    IF NOT v_paid THEN
      INSERT INTO public.agent_commission_pending (agent_id, amount, reason, source_parent_tx_id)
      VALUES (p_agent_id, v_commission_gnf, CASE WHEN v_agent.cash_agent_suspended THEN 'agent_suspendu' ELSE 'pdg_insuffisant' END, v_parent);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, status)
      VALUES (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, v_comm_agent, v_aw_cur, 'pending');
    END IF;
  ELSE
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, status)
    VALUES (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, 0, v_aw_cur, 'completed');
  END IF;

  -- Journalisation de l'écart d'arrondi FX (jamais absorbé en silence).
  IF (v_fx->>'remainder')::numeric <> 0 OR (v_comm_fx->>'remainder')::numeric <> 0 THEN
    PERFORM public.agent_audit_log_safe('info', 'agent_cash_fx_rounding',
      jsonb_build_object('parent_tx_id', v_parent, 'op', 'deposit',
        'debit_remainder', (v_fx->>'remainder')::numeric, 'commission_remainder', (v_comm_fx->>'remainder')::numeric));
  END IF;

  -- CHECK final : aucune opération sans sa commission tracée → rollback total.
  SELECT EXISTS (SELECT 1 FROM public.agent_cash_ledger WHERE parent_tx_id = v_parent AND leg = 'agent_commission_credit') INTO v_has_commission;
  IF NOT v_has_commission THEN RAISE EXCEPTION 'COMMISSION_MANQUANTE: dépôt % sans commission tracée', v_parent; END IF;

  UPDATE public.agent_cash_operations SET agent_share = v_comm_agent, result = jsonb_build_object(
    'success', true, 'parent_tx_id', v_parent, 'client_credited', v_amount_client, 'client_currency', v_client_cur,
    'agent_debited', v_agent_debit, 'agent_currency', v_aw_cur, 'agent_commission', v_comm_agent,
    'commission_paid', v_paid, 'rate', (v_fx->>'rate')::numeric,
    'quarantined', COALESCE((v_credit_res->>'quarantined')::numeric, 0)
  ) WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_deposit(uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_deposit(uuid, uuid, numeric, text) TO service_role;

-- ── 5) RPC agent_cash_withdrawal v2 (wallet client → wallet agent, multi-devises) ──
-- p_amount dans la devise du CLIENT. Client débité (montant + frais) ; agent crédité de
-- l'équivalent du montant dans SA devise ; frais → PDG (GNF) ; part agent (30%) versée en devise agent.
CREATE OR REPLACE FUNCTION public.agent_cash_withdrawal(
  p_agent_id uuid, p_client_user_id uuid, p_amount numeric, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent uuid; v_agent RECORD; v_cfg public.agent_cash_config;
  v_client_wallet bigint; v_client_cur text; v_pdg_wallet bigint;
  v_aw_id bigint; v_aw_cur text; v_aw_bal numeric; v_floor_agent numeric;
  v_amount_gnf numeric; v_fee_gnf numeric; v_agent_share_gnf numeric;
  v_win_amount numeric := 0; v_win_fees numeric := 0; v_cum_fee numeric;
  v_day_comm numeric := 0; v_to_pending boolean := false; v_reason text := NULL;
  v_client_day numeric := 0; v_has_commission boolean;
  v_fee_client numeric; v_fx_agent jsonb; v_agent_credit numeric;
  v_comm_fx jsonb; v_comm_agent numeric;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_client_user_id IS NULL THEN RAISE EXCEPTION 'CLIENT_INTROUVABLE'; END IF;
  v_cfg := public.agent_cash_active_config();

  INSERT INTO public.agent_cash_operations (idempotency_key, operation, agent_id, client_user_id, amount)
  VALUES (p_idempotency_key, 'withdrawal', p_agent_id, p_client_user_id, p_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.agent_cash_operations WHERE idempotency_key = p_idempotency_key);
  END IF;

  SELECT * INTO v_agent FROM public.agents_management WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_INTROUVABLE'; END IF;
  IF NOT v_agent.cash_agent_active THEN RAISE EXCEPTION 'AGENT_INACTIF'; END IF;

  -- Wallet opérationnel agent + plancher (converti dans sa devise).
  SELECT wallet_id, currency, balance INTO v_aw_id, v_aw_cur, v_aw_bal FROM public._acash_agent_wallet(v_agent.user_id);
  IF v_aw_id IS NULL THEN RAISE EXCEPTION 'WALLET_AGENT_INTROUVABLE'; END IF;
  v_floor_agent := (public._acash_fx(v_cfg.min_wallet_balance_for_cash_ops, 'GNF', v_aw_cur)->>'converted')::numeric;
  IF v_aw_bal < v_floor_agent THEN RAISE EXCEPTION 'SOLDE_AGENT_INSUFFISANT'; END IF;

  -- Wallet client + sa devise.
  SELECT id, currency INTO v_client_wallet, v_client_cur FROM public.wallets
  WHERE user_id = p_client_user_id ORDER BY (currency = 'GNF') DESC, updated_at DESC LIMIT 1;
  IF v_client_wallet IS NULL THEN RAISE EXCEPTION 'WALLET_CLIENT_INTROUVABLE'; END IF;
  v_client_cur := COALESCE(v_client_cur, 'GNF');

  -- D4 : plafond de retrait journalier par CLIENT (24h glissantes). Le plafond est en GNF ;
  -- on convertit le cumul du client (sa devise) en GNF avant comparaison.
  SELECT COALESCE(sum(amount), 0) INTO v_client_day FROM public.agent_cash_operations
  WHERE operation = 'withdrawal' AND client_user_id = p_client_user_id
    AND created_at > now() - interval '24 hours' AND parent_tx_id <> v_parent;
  v_amount_gnf := (public._acash_fx(v_client_day + p_amount, v_client_cur, 'GNF')->>'converted')::numeric;
  IF v_amount_gnf > COALESCE(v_cfg.max_client_withdrawal_daily, 5000000) THEN
    RAISE EXCEPTION 'PLAFOND_CLIENT_ATTEINT';
  END IF;

  -- Frais (base GNF, puis exprimés dans la devise du client pour le débit). Anti-splitting.
  SELECT COALESCE(sum(amount),0), COALESCE(sum(fee),0) INTO v_win_amount, v_win_fees
  FROM public.agent_cash_operations
  WHERE operation = 'withdrawal' AND agent_id = p_agent_id AND client_user_id = p_client_user_id
    AND created_at > now() - make_interval(mins => v_cfg.anti_split_window_minutes)
    AND parent_tx_id <> v_parent;
  v_cum_fee := least(greatest(round((v_win_amount + p_amount) * v_cfg.withdrawal_fee_percent / 100.0), v_cfg.withdrawal_fee_min), v_cfg.withdrawal_fee_max);
  v_fee_client := greatest(v_cum_fee - v_win_fees, 0);   -- frais dans la devise du client
  v_fee_gnf := (public._acash_fx(v_fee_client, v_client_cur, 'GNF')->>'converted')::numeric;
  v_agent_share_gnf := round(v_fee_gnf * v_cfg.withdrawal_agent_share_of_fee / 100.0);

  -- 1) Client débité de (montant + frais) dans SA devise (verrou wallet client).
  PERFORM public._acash_debit_wallet(v_client_wallet, p_amount + v_fee_client, 'SOLDE_INSUFFISANT');
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
  VALUES (v_parent, 'withdrawal', 'client_debit', p_agent_id, p_client_user_id, p_amount + v_fee_client, v_client_cur);

  -- 2) Agent crédité de l'équivalent du montant dans SA devise (il rend le cash physique).
  v_fx_agent := public._acash_fx(p_amount, v_client_cur, v_aw_cur);
  v_agent_credit := (v_fx_agent->>'converted')::numeric;
  PERFORM public._acash_credit_wallet(v_aw_id, v_agent_credit);
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, fx_rate, fx_rate_at, fx_source)
  VALUES (v_parent, 'withdrawal', 'agent_wallet_credit', p_agent_id, p_client_user_id, v_agent_credit, v_aw_cur,
          (v_fx_agent->>'rate')::numeric, (v_fx_agent->>'rate_at')::timestamptz, v_fx_agent->>'source');

  -- 3) Frais → PDG (GNF, devise de base plateforme).
  v_pdg_wallet := public.get_pdg_gnf_wallet_id();
  IF v_pdg_wallet IS NULL THEN RAISE EXCEPTION 'PDG_INTROUVABLE'; END IF;
  IF v_fee_gnf > 0 THEN
    PERFORM public._acash_credit_wallet(v_pdg_wallet, v_fee_gnf);
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
    VALUES (v_parent, 'withdrawal', 'pdg_fee_credit', p_agent_id, p_client_user_id, v_fee_gnf, 'GNF');
  END IF;

  -- Plafond commission journalier + kill switch → part agent en pending.
  SELECT COALESCE(sum(agent_share),0) INTO v_day_comm FROM public.agent_cash_operations
  WHERE agent_id = p_agent_id AND operation = 'withdrawal' AND created_at::date = now()::date AND parent_tx_id <> v_parent;
  IF v_agent.cash_agent_suspended THEN v_to_pending := true; v_reason := 'agent_suspendu';
  ELSIF (v_day_comm + v_agent_share_gnf) > v_cfg.daily_commission_cap_per_agent THEN v_to_pending := true; v_reason := 'plafond_journalier';
  END IF;

  -- Part agent (30% des frais) → versée à l'agent DANS SA devise (depuis le PDG). TOUJOURS tracée.
  v_comm_fx := public._acash_fx(v_agent_share_gnf, 'GNF', v_aw_cur);
  v_comm_agent := (v_comm_fx->>'converted')::numeric;
  IF v_agent_share_gnf > 0 THEN
    IF v_to_pending THEN
      INSERT INTO public.agent_commission_pending (agent_id, amount, reason, source_parent_tx_id)
      VALUES (p_agent_id, v_agent_share_gnf, v_reason, v_parent);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, status)
      VALUES (v_parent, 'withdrawal', 'agent_commission_credit', p_agent_id, p_client_user_id, v_comm_agent, v_aw_cur, 'pending');
      INSERT INTO public.agent_audit_log_safe(severity, event, detail)
      VALUES ('warning', 'agent_cash_commission_pending', jsonb_build_object('agent_id', p_agent_id, 'amount_gnf', v_agent_share_gnf, 'reason', v_reason, 'parent_tx_id', v_parent));
    ELSE
      PERFORM public._acash_debit_wallet(v_pdg_wallet, v_agent_share_gnf, 'PDG_INSUFFISANT');
      PERFORM public._acash_credit_wallet(v_aw_id, v_comm_agent);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency)
      VALUES (v_parent, 'withdrawal', 'pdg_commission_debit', p_agent_id, p_client_user_id, v_agent_share_gnf, 'GNF');
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, fx_rate, fx_rate_at, fx_source)
      VALUES (v_parent, 'withdrawal', 'agent_commission_credit', p_agent_id, p_client_user_id, v_comm_agent, v_aw_cur,
              (v_comm_fx->>'rate')::numeric, (v_comm_fx->>'rate_at')::timestamptz, v_comm_fx->>'source');
    END IF;
  ELSE
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, currency, status)
    VALUES (v_parent, 'withdrawal', 'agent_commission_credit', p_agent_id, p_client_user_id, 0, v_aw_cur, 'completed');
  END IF;

  -- CHECK final commission tracée.
  SELECT EXISTS (SELECT 1 FROM public.agent_cash_ledger WHERE parent_tx_id = v_parent AND leg = 'agent_commission_credit') INTO v_has_commission;
  IF NOT v_has_commission THEN RAISE EXCEPTION 'COMMISSION_MANQUANTE: retrait % sans commission tracée', v_parent; END IF;

  UPDATE public.agent_cash_operations
  SET fee = v_fee_gnf, agent_share = v_agent_share_gnf, pdg_share = v_fee_gnf - v_agent_share_gnf,
      result = jsonb_build_object('success', true, 'parent_tx_id', v_parent, 'amount', p_amount, 'client_currency', v_client_cur,
        'fee_client', v_fee_client, 'agent_credited', v_agent_credit, 'agent_currency', v_aw_cur,
        'agent_share', v_comm_agent, 'commission_pending', v_to_pending, 'rate', (v_fx_agent->>'rate')::numeric)
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_withdrawal(uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_withdrawal(uuid, uuid, numeric, text) TO service_role;

-- ── 6) Suppression de « Retrait moi-même » (sans objet : le wallet EST le capital de l'agent) ──
DROP FUNCTION IF EXISTS public.agent_cash_self_withdrawal(uuid, numeric, text);

-- ── 7) Réconciliation v2 (multi-devises, plus de float séparé) ──
CREATE OR REPLACE FUNCTION public.agent_cash_reconciliation_check()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_unbalanced int; v_missing_comm int; v_untraced_fx int; v_legacy_float int; v_report jsonb;
BEGIN
  -- Invariant 1 : opérations PURE-GNF (aucun leg converti) → débits = crédits.
  -- Les opérations cross-devises traversent légitimement les devises (jamais équilibrées par
  -- devise) : elles sont couvertes par l'invariant 3 (tout leg converti porte son taux tracé).
  SELECT count(*) INTO v_unbalanced FROM (
    SELECT l.parent_tx_id,
      sum(CASE WHEN l.leg LIKE '%_debit' THEN l.amount ELSE 0 END) AS deb,
      sum(CASE WHEN l.leg LIKE '%_credit' THEN l.amount ELSE 0 END) AS cred
    FROM public.agent_cash_ledger l
    WHERE l.status = 'completed' AND l.operation IN ('deposit','withdrawal')
      AND NOT EXISTS (SELECT 1 FROM public.agent_cash_ledger x WHERE x.parent_tx_id = l.parent_tx_id AND x.fx_rate IS NOT NULL)
    GROUP BY l.parent_tx_id
    HAVING abs(sum(CASE WHEN l.leg LIKE '%_debit' THEN l.amount ELSE 0 END)
             - sum(CASE WHEN l.leg LIKE '%_credit' THEN l.amount ELSE 0 END)) > 1
  ) d;

  -- Invariant 2 (PDG) : chaque dépôt/retrait a SA commission tracée.
  SELECT count(*) INTO v_missing_comm FROM public.agent_cash_operations o
  WHERE o.operation IN ('deposit','withdrawal')
    AND NOT EXISTS (SELECT 1 FROM public.agent_cash_ledger l WHERE l.parent_tx_id = o.parent_tx_id AND l.leg = 'agent_commission_credit');

  -- Invariant 3 : tout leg en devise ≠ GNF DOIT porter un taux tracé (fx_rate).
  SELECT count(*) INTO v_untraced_fx FROM public.agent_cash_ledger
  WHERE operation IN ('deposit','withdrawal') AND currency <> 'GNF' AND fx_rate IS NULL;

  -- Invariant 4 : plus AUCUN leg float après la migration (modèle wallet unique).
  SELECT count(*) INTO v_legacy_float FROM public.agent_cash_ledger
  WHERE leg IN ('agent_float_credit','agent_float_debit')
    AND created_at > (SELECT max(created_at) FROM public.agent_cash_ledger WHERE leg = 'float_merge_to_wallet');

  v_report := jsonb_build_object('generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','ledger_unbalanced','label','Opérations (par devise) débits ≠ crédits','severity','critical','count',v_unbalanced,'observed',v_unbalanced),
      jsonb_build_object('key','missing_commission','label','Opérations sans commission tracée','severity','critical','count',v_missing_comm,'observed',v_missing_comm),
      jsonb_build_object('key','fx_untraced','label','Legs convertis sans taux tracé','severity','critical','count',v_untraced_fx,'observed',v_untraced_fx),
      jsonb_build_object('key','legacy_float','label','Legs float après migration (interdit)','severity','warning','count',v_legacy_float,'observed',v_legacy_float)
    ));
  IF v_unbalanced > 0 OR v_missing_comm > 0 OR v_untraced_fx > 0 OR v_legacy_float > 0 THEN
    PERFORM public.agent_audit_log_safe('critical', 'agent_cash_reconciliation_anomaly', v_report);
  END IF;
  RETURN v_report;
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_reconciliation_check() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_reconciliation_check() TO authenticated, service_role;

-- ── 8) config_update : exposer min_wallet_balance_for_cash_ops ──
CREATE OR REPLACE FUNCTION public.agent_cash_config_update(p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cur public.agent_cash_config; v_new_id uuid;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  v_cur := public.agent_cash_active_config();
  UPDATE public.agent_cash_config SET is_active = false WHERE is_active = true;
  INSERT INTO public.agent_cash_config (
    withdrawal_fee_percent, withdrawal_fee_min, withdrawal_fee_max,
    withdrawal_agent_share_of_fee, withdrawal_pdg_share_of_fee,
    deposit_agent_commission_percent, activation_float_threshold,
    min_float_for_operations, daily_commission_cap_per_agent, anti_split_window_minutes,
    max_client_withdrawal_daily, min_wallet_balance_for_cash_ops, is_active, created_by)
  VALUES (
    COALESCE((p_changes->>'withdrawal_fee_percent')::numeric, v_cur.withdrawal_fee_percent),
    COALESCE((p_changes->>'withdrawal_fee_min')::numeric, v_cur.withdrawal_fee_min),
    COALESCE((p_changes->>'withdrawal_fee_max')::numeric, v_cur.withdrawal_fee_max),
    COALESCE((p_changes->>'withdrawal_agent_share_of_fee')::numeric, v_cur.withdrawal_agent_share_of_fee),
    COALESCE((p_changes->>'withdrawal_pdg_share_of_fee')::numeric, v_cur.withdrawal_pdg_share_of_fee),
    COALESCE((p_changes->>'deposit_agent_commission_percent')::numeric, v_cur.deposit_agent_commission_percent),
    v_cur.activation_float_threshold,
    v_cur.min_float_for_operations,
    COALESCE((p_changes->>'daily_commission_cap_per_agent')::numeric, v_cur.daily_commission_cap_per_agent),
    COALESCE((p_changes->>'anti_split_window_minutes')::int, v_cur.anti_split_window_minutes),
    COALESCE((p_changes->>'max_client_withdrawal_daily')::numeric, v_cur.max_client_withdrawal_daily),
    COALESCE((p_changes->>'min_wallet_balance_for_cash_ops')::numeric, v_cur.min_wallet_balance_for_cash_ops),
    true, auth.uid())
  RETURNING id INTO v_new_id;
  RETURN jsonb_build_object('success', true, 'config_id', v_new_id);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_config_update(jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_config_update(jsonb) TO authenticated, service_role;

-- ── Statut opérationnel de l'agent : son SOLDE WALLET couvre-t-il le plancher ? (dans sa devise) ──
CREATE OR REPLACE FUNCTION public.agent_cash_wallet_ok(p_agent_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid; v_cur text; v_bal numeric; v_cfg public.agent_cash_config; v_floor numeric;
BEGIN
  SELECT user_id INTO v_uid FROM public.agents_management WHERE id = p_agent_id;
  IF v_uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_agent'); END IF;
  SELECT currency, balance INTO v_cur, v_bal FROM public.wallets
  WHERE user_id = v_uid ORDER BY (currency='GNF') DESC, balance DESC, updated_at DESC LIMIT 1;
  IF v_cur IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_wallet'); END IF;
  v_cfg := public.agent_cash_active_config();
  BEGIN
    v_floor := (public._acash_fx(v_cfg.min_wallet_balance_for_cash_ops, 'GNF', v_cur)->>'converted')::numeric;
  EXCEPTION WHEN OTHERS THEN
    -- Taux indisponible → on ne peut pas garantir le plancher : bloqué (motif explicite).
    RETURN jsonb_build_object('ok', false, 'reason', 'rate_unavailable', 'currency', v_cur, 'balance', v_bal);
  END;
  RETURN jsonb_build_object('ok', v_bal >= v_floor, 'currency', v_cur, 'balance', v_bal, 'floor', v_floor, 'min_gnf', v_cfg.min_wallet_balance_for_cash_ops);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_wallet_ok(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_wallet_ok(uuid) TO authenticated, service_role;

-- ── Auto-vérification ──
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'agent_cash_self_withdrawal') THEN
    RAISE EXCEPTION 'agent_cash_self_withdrawal encore présente — suppression échouée';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='agent_cash_config' AND column_name='min_wallet_balance_for_cash_ops') THEN
    RAISE EXCEPTION 'min_wallet_balance_for_cash_ops absent';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.proname='agent_cash_deposit' AND pg_get_functiondef(p.oid) LIKE '%COMMISSION_MANQUANTE%') THEN
    RAISE EXCEPTION 'garde COMMISSION_MANQUANTE absent du dépôt v2';
  END IF;
  RAISE NOTICE 'OK : agent cash v2 — wallet unique, self_withdrawal supprimé, gardes présents.';
END $$;

SELECT 'Agent Cash v2 : wallet unique (float fusionné+tracé), RPC dépôt/retrait multi-devises (taux BCRG + garde fraîcheur + traçage), self_withdrawal supprimé, réconciliation v2.' AS status;
