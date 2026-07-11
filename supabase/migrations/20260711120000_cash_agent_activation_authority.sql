-- ============================================================================
-- 💵 AGENT CASH — Autorité d'activation RÉELLE (correctif) + Retrait moi-même
-- ----------------------------------------------------------------------------
-- Deux corrections de malentendus (décision PDG, source de vérité) :
--  1) L'activation d'un agent cash est réservée au PDG ET aux AGENTS DE GESTION
--     (agents_management) AYANT la permission `can_activate_cash_agents`. AUCUN agent
--     cash ni « sous-agent » ne peut activer qui que ce soit → le PARRAINAGE agent-cash
--     est SUPPRIMÉ (retiré de activate_cash_agent ; gardes SPONSORSHIP_* obsolètes).
--  2) Nouveau « Retrait moi-même » : l'agent convertit son propre wallet perso en float
--     (wallet perso débité, float crédité), frais selon self_withdrawal_fee_percent (DÉFAUT 0).
-- Recréation DEPUIS LA DÉFINITION LIVE (leçon du garde FX). RPC financières inchangées.
-- ============================================================================

-- ── 1) Permission d'activation (sur les agents de GESTION uniquement) ────────
ALTER TABLE public.agents_management
  ADD COLUMN IF NOT EXISTS can_activate_cash_agents boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.agents_management.can_activate_cash_agents IS
  'Permission PDG : cet agent DE GESTION peut activer des comptes agent cash. Aucun agent cash ne l''obtient (défaut false).';
COMMENT ON COLUMN public.agents_management.cash_enabled_by IS
  'activated_by (traçabilité) : user_id de l''activateur (PDG ou agent de gestion) ayant activé cet agent cash. PAS un parrainage.';

-- ── 2) Config : self_withdrawal_fee_percent + dépréciation du parrainage ─────
ALTER TABLE public.agent_cash_config
  ADD COLUMN IF NOT EXISTS self_withdrawal_fee_percent numeric NOT NULL DEFAULT 0 CHECK (self_withdrawal_fee_percent >= 0);
COMMENT ON COLUMN public.agent_cash_config.self_withdrawal_fee_percent IS
  'Frais du « Retrait moi-même » de l''agent (% du montant). DÉFAUT 0 (son propre argent). Réglable PDG.';
COMMENT ON COLUMN public.agent_cash_config.allow_agent_sponsorship IS
  'DÉPRÉCIÉ (2026-07-11) : le parrainage agent-cash→agent-cash n''existe plus. Conservé pour l''historique des versions.';
COMMENT ON COLUMN public.agent_cash_config.max_sub_agents_per_sponsor IS
  'DÉPRÉCIÉ (2026-07-11) : parrainage supprimé. Conservé pour l''historique des versions.';

-- ── 3) CHECK : accepter self_withdrawal (opération) + agent_personal_debit (leg) ──
ALTER TABLE public.agent_cash_operations DROP CONSTRAINT IF EXISTS agent_cash_operations_operation_check;
ALTER TABLE public.agent_cash_operations ADD CONSTRAINT agent_cash_operations_operation_check
  CHECK (operation = ANY (ARRAY['deposit','withdrawal','float_topup','self_withdrawal','commission_payout','commission_pending_release','commission_move']));
ALTER TABLE public.agent_cash_ledger DROP CONSTRAINT IF EXISTS agent_cash_ledger_leg_check;
ALTER TABLE public.agent_cash_ledger ADD CONSTRAINT agent_cash_ledger_leg_check
  CHECK (leg = ANY (ARRAY['client_debit','client_credit','agent_float_credit','agent_float_debit','pdg_fee_credit','pdg_commission_debit','agent_commission_credit','agent_commission_debit','agent_personal_credit','agent_personal_debit']));

-- ── 4) activate_cash_agent : autorité PDG + permission ; PARRAINAGE SUPPRIMÉ ──
CREATE OR REPLACE FUNCTION public.activate_cash_agent(
  p_target_user_id uuid,
  p_actor_user_id  uuid,
  p_actor_is_pdg   boolean
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pdg_id uuid;
  v_actor_agent RECORD;
  v_existing RECORD;
  v_prof RECORD;
  v_name text; v_email text; v_phone text;
  v_code text; v_new_id uuid; v_try int := 0;
BEGIN
  IF p_target_user_id IS NULL THEN RAISE EXCEPTION 'CIBLE_INTROUVABLE'; END IF;

  -- Autorité : PDG (tranché côté endpoint) OU agent de GESTION avec la permission.
  -- ⛔ Un agent cash (sans permission) ne peut JAMAIS activer → FORBIDDEN. Plus de parrainage.
  IF NOT p_actor_is_pdg THEN
    SELECT * INTO v_actor_agent FROM public.agents_management
      WHERE user_id = p_actor_user_id AND can_activate_cash_agents = true AND is_active = true;
    IF NOT FOUND THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  END IF;
  -- Traçabilité de l'activateur = cash_enabled_by (user_id, plus bas). parent_agent_id NON
  -- utilisé (trigger check_agent_hierarchy interdit type 'principal' + parent).

  -- PDG actif (coffre) pour pdg_id NOT NULL.
  SELECT id INTO v_pdg_id FROM public.pdg_management WHERE is_active = true ORDER BY created_at LIMIT 1;
  IF v_pdg_id IS NULL THEN RAISE EXCEPTION 'PDG_INTROUVABLE'; END IF;

  -- Fiche déjà existante → on (ré)active + trace, sans dupliquer. On NE touche PAS
  -- can_create_sub_agent (peut appartenir à un agent de gestion).
  SELECT * INTO v_existing FROM public.agents_management WHERE user_id = p_target_user_id FOR UPDATE;
  IF FOUND THEN
    UPDATE public.agents_management
       SET cash_agent_enabled = true,
           cash_agent_active   = true,
           cash_enabled_at = COALESCE(cash_enabled_at, now()),
           cash_enabled_by = COALESCE(cash_enabled_by, p_actor_user_id),
           updated_at = now()
     WHERE id = v_existing.id;
    RETURN jsonb_build_object('success', true, 'agent_id', v_existing.id,
      'agent_code', v_existing.agent_code, 'already_existed', true, 'name', v_existing.name,
      'user_id', p_target_user_id);
  END IF;

  -- Profil cible. Email NOT NULL UNIQUE → repli synthétique si absent.
  SELECT first_name, last_name, full_name, email, phone INTO v_prof
    FROM public.profiles WHERE id = p_target_user_id;
  v_name  := NULLIF(btrim(COALESCE(v_prof.full_name,
              btrim(COALESCE(v_prof.first_name,'') || ' ' || COALESCE(v_prof.last_name,'')))), '');
  v_name  := COALESCE(v_name, 'Agent 224');
  v_email := NULLIF(btrim(COALESCE(v_prof.email, '')), '');
  v_email := COALESCE(v_email, 'agent-' || p_target_user_id || '@224agent.gn');
  v_phone := NULLIF(btrim(COALESCE(v_prof.phone, '')), '');

  LOOP
    v_try := v_try + 1;
    v_code := 'AGT-' || to_char(now(), 'YYYY') || '-' ||
              upper(substr(md5(random()::text || clock_timestamp()::text || p_target_user_id::text), 1, 6));
    BEGIN
      INSERT INTO public.agents_management (
        agent_code, user_id, pdg_id, name, email, phone, role,
        is_active, can_create_sub_agent, type_agent, parent_agent_id,
        cash_agent_enabled, cash_agent_active, cash_enabled_at, cash_enabled_by
      ) VALUES (
        v_code, p_target_user_id, v_pdg_id, v_name,
        CASE WHEN v_try = 1 THEN v_email ELSE 'agent-' || p_target_user_id || '-' || v_try || '@224agent.gn' END,
        v_phone, 'agent',
        true, false, 'principal', NULL,   -- cash agent : ne recrute jamais ; trace activateur = cash_enabled_by
        true, true, now(), p_actor_user_id
      ) RETURNING id INTO v_new_id;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF v_try >= 5 THEN RAISE; END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'agent_id', v_new_id,
    'agent_code', v_code, 'already_existed', false, 'name', v_name, 'user_id', p_target_user_id);
END $$;
REVOKE ALL ON FUNCTION public.activate_cash_agent(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.activate_cash_agent(uuid, uuid, boolean) TO service_role;

-- ── 5) agent_cash_self_withdrawal : « Retrait moi-même » (perso → float) ─────
-- Wallet perso agent débité de (montant + frais self), float crédité du montant (il prend
-- les billets dans sa caisse). Frais (défaut 0) → circuit PDG habituel, split 30/70.
CREATE OR REPLACE FUNCTION public.agent_cash_self_withdrawal(
  p_agent_id uuid, p_amount numeric, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent uuid; v_agent RECORD; v_cfg public.agent_cash_config;
  v_wallet_id bigint; v_pdg_wallet bigint;
  v_fee numeric; v_agent_share numeric := 0; v_pdg_share numeric := 0;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  v_cfg := public.agent_cash_active_config();

  INSERT INTO public.agent_cash_operations (idempotency_key, operation, agent_id, amount)
  VALUES (p_idempotency_key, 'self_withdrawal', p_agent_id, p_amount)
  ON CONFLICT (idempotency_key) DO NOTHING RETURNING parent_tx_id INTO v_parent;
  IF v_parent IS NULL THEN
    RETURN (SELECT result FROM public.agent_cash_operations WHERE idempotency_key = p_idempotency_key);
  END IF;

  SELECT * INTO v_agent FROM public.agents_management WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_INTROUVABLE'; END IF;
  IF NOT v_agent.cash_agent_enabled OR v_agent.cash_agent_suspended THEN RAISE EXCEPTION 'AGENT_INACTIF'; END IF;

  v_fee := round(p_amount * v_cfg.self_withdrawal_fee_percent / 100.0, 2);

  -- 1) Wallet perso agent -= (montant + frais).
  SELECT id INTO v_wallet_id FROM public.wallets WHERE user_id = v_agent.user_id AND currency = 'GNF' FOR UPDATE;
  IF v_wallet_id IS NULL THEN RAISE EXCEPTION 'WALLET_AGENT_INTROUVABLE'; END IF;
  PERFORM public._acash_debit_wallet(v_wallet_id, p_amount + v_fee, 'SOLDE_PERSO_INSUFFISANT');
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount)
  VALUES (v_parent, 'self_withdrawal', 'agent_personal_debit', p_agent_id, p_amount + v_fee);

  -- 2) Float agent += montant.
  UPDATE public.agents_management SET cash_float_balance = cash_float_balance + p_amount, updated_at = now()
  WHERE id = p_agent_id;
  INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount)
  VALUES (v_parent, 'self_withdrawal', 'agent_float_credit', p_agent_id, p_amount);

  -- 3) Frais (si > 0) : PDG crédité, part agent 30% redescend (circuit habituel).
  IF v_fee > 0 THEN
    v_agent_share := round(v_fee * v_cfg.withdrawal_agent_share_of_fee / 100.0, 2);
    v_pdg_share   := v_fee - v_agent_share;
    v_pdg_wallet  := public.get_pdg_gnf_wallet_id();
    IF v_pdg_wallet IS NULL THEN RAISE EXCEPTION 'PDG_INTROUVABLE'; END IF;
    PERFORM public._acash_credit_wallet(v_pdg_wallet, v_fee);
    INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount)
    VALUES (v_parent, 'self_withdrawal', 'pdg_fee_credit', p_agent_id, v_fee);
    IF v_agent_share > 0 THEN
      PERFORM public._acash_debit_wallet(v_pdg_wallet, v_agent_share, 'PDG_INSUFFISANT');
      UPDATE public.agents_management SET cash_commission_balance = cash_commission_balance + v_agent_share, updated_at = now()
      WHERE id = p_agent_id;
      INSERT INTO public.agent_cash_ledger (parent_tx_id, operation, leg, agent_id, amount)
      VALUES (v_parent, 'self_withdrawal', 'pdg_commission_debit', p_agent_id, v_agent_share),
             (v_parent, 'self_withdrawal', 'agent_commission_credit', p_agent_id, v_agent_share);
    END IF;
  END IF;

  UPDATE public.agent_cash_operations
  SET fee = v_fee, agent_share = v_agent_share, pdg_share = v_pdg_share,
      result = jsonb_build_object('success', true, 'parent_tx_id', v_parent, 'amount', p_amount,
        'fee', v_fee, 'new_float', (SELECT cash_float_balance FROM public.agents_management WHERE id = p_agent_id))
  WHERE parent_tx_id = v_parent;
  RETURN (SELECT result FROM public.agent_cash_operations WHERE parent_tx_id = v_parent);
END $$;
REVOKE ALL ON FUNCTION public.agent_cash_self_withdrawal(uuid, numeric, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.agent_cash_self_withdrawal(uuid, numeric, text) TO service_role;

-- ── 6) Auto-test : parrainage disparu + permission présente ──────────────────
DO $$
DECLARE v_src text;
BEGIN
  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'activate_cash_agent';
  IF v_src LIKE '%SPONSORSHIP_%' OR v_src LIKE '%cash_agent_enabled = true AND cash_agent_suspended = false%' THEN
    RAISE EXCEPTION 'activate_cash_agent : branche parrainage encore présente';
  END IF;
  IF v_src NOT LIKE '%can_activate_cash_agents = true%' THEN
    RAISE EXCEPTION 'activate_cash_agent : autorité par permission absente';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'agent_cash_self_withdrawal') THEN
    RAISE EXCEPTION 'agent_cash_self_withdrawal absente';
  END IF;
  RAISE NOTICE 'OK : autorité par permission, parrainage supprimé, self-withdrawal créée.';
END $$;

SELECT 'Autorité activation (PDG + permission) + retrait moi-même. Parrainage supprimé.' AS status;
