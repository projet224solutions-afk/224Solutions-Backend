-- ============================================================================
-- 💵 SYSTÈME AGENT DÉPÔT/RETRAIT CASH — float, commissions atomiques (transit PDG),
--    ledger double-entrée immuable, garde-fous. Décisions produit validées PDG.
-- ----------------------------------------------------------------------------
-- CHOIX D'IMPLÉMENTATION (documentés) :
--  • Table wallets canonique = public.wallets (1 wallet / user, unique user_id).
--  • Dépôt : crédit client via credit_user_wallet_safe (canonique) → conserve le plafond
--    AML (anti-blanchiment) ; montant enregistré = montant déposé.
--  • Débits (retrait client, transit PDG) : UPDATE verrouillés directs (FOR UPDATE, ordre
--    déterministe client→agent→PDG) + CHECK balance>=0 → montants EXACTS, contrôle total.
--  • Idempotence : table en-tête agent_cash_operations (idempotency_key UNIQUE). Le ledger
--    porte les LEGS (double-entrée) liés par parent_tx_id ; il est IMMUABLE (pas d'UPDATE/DELETE).
--  • Identité client : resolve_user_id_by_phone_strict (fait côté endpoint) ; les RPC reçoivent
--    un p_client_user_id déjà résolu (jamais de LIMIT 1 silencieux).
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1.1 — Configuration (versionnée, 1 ligne active). Modifiable depuis l'UI PDG.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_cash_config (
  id                               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  withdrawal_fee_percent           numeric NOT NULL DEFAULT 1.2,
  withdrawal_fee_min               numeric NOT NULL DEFAULT 1000,
  withdrawal_fee_max               numeric NOT NULL DEFAULT 30000,
  withdrawal_agent_share_of_fee    numeric NOT NULL DEFAULT 30,   -- % DES FRAIS
  withdrawal_pdg_share_of_fee      numeric NOT NULL DEFAULT 70,   -- % DES FRAIS
  deposit_agent_commission_percent numeric NOT NULL DEFAULT 0.2,
  activation_float_threshold       numeric NOT NULL DEFAULT 2500000,
  min_float_for_operations         numeric NOT NULL DEFAULT 100000,
  daily_commission_cap_per_agent   numeric NOT NULL DEFAULT 500000,
  anti_split_window_minutes        int     NOT NULL DEFAULT 30,
  is_active                        boolean NOT NULL DEFAULT true,
  created_at                       timestamptz NOT NULL DEFAULT now(),
  created_by                       uuid,
  CONSTRAINT ck_agent_cash_share_100 CHECK (withdrawal_agent_share_of_fee + withdrawal_pdg_share_of_fee = 100),
  CONSTRAINT ck_agent_cash_positive  CHECK (withdrawal_fee_min >= 0 AND withdrawal_fee_max >= withdrawal_fee_min
                                            AND withdrawal_fee_percent >= 0 AND deposit_agent_commission_percent >= 0)
);
ALTER TABLE public.agent_cash_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS acc_pdg_read  ON public.agent_cash_config;
DROP POLICY IF EXISTS acc_pdg_write ON public.agent_cash_config;
CREATE POLICY acc_pdg_read  ON public.agent_cash_config FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
CREATE POLICY acc_pdg_write ON public.agent_cash_config FOR ALL    TO authenticated USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());
REVOKE ALL ON public.agent_cash_config FROM anon;

-- Une seule ligne active à la fois (index partiel).
CREATE UNIQUE INDEX IF NOT EXISTS uq_agent_cash_config_active ON public.agent_cash_config (is_active) WHERE is_active = true;

-- Seed d'une config active par défaut (idempotent).
INSERT INTO public.agent_cash_config (is_active)
SELECT true WHERE NOT EXISTS (SELECT 1 FROM public.agent_cash_config WHERE is_active = true);

-- Lecture de la config active (source unique pour TOUTES les RPC — jamais de valeur en dur).
CREATE OR REPLACE FUNCTION public.agent_cash_active_config()
RETURNS public.agent_cash_config
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.agent_cash_config WHERE is_active = true ORDER BY created_at DESC LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.agent_cash_active_config() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_active_config() TO authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- A1.2 — Soldes cash de l'agent (sur agents_management ; 3 soldes séparés).
--   float (outil de travail) / commissions (gains retirables) / perso = wallet classique.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.agents_management
  ADD COLUMN IF NOT EXISTS cash_float_balance      numeric NOT NULL DEFAULT 0 CHECK (cash_float_balance >= 0),
  ADD COLUMN IF NOT EXISTS cash_commission_balance numeric NOT NULL DEFAULT 0 CHECK (cash_commission_balance >= 0),
  ADD COLUMN IF NOT EXISTS cash_agent_active       boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS cash_agent_suspended    boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS cash_suspended_reason   text,
  ADD COLUMN IF NOT EXISTS cash_suspended_at       timestamptz;

-- ─────────────────────────────────────────────────────────────────────────────
-- A1.3 — En-tête d'opération (idempotence + résumé). idempotency_key UNIQUE.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_cash_operations (
  parent_tx_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key text UNIQUE NOT NULL,
  operation       text NOT NULL CHECK (operation IN ('deposit','withdrawal','float_topup','commission_payout','commission_pending_release','commission_move')),
  agent_id        uuid,
  client_user_id  uuid,
  amount          numeric,
  fee             numeric DEFAULT 0,
  agent_share     numeric DEFAULT 0,
  pdg_share       numeric DEFAULT 0,
  result          jsonb,
  created_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.agent_cash_operations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS aco_pdg_read ON public.agent_cash_operations;
CREATE POLICY aco_pdg_read ON public.agent_cash_operations FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
REVOKE ALL ON public.agent_cash_operations FROM anon;
CREATE INDEX IF NOT EXISTS ix_aco_agent_time  ON public.agent_cash_operations (agent_id, created_at);
CREATE INDEX IF NOT EXISTS ix_aco_pair_time   ON public.agent_cash_operations (agent_id, client_user_id, created_at);

-- ─────────────────────────────────────────────────────────────────────────────
-- A1.4 — Ledger double-entrée IMMUABLE (aucun UPDATE/DELETE).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_cash_ledger (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  parent_tx_id   uuid NOT NULL,
  operation      text NOT NULL,
  leg            text NOT NULL CHECK (leg IN (
                   'client_debit','client_credit','agent_float_credit','agent_float_debit',
                   'pdg_fee_credit','pdg_commission_debit','agent_commission_credit',
                   'agent_commission_debit','agent_personal_credit')),
  agent_id       uuid,
  client_user_id uuid,
  amount         numeric NOT NULL CHECK (amount >= 0),
  currency       text NOT NULL DEFAULT 'GNF',
  status         text NOT NULL DEFAULT 'completed' CHECK (status IN ('completed','pending')),
  created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.agent_cash_ledger ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS acl_pdg_read ON public.agent_cash_ledger;
CREATE POLICY acl_pdg_read ON public.agent_cash_ledger FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
REVOKE ALL ON public.agent_cash_ledger FROM anon;
CREATE INDEX IF NOT EXISTS ix_acl_agent_time ON public.agent_cash_ledger (agent_id, created_at);
CREATE INDEX IF NOT EXISTS ix_acl_parent      ON public.agent_cash_ledger (parent_tx_id);

-- Immuabilité : interdit UPDATE/DELETE (même à service_role via trigger).
REVOKE UPDATE, DELETE ON public.agent_cash_ledger FROM PUBLIC, anon, authenticated, service_role;
CREATE OR REPLACE FUNCTION public.agent_cash_ledger_immutable()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'agent_cash_ledger est IMMUABLE (ni UPDATE ni DELETE)';
END $$;
DROP TRIGGER IF EXISTS trg_acl_immutable ON public.agent_cash_ledger;
CREATE TRIGGER trg_acl_immutable BEFORE UPDATE OR DELETE ON public.agent_cash_ledger
  FOR EACH ROW EXECUTE FUNCTION public.agent_cash_ledger_immutable();

-- ─────────────────────────────────────────────────────────────────────────────
-- A1.5 — Commissions séquestrées (PDG insuffisant / agent suspendu / plafond jour).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_commission_pending (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id             uuid NOT NULL,
  amount               numeric NOT NULL CHECK (amount > 0),
  reason               text,
  source_parent_tx_id  uuid,
  status               text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','released','confiscated')),
  resolved_by          uuid,
  resolved_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.agent_commission_pending ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS acp_pdg_read ON public.agent_commission_pending;
CREATE POLICY acp_pdg_read ON public.agent_commission_pending FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
REVOKE ALL ON public.agent_commission_pending FROM anon;
CREATE INDEX IF NOT EXISTS ix_acp_agent_status ON public.agent_commission_pending (agent_id, status);

-- ─────────────────────────────────────────────────────────────────────────────
-- A1.6 — Demandes de retrait de commissions (Orange Money / banque). Auto = plus tard.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_commission_payout_requests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id      uuid NOT NULL,
  amount        numeric NOT NULL CHECK (amount > 0),
  method        text NOT NULL CHECK (method IN ('orange_money','bank')),
  destination   jsonb,        -- {phone|iban|account...} — masqué hors PDG côté app
  status        text NOT NULL DEFAULT 'pending_pdg' CHECK (status IN ('pending_pdg','processing','paid','rejected')),
  reject_reason text,
  processed_by  uuid,
  processed_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.agent_commission_payout_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS acpr_pdg_read ON public.agent_commission_payout_requests;
CREATE POLICY acpr_pdg_read ON public.agent_commission_payout_requests FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
REVOKE ALL ON public.agent_commission_payout_requests FROM anon;
CREATE INDEX IF NOT EXISTS ix_acpr_status ON public.agent_commission_payout_requests (status, created_at);

-- ─────────────────────────────────────────────────────────────────────────────
-- A1.7 — OTP client pour le retrait (client peut être hors ligne). TTL 5 min, 3 essais.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agent_cash_otp (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id       uuid NOT NULL,
  client_user_id uuid NOT NULL,
  otp_hash       text NOT NULL,
  amount         numeric,
  attempts       int NOT NULL DEFAULT 0,
  consumed       boolean NOT NULL DEFAULT false,
  expires_at     timestamptz NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.agent_cash_otp ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.agent_cash_otp FROM anon, authenticated;  -- backend service_role uniquement
CREATE INDEX IF NOT EXISTS ix_aco_otp_pair ON public.agent_cash_otp (agent_id, client_user_id, created_at DESC);

-- ============================================================================
-- A2 — RPC ATOMIQUES
-- ============================================================================

-- Helpers internes de mouvement wallet (verrou + CHECK), utilisés dans les RPC ci-dessous.
-- Débit direct verrouillé d'un wallet par id, échec propre si solde insuffisant.
CREATE OR REPLACE FUNCTION public._acash_debit_wallet(p_wallet_id bigint, p_amount numeric, p_err text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_bal numeric;
BEGIN
  SELECT balance INTO v_bal FROM public.wallets WHERE id = p_wallet_id FOR UPDATE;
  IF v_bal IS NULL THEN RAISE EXCEPTION 'WALLET_INTROUVABLE'; END IF;
  IF v_bal < p_amount THEN RAISE EXCEPTION '%', p_err; END IF;
  UPDATE public.wallets SET balance = balance - p_amount, updated_at = now() WHERE id = p_wallet_id;
END $$;

CREATE OR REPLACE FUNCTION public._acash_credit_wallet(p_wallet_id bigint, p_amount numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.wallets SET balance = COALESCE(balance,0) + p_amount, updated_at = now() WHERE id = p_wallet_id;
END $$;

-- ── A2.a : Activation cash de l'agent (conversion float depuis son wallet perso) ──
-- Mécanisme retenu (documenté) : le float est alimenté depuis le WALLET PERSO GNF de l'agent
-- (l'agent recharge d'abord son wallet via Orange Money/banque = flux existants), puis convertit
-- wallet perso → cash_float_balance. Aucun mint : c'est un DÉPLACEMENT interne tracé.
CREATE OR REPLACE FUNCTION public.agent_activate_cash(
  p_agent_id uuid, p_topup_amount numeric, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent uuid; v_agent RECORD; v_wallet_id bigint; v_cfg public.agent_cash_config;
BEGIN
  IF p_topup_amount IS NULL OR p_topup_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  v_cfg := public.agent_cash_active_config();

  -- Idempotence
  INSERT INTO public.agent_cash_operations (idempotency_key, operation, agent_id, amount)
  VALUES (p_idempotency_key, 'float_topup', p_agent_id, p_topup_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.agent_cash_operations WHERE idempotency_key = p_idempotency_key);
  END IF;

  SELECT * INTO v_agent FROM public.agents_management WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_INTROUVABLE'; END IF;

  SELECT id INTO v_wallet_id FROM public.wallets WHERE user_id = v_agent.user_id AND currency = 'GNF' FOR UPDATE;
  IF v_wallet_id IS NULL THEN RAISE EXCEPTION 'WALLET_AGENT_INTROUVABLE'; END IF;

  -- Déplacement perso → float
  PERFORM public._acash_debit_wallet(v_wallet_id, p_topup_amount, 'SOLDE_PERSO_INSUFFISANT');
  UPDATE public.agents_management
  SET cash_float_balance = cash_float_balance + p_topup_amount,
      cash_agent_active = (cash_float_balance + p_topup_amount) >= v_cfg.activation_float_threshold,
      updated_at = now()
  WHERE id = p_agent_id;

  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount)
  VALUES (v_parent, 'float_topup', 'agent_float_credit', p_agent_id, p_topup_amount);

  UPDATE public.agent_cash_operations SET result = jsonb_build_object(
    'success', true, 'parent_tx_id', v_parent, 'float_added', p_topup_amount,
    'cash_agent_active', (SELECT cash_agent_active FROM public.agents_management WHERE id = p_agent_id)
  ) WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $$;
REVOKE ALL ON FUNCTION public.agent_activate_cash(uuid, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_activate_cash(uuid, numeric, text) TO service_role;

-- ── A2.b : Dépôt cash (client crédité du montant EXACT, 0 frais client) ──
CREATE OR REPLACE FUNCTION public.agent_cash_deposit(
  p_agent_id uuid, p_client_user_id uuid, p_amount numeric, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent uuid; v_agent RECORD; v_cfg public.agent_cash_config;
  v_commission numeric; v_pdg_wallet bigint; v_pdg_bal numeric; v_paid boolean := false;
  v_credit_res jsonb;
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

  -- Verrous ordre déterministe : agent d'abord (float), PDG ensuite. (Le wallet client est
  -- verrouillé DANS credit_user_wallet_safe.)
  SELECT * INTO v_agent FROM public.agents_management WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_INTROUVABLE'; END IF;
  IF NOT v_agent.cash_agent_active OR v_agent.cash_agent_suspended THEN RAISE EXCEPTION 'AGENT_INACTIF'; END IF;
  IF v_agent.cash_float_balance < v_cfg.min_float_for_operations THEN RAISE EXCEPTION 'FLOAT_INSUFFISANT'; END IF;
  IF v_agent.cash_float_balance < p_amount THEN RAISE EXCEPTION 'FLOAT_INSUFFISANT'; END IF;

  -- 1) Float agent -= montant
  UPDATE public.agents_management SET cash_float_balance = cash_float_balance - p_amount, updated_at = now()
  WHERE id = p_agent_id;
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
  VALUES (v_parent, 'deposit', 'agent_float_debit', p_agent_id, p_client_user_id, p_amount);

  -- 2) Client crédité du montant EXACT (canonique : conserve l'AML)
  v_credit_res := public.credit_user_wallet_safe(p_client_user_id, p_amount, 'GNF', 'agent_cash_deposit', v_parent::text);
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
  VALUES (v_parent, 'deposit', 'client_credit', p_agent_id, p_client_user_id, p_amount);

  -- 3) Commission de dépôt (payée par le PDG). Si PDG insuffisant/agent suspendu → pending.
  v_commission := round(p_amount * v_cfg.deposit_agent_commission_percent / 100.0, 2);
  IF v_commission > 0 THEN
    v_pdg_wallet := public.get_pdg_gnf_wallet_id();
    IF v_pdg_wallet IS NOT NULL AND NOT v_agent.cash_agent_suspended THEN
      SELECT balance INTO v_pdg_bal FROM public.wallets WHERE id = v_pdg_wallet FOR UPDATE;
      IF v_pdg_bal >= v_commission THEN
        PERFORM public._acash_debit_wallet(v_pdg_wallet, v_commission, 'PDG_INSUFFISANT');
        UPDATE public.agents_management SET cash_commission_balance = cash_commission_balance + v_commission, updated_at = now()
        WHERE id = p_agent_id;
        INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
        VALUES (v_parent, 'deposit', 'pdg_commission_debit', p_agent_id, p_client_user_id, v_commission),
               (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, v_commission);
        v_paid := true;
      END IF;
    END IF;
    IF NOT v_paid THEN
      INSERT INTO public.agent_commission_pending (agent_id, amount, reason, source_parent_tx_id)
      VALUES (p_agent_id, v_commission, CASE WHEN v_agent.cash_agent_suspended THEN 'agent_suspendu' ELSE 'pdg_insuffisant' END, v_parent);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, status)
      VALUES (v_parent, 'deposit', 'agent_commission_credit', p_agent_id, p_client_user_id, v_commission, 'pending');
    END IF;
  END IF;

  UPDATE public.agent_cash_operations SET agent_share = v_commission, result = jsonb_build_object(
    'success', true, 'parent_tx_id', v_parent, 'client_credited', p_amount,
    'agent_commission', v_commission, 'commission_paid', v_paid,
    'quarantined', COALESCE((v_credit_res->>'quarantined')::numeric, 0)
  ) WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_deposit(uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_deposit(uuid, uuid, numeric, text) TO service_role;

-- ── A2.c : Retrait cash (frais client, transit PDG, part agent 30% des frais) ──
CREATE OR REPLACE FUNCTION public.agent_cash_withdrawal(
  p_agent_id uuid, p_client_user_id uuid, p_amount numeric, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent uuid; v_agent RECORD; v_cfg public.agent_cash_config;
  v_client_wallet bigint; v_pdg_wallet bigint;
  v_fee numeric; v_agent_share numeric; v_pdg_share numeric;
  v_win_amount numeric := 0; v_win_fees numeric := 0; v_cum_fee numeric;
  v_day_comm numeric := 0; v_to_pending boolean := false; v_reason text := NULL;
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
  IF v_agent.cash_float_balance < v_cfg.min_float_for_operations THEN RAISE EXCEPTION 'FLOAT_INSUFFISANT'; END IF;

  -- Anti-splitting : frais sur le CUMUL de la fenêtre, moins les frais déjà payés.
  SELECT COALESCE(sum(amount),0), COALESCE(sum(fee),0) INTO v_win_amount, v_win_fees
  FROM public.agent_cash_operations
  WHERE operation = 'withdrawal' AND agent_id = p_agent_id AND client_user_id = p_client_user_id
    AND created_at > now() - make_interval(mins => v_cfg.anti_split_window_minutes)
    AND parent_tx_id <> v_parent;
  v_cum_fee := least(greatest(round((v_win_amount + p_amount) * v_cfg.withdrawal_fee_percent / 100.0, 2), v_cfg.withdrawal_fee_min), v_cfg.withdrawal_fee_max);
  v_fee := greatest(v_cum_fee - v_win_fees, 0);
  -- Part agent = frais × part% ; part PDG = frais − part agent (par soustraction → somme exacte).
  v_agent_share := round(v_fee * v_cfg.withdrawal_agent_share_of_fee / 100.0, 2);
  v_pdg_share   := v_fee - v_agent_share;

  -- 1) Client débité de (montant + frais). Verrou wallet client.
  SELECT id INTO v_client_wallet FROM public.wallets WHERE user_id = p_client_user_id AND currency = 'GNF';
  IF v_client_wallet IS NULL THEN RAISE EXCEPTION 'WALLET_CLIENT_INTROUVABLE'; END IF;
  PERFORM public._acash_debit_wallet(v_client_wallet, p_amount + v_fee, 'SOLDE_INSUFFISANT');
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
  VALUES (v_parent, 'withdrawal', 'client_debit', p_agent_id, p_client_user_id, p_amount + v_fee);

  -- 2) Float agent += montant (il rend le cash physique)
  UPDATE public.agents_management SET cash_float_balance = cash_float_balance + p_amount, updated_at = now()
  WHERE id = p_agent_id;
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
  VALUES (v_parent, 'withdrawal', 'agent_float_credit', p_agent_id, p_client_user_id, p_amount);

  -- 3) Transit PDG : frais entrent au PDG, puis part agent en sort.
  v_pdg_wallet := public.get_pdg_gnf_wallet_id();
  IF v_pdg_wallet IS NULL THEN RAISE EXCEPTION 'PDG_INTROUVABLE'; END IF;
  IF v_fee > 0 THEN
    PERFORM public._acash_credit_wallet(v_pdg_wallet, v_fee);
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
    VALUES (v_parent, 'withdrawal', 'pdg_fee_credit', p_agent_id, p_client_user_id, v_fee);
  END IF;

  -- Plafond commission journalier + kill switch → part agent en pending.
  SELECT COALESCE(sum(agent_share),0) INTO v_day_comm FROM public.agent_cash_operations
  WHERE agent_id = p_agent_id AND operation = 'withdrawal' AND created_at::date = now()::date AND parent_tx_id <> v_parent;
  IF v_agent.cash_agent_suspended THEN v_to_pending := true; v_reason := 'agent_suspendu';
  ELSIF (v_day_comm + v_agent_share) > v_cfg.daily_commission_cap_per_agent THEN v_to_pending := true; v_reason := 'plafond_journalier';
  END IF;

  IF v_agent_share > 0 THEN
    IF v_to_pending THEN
      -- Part agent séquestrée ; le PDG garde temporairement la part (débit différé).
      INSERT INTO public.agent_commission_pending (agent_id, amount, reason, source_parent_tx_id)
      VALUES (p_agent_id, v_agent_share, v_reason, v_parent);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount, status)
      VALUES (v_parent, 'withdrawal', 'agent_commission_credit', p_agent_id, p_client_user_id, v_agent_share, 'pending');
      INSERT INTO public.agent_audit_log_safe(severity, event, detail)
      VALUES ('warning', 'agent_cash_commission_pending', jsonb_build_object('agent_id', p_agent_id, 'amount', v_agent_share, 'reason', v_reason, 'parent_tx_id', v_parent));
    ELSE
      PERFORM public._acash_debit_wallet(v_pdg_wallet, v_agent_share, 'PDG_INSUFFISANT');
      UPDATE public.agents_management SET cash_commission_balance = cash_commission_balance + v_agent_share, updated_at = now()
      WHERE id = p_agent_id;
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, client_user_id, amount)
      VALUES (v_parent, 'withdrawal', 'pdg_commission_debit', p_agent_id, p_client_user_id, v_agent_share),
             (v_parent, 'withdrawal', 'agent_commission_credit', p_agent_id, p_client_user_id, v_agent_share);
    END IF;
  END IF;

  UPDATE public.agent_cash_operations
  SET fee = v_fee, agent_share = v_agent_share, pdg_share = v_pdg_share,
      result = jsonb_build_object('success', true, 'parent_tx_id', v_parent, 'amount', p_amount,
        'fee', v_fee, 'agent_share', v_agent_share, 'pdg_share', v_pdg_share, 'commission_pending', v_to_pending)
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_withdrawal(uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_withdrawal(uuid, uuid, numeric, text) TO service_role;

-- Petit journal d'audit tolérant (crée la table si le projet n'en a pas de standard ici).
CREATE TABLE IF NOT EXISTS public.agent_cash_audit_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  severity text, event text, detail jsonb, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.agent_cash_audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS acal_pdg_read ON public.agent_cash_audit_log;
CREATE POLICY acal_pdg_read ON public.agent_cash_audit_log FOR SELECT TO authenticated USING (public.is_admin_or_pdg());
REVOKE ALL ON public.agent_cash_audit_log FROM anon;
CREATE OR REPLACE FUNCTION public.agent_audit_log_safe(severity text, event text, detail jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.agent_cash_audit_log (severity, event, detail) VALUES (severity, event, detail);
END $$;

-- ── A2.d : Libération/confiscation d'une commission pending (PDG only) ──
CREATE OR REPLACE FUNCTION public.agent_cash_release_pending(p_pending_id uuid, p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_p RECORD; v_pdg_wallet bigint; v_pdg_bal numeric; v_parent uuid := gen_random_uuid();
BEGIN
  -- service_role de confiance (backend, PDG déjà vérifié à l'endpoint) → auth.uid() NULL ;
  -- appel authentifié direct → doit être admin/PDG.
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_action NOT IN ('release','confiscate') THEN RAISE EXCEPTION 'ACTION_INVALIDE'; END IF;
  SELECT * INTO v_p FROM public.agent_commission_pending WHERE id = p_pending_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PENDING_INTROUVABLE'; END IF;
  IF v_p.status <> 'pending' THEN RAISE EXCEPTION 'DEJA_RESOLU'; END IF;

  IF p_action = 'release' THEN
    v_pdg_wallet := public.get_pdg_gnf_wallet_id();
    SELECT balance INTO v_pdg_bal FROM public.wallets WHERE id = v_pdg_wallet FOR UPDATE;
    IF v_pdg_bal < v_p.amount THEN RAISE EXCEPTION 'PDG_INSUFFISANT'; END IF;
    PERFORM public._acash_debit_wallet(v_pdg_wallet, v_p.amount, 'PDG_INSUFFISANT');
    UPDATE public.agents_management SET cash_commission_balance = cash_commission_balance + v_p.amount, updated_at = now()
    WHERE id = v_p.agent_id;
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount)
    VALUES (v_parent, 'commission_pending_release', 'pdg_commission_debit', v_p.agent_id, v_p.amount),
           (v_parent, 'commission_pending_release', 'agent_commission_credit', v_p.agent_id, v_p.amount);
  END IF;

  UPDATE public.agent_commission_pending
  SET status = CASE WHEN p_action='release' THEN 'released' ELSE 'confiscated' END,
      resolved_by = auth.uid(), resolved_at = now()
  WHERE id = p_pending_id;
  RETURN jsonb_build_object('success', true, 'id', p_pending_id, 'action', p_action);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_release_pending(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_release_pending(uuid, text) TO authenticated, service_role;

-- ── A2.e : Demande de retrait des commissions agent (4 canaux) ──
CREATE OR REPLACE FUNCTION public.agent_commission_withdrawal_request(
  p_agent_id uuid, p_amount numeric, p_method text, p_destination jsonb, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_parent uuid; v_agent RECORD; v_wallet_id bigint; v_req uuid;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  IF p_method NOT IN ('orange_money','bank','to_personal_wallet','to_float') THEN RAISE EXCEPTION 'METHODE_INVALIDE'; END IF;

  INSERT INTO public.agent_cash_operations (idempotency_key, operation, agent_id, amount)
  VALUES (p_idempotency_key, 'commission_payout', p_agent_id, p_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.agent_cash_operations WHERE idempotency_key = p_idempotency_key);
  END IF;

  SELECT * INTO v_agent FROM public.agents_management WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_INTROUVABLE'; END IF;
  IF v_agent.cash_commission_balance < p_amount THEN RAISE EXCEPTION 'COMMISSION_INSUFFISANTE'; END IF;

  -- Débit du solde commissions dans TOUS les cas (réservé immédiatement).
  UPDATE public.agents_management SET cash_commission_balance = cash_commission_balance - p_amount, updated_at = now()
  WHERE id = p_agent_id;
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount)
  VALUES (v_parent, 'commission_payout', 'agent_commission_debit', p_agent_id, p_amount);

  IF p_method IN ('to_personal_wallet','to_float') THEN
    IF p_method = 'to_personal_wallet' THEN
      SELECT id INTO v_wallet_id FROM public.wallets WHERE user_id = v_agent.user_id AND currency = 'GNF' FOR UPDATE;
      IF v_wallet_id IS NULL THEN RAISE EXCEPTION 'WALLET_AGENT_INTROUVABLE'; END IF;
      PERFORM public._acash_credit_wallet(v_wallet_id, p_amount);
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount)
      VALUES (v_parent, 'commission_move', 'agent_personal_credit', p_agent_id, p_amount);
    ELSE
      UPDATE public.agents_management SET cash_float_balance = cash_float_balance + p_amount,
             cash_agent_active = (cash_float_balance + p_amount) >= (public.agent_cash_active_config()).activation_float_threshold, updated_at = now()
      WHERE id = p_agent_id;
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount)
      VALUES (v_parent, 'commission_move', 'agent_float_credit', p_agent_id, p_amount);
    END IF;
    UPDATE public.agent_cash_operations SET result = jsonb_build_object('success', true, 'method', p_method, 'amount', p_amount, 'immediate', true)
    WHERE parent_tx_id = v_parent;
  ELSE
    -- Orange Money / banque : demande PDG (solde déjà réservé).
    INSERT INTO public.agent_commission_payout_requests (agent_id, amount, method, destination)
    VALUES (p_agent_id, p_amount, p_method, p_destination) RETURNING id INTO v_req;
    UPDATE public.agent_cash_operations SET result = jsonb_build_object('success', true, 'method', p_method, 'amount', p_amount, 'request_id', v_req, 'status', 'pending_pdg')
    WHERE parent_tx_id = v_parent;
  END IF;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $$;
REVOKE ALL ON FUNCTION public.agent_commission_withdrawal_request(uuid, numeric, text, jsonb, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_commission_withdrawal_request(uuid, numeric, text, jsonb, text) TO service_role;

-- ── A2.f : Exécution PDG d'une demande de payout (marquer payé / rejeter) ──
CREATE OR REPLACE FUNCTION public.agent_commission_payout_execute(p_request_id uuid, p_action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_r RECORD; v_parent uuid := gen_random_uuid();
BEGIN
  -- service_role de confiance (backend, PDG déjà vérifié à l'endpoint) → auth.uid() NULL ;
  -- appel authentifié direct → doit être admin/PDG.
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_action NOT IN ('approve_paid','reject') THEN RAISE EXCEPTION 'ACTION_INVALIDE'; END IF;
  SELECT * INTO v_r FROM public.agent_commission_payout_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEMANDE_INTROUVABLE'; END IF;
  IF v_r.status NOT IN ('pending_pdg','processing') THEN RAISE EXCEPTION 'DEJA_TRAITE'; END IF;

  IF p_action = 'approve_paid' THEN
    UPDATE public.agent_commission_payout_requests SET status='paid', processed_by=auth.uid(), processed_at=now() WHERE id=p_request_id;
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount)
    VALUES (v_parent, 'commission_payout', 'agent_commission_debit', v_r.agent_id, v_r.amount);
  ELSE
    -- Rejet : re-créditer la commission à l'agent (le solde avait été réservé).
    UPDATE public.agents_management SET cash_commission_balance = cash_commission_balance + v_r.amount, updated_at=now() WHERE id=v_r.agent_id;
    UPDATE public.agent_commission_payout_requests SET status='rejected', processed_by=auth.uid(), processed_at=now() WHERE id=p_request_id;
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount)
    VALUES (v_parent, 'commission_payout', 'agent_commission_credit', v_r.agent_id, v_r.amount);
  END IF;
  RETURN jsonb_build_object('success', true, 'request_id', p_request_id, 'action', p_action);
END $$;
REVOKE ALL ON FUNCTION public.agent_commission_payout_execute(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_commission_payout_execute(uuid, text) TO authenticated, service_role;

-- ── Suspension / réactivation (kill switch PDG) ──
CREATE OR REPLACE FUNCTION public.agent_cash_set_suspended(p_agent_id uuid, p_suspended boolean, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- service_role de confiance (backend, PDG déjà vérifié à l'endpoint) → auth.uid() NULL ;
  -- appel authentifié direct → doit être admin/PDG.
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  UPDATE public.agents_management
  SET cash_agent_suspended = p_suspended,
      cash_suspended_reason = CASE WHEN p_suspended THEN p_reason ELSE NULL END,
      cash_suspended_at     = CASE WHEN p_suspended THEN now() ELSE NULL END,
      updated_at = now()
  WHERE id = p_agent_id;
  RETURN jsonb_build_object('success', true, 'agent_id', p_agent_id, 'suspended', p_suspended);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_set_suspended(uuid, boolean, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_set_suspended(uuid, boolean, text) TO authenticated, service_role;

-- ============================================================================
-- A3 — Réconciliation (pattern leak-check). Lecture seule ; anomalies → audit log.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.agent_cash_reconciliation_check()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_unbalanced int; v_float_drift int; v_report jsonb;
BEGIN
  -- Invariant 1 : par parent_tx_id, somme(débits) = somme(crédits).
  SELECT count(*) INTO v_unbalanced FROM (
    SELECT parent_tx_id,
      sum(CASE WHEN leg LIKE '%_debit' THEN amount ELSE 0 END) AS deb,
      sum(CASE WHEN leg LIKE '%_credit' THEN amount ELSE 0 END) AS cred
    FROM public.agent_cash_ledger WHERE status = 'completed'
    GROUP BY parent_tx_id
    HAVING abs(sum(CASE WHEN leg LIKE '%_debit' THEN amount ELSE 0 END)
             - sum(CASE WHEN leg LIKE '%_credit' THEN amount ELSE 0 END)) > 1
  ) d;

  -- Invariant 2 : float agent = somme(float_credit) − somme(float_debit) du ledger.
  SELECT count(*) INTO v_float_drift FROM (
    SELECT a.id,
      a.cash_float_balance AS bal,
      COALESCE(sum(CASE WHEN l.leg='agent_float_credit' THEN l.amount
                        WHEN l.leg='agent_float_debit'  THEN -l.amount ELSE 0 END),0) AS expected
    FROM public.agents_management a
    LEFT JOIN public.agent_cash_ledger l ON l.agent_id = a.id AND l.status='completed'
    GROUP BY a.id, a.cash_float_balance
    HAVING abs(a.cash_float_balance - COALESCE(sum(CASE WHEN l.leg='agent_float_credit' THEN l.amount
                        WHEN l.leg='agent_float_debit'  THEN -l.amount ELSE 0 END),0)) > 1
  ) f;

  v_report := jsonb_build_object('generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','ledger_unbalanced','label','Opérations dont débits ≠ crédits','severity','critical','count',v_unbalanced,'observed',v_unbalanced),
      jsonb_build_object('key','float_drift','label','Float agent ≠ somme des legs float','severity','critical','count',v_float_drift,'observed',v_float_drift)
    ));
  IF v_unbalanced > 0 OR v_float_drift > 0 THEN
    PERFORM public.agent_audit_log_safe('critical', 'agent_cash_reconciliation_anomaly', v_report);
  END IF;
  RETURN v_report;
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_reconciliation_check() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_reconciliation_check() TO authenticated, service_role;

-- ── Config : nouvelle version active (PDG). Historise (l'ancienne → is_active=false). ──
CREATE OR REPLACE FUNCTION public.agent_cash_config_update(p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cur public.agent_cash_config; v_new_id uuid;
BEGIN
  -- service_role de confiance (backend, PDG déjà vérifié à l'endpoint) → auth.uid() NULL ;
  -- appel authentifié direct → doit être admin/PDG.
  IF auth.uid() IS NOT NULL AND NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  v_cur := public.agent_cash_active_config();
  UPDATE public.agent_cash_config SET is_active = false WHERE is_active = true;
  INSERT INTO public.agent_cash_config (
    withdrawal_fee_percent, withdrawal_fee_min, withdrawal_fee_max,
    withdrawal_agent_share_of_fee, withdrawal_pdg_share_of_fee,
    deposit_agent_commission_percent, activation_float_threshold,
    min_float_for_operations, daily_commission_cap_per_agent, anti_split_window_minutes,
    is_active, created_by)
  VALUES (
    COALESCE((p_changes->>'withdrawal_fee_percent')::numeric, v_cur.withdrawal_fee_percent),
    COALESCE((p_changes->>'withdrawal_fee_min')::numeric, v_cur.withdrawal_fee_min),
    COALESCE((p_changes->>'withdrawal_fee_max')::numeric, v_cur.withdrawal_fee_max),
    COALESCE((p_changes->>'withdrawal_agent_share_of_fee')::numeric, v_cur.withdrawal_agent_share_of_fee),
    COALESCE((p_changes->>'withdrawal_pdg_share_of_fee')::numeric, v_cur.withdrawal_pdg_share_of_fee),
    COALESCE((p_changes->>'deposit_agent_commission_percent')::numeric, v_cur.deposit_agent_commission_percent),
    COALESCE((p_changes->>'activation_float_threshold')::numeric, v_cur.activation_float_threshold),
    COALESCE((p_changes->>'min_float_for_operations')::numeric, v_cur.min_float_for_operations),
    COALESCE((p_changes->>'daily_commission_cap_per_agent')::numeric, v_cur.daily_commission_cap_per_agent),
    COALESCE((p_changes->>'anti_split_window_minutes')::int, v_cur.anti_split_window_minutes),
    true, auth.uid())
  RETURNING id INTO v_new_id;   -- le CHECK ck_agent_cash_share_100 bloque si parts ≠ 100
  RETURN jsonb_build_object('success', true, 'config_id', v_new_id);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_config_update(jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_config_update(jsonb) TO authenticated, service_role;

SELECT 'Système Agent Cash installé : config + 3 soldes + ledger immuable + 6 RPC atomiques + réconciliation.' AS status;
