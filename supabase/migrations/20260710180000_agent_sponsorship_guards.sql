-- ============================================================================
-- 💵 AGENT CASH — Garde-fous du parrainage (décision PDG, réglables depuis l'UI)
-- ----------------------------------------------------------------------------
-- La migration 20260710170000 permet à tout agent cash actif d'activer des
-- sous-agents (parent_agent_id, type_agent='sous_agent') sans limite → chaînes de
-- parrainage illimitées possibles. On ajoute deux garde-fous, versionnés comme le
-- reste de agent_cash_config :
--   • allow_agent_sponsorship    : interrupteur global (false → SEUL le PDG active).
--   • max_sub_agents_per_sponsor : plafond de sous-agents ACTIFS par parrain.
-- Les deux gardes s'appliquent UNIQUEMENT à la branche « acteur = agent parrain » ;
-- l'activation par le PDG n'est JAMAIS limitée. Défauts (ON, 10) = comportement
-- actuel inchangé tant que le PDG ne les modifie pas.
-- ============================================================================

-- ── 1) Colonnes de config (défauts = statu quo) ─────────────────────────────
ALTER TABLE public.agent_cash_config
  ADD COLUMN IF NOT EXISTS allow_agent_sponsorship    boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS max_sub_agents_per_sponsor int     NOT NULL DEFAULT 10
    CHECK (max_sub_agents_per_sponsor >= 0);

-- ── 2) RPC de mise à jour versionnée : prendre en compte les 2 nouveaux champs ──
-- (recréée à l'identique de la version LIVE + 2 colonnes ; pattern versionné conservé)
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
    allow_agent_sponsorship, max_sub_agents_per_sponsor,
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
    COALESCE((p_changes->>'allow_agent_sponsorship')::boolean, v_cur.allow_agent_sponsorship),
    COALESCE((p_changes->>'max_sub_agents_per_sponsor')::int, v_cur.max_sub_agents_per_sponsor),
    true, auth.uid())
  RETURNING id INTO v_new_id;   -- le CHECK ck_agent_cash_share_100 bloque si parts ≠ 100
  RETURN jsonb_build_object('success', true, 'config_id', v_new_id);
END $$;

-- ── 3) activate_cash_agent : + 2 gardes dans la branche « agent parrain » ────
-- (repart de la définition LIVE ; tout le reste — idempotence, traçage, FORBIDDEN,
--  retry INSERT — est STRICTEMENT identique. Seule la branche NON-PDG est augmentée.)
CREATE OR REPLACE FUNCTION public.activate_cash_agent(
  p_target_user_id uuid,
  p_actor_user_id  uuid,
  p_actor_is_pdg   boolean
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pdg_id uuid;
  v_actor_agent RECORD;
  v_parent_agent_id uuid := NULL;   -- fiche du parrain (NULL si activation par le PDG)
  v_cfg public.agent_cash_config;   -- config active (gardes parrainage)
  v_sub_count int;                  -- sous-agents actifs déjà rattachés au parrain
  v_existing RECORD;
  v_prof RECORD;
  v_name text; v_email text; v_phone text;
  v_code text; v_new_id uuid; v_try int := 0;
BEGIN
  IF p_target_user_id IS NULL THEN RAISE EXCEPTION 'CIBLE_INTROUVABLE'; END IF;

  -- Autorité : PDG (tranché côté endpoint) OU agent cash actif (parrain).
  IF NOT p_actor_is_pdg THEN
    SELECT * INTO v_actor_agent FROM public.agents_management
      WHERE user_id = p_actor_user_id AND cash_agent_enabled = true AND cash_agent_suspended = false;
    IF NOT FOUND THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
    v_parent_agent_id := v_actor_agent.id;

    -- 🛡️ GARDE-FOUS PARRAINAGE (branche agent UNIQUEMENT ; le PDG n'est jamais limité).
    v_cfg := public.agent_cash_active_config();
    -- 1) Interrupteur global.
    IF NOT v_cfg.allow_agent_sponsorship THEN
      RAISE EXCEPTION 'SPONSORSHIP_DISABLED';
    END IF;
    -- 2) Plafond de sous-agents ACTIFS par parrain. On exclut la cible du comptage
    --    pour ne PAS bloquer la réactivation idempotente d'un sous-agent déjà compté.
    SELECT count(*) INTO v_sub_count FROM public.agents_management
      WHERE parent_agent_id = v_actor_agent.id AND cash_agent_enabled = true
        AND user_id <> p_target_user_id;
    IF v_sub_count >= v_cfg.max_sub_agents_per_sponsor THEN
      RAISE EXCEPTION 'SPONSORSHIP_LIMIT_REACHED';
    END IF;
  END IF;

  -- PDG actif (coffre) pour pdg_id NOT NULL.
  SELECT id INTO v_pdg_id FROM public.pdg_management WHERE is_active = true ORDER BY created_at LIMIT 1;
  IF v_pdg_id IS NULL THEN RAISE EXCEPTION 'PDG_INTROUVABLE'; END IF;

  -- Fiche déjà existante pour cet utilisateur → on (ré)active + trace, on ne duplique pas.
  SELECT * INTO v_existing FROM public.agents_management WHERE user_id = p_target_user_id FOR UPDATE;
  IF FOUND THEN
    UPDATE public.agents_management
       SET cash_agent_enabled = true,
           cash_agent_active   = true,          -- grant → opérations débloquées (float ensuite)
           can_create_sub_agent = true,
           cash_enabled_at = COALESCE(cash_enabled_at, now()),
           cash_enabled_by = COALESCE(cash_enabled_by, p_actor_user_id),
           parent_agent_id = COALESCE(parent_agent_id, v_parent_agent_id),
           updated_at = now()
     WHERE id = v_existing.id;
    RETURN jsonb_build_object('success', true, 'agent_id', v_existing.id,
      'agent_code', v_existing.agent_code, 'already_existed', true,
      'name', v_existing.name);
  END IF;

  -- Profil cible (nom/email/téléphone). Email NOT NULL UNIQUE → repli synthétique si absent.
  SELECT first_name, last_name, full_name, email, phone INTO v_prof
    FROM public.profiles WHERE id = p_target_user_id;
  v_name  := NULLIF(btrim(COALESCE(v_prof.full_name,
              btrim(COALESCE(v_prof.first_name,'') || ' ' || COALESCE(v_prof.last_name,'')))), '');
  v_name  := COALESCE(v_name, 'Agent 224');
  v_email := NULLIF(btrim(COALESCE(v_prof.email, '')), '');
  v_email := COALESCE(v_email, 'agent-' || p_target_user_id || '@224agent.gn');
  v_phone := NULLIF(btrim(COALESCE(v_prof.phone, '')), '');

  -- INSERT avec retry sur collision (agent_code / email).
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
        true, true,
        CASE WHEN p_actor_is_pdg THEN 'principal' ELSE 'sous_agent' END,
        v_parent_agent_id,
        true, true, now(), p_actor_user_id
      ) RETURNING id INTO v_new_id;
      EXIT; -- succès
    EXCEPTION WHEN unique_violation THEN
      IF v_try >= 5 THEN RAISE; END IF; -- abandon après 5 essais
    END;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'agent_id', v_new_id,
    'agent_code', v_code, 'already_existed', false, 'name', v_name);
END $$;
REVOKE ALL ON FUNCTION public.activate_cash_agent(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.activate_cash_agent(uuid, uuid, boolean) TO service_role;

-- ── 4) Auto-test : surcharge unique + les 2 gardes présents ──────────────────
DO $$
DECLARE v_cnt int; v_src text;
BEGIN
  SELECT count(*) INTO v_cnt FROM pg_proc WHERE proname = 'activate_cash_agent';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'activate_cash_agent : % surcharges (attendu 1)', v_cnt; END IF;
  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'activate_cash_agent';
  IF v_src NOT LIKE '%SPONSORSHIP_DISABLED%' OR v_src NOT LIKE '%SPONSORSHIP_LIMIT_REACHED%' THEN
    RAISE EXCEPTION 'activate_cash_agent : gardes parrainage absents';
  END IF;
  RAISE NOTICE 'OK : activate_cash_agent unique + gardes parrainage présents.';
END $$;

SELECT 'Garde-fous parrainage : allow_agent_sponsorship + max_sub_agents_per_sponsor (réglables PDG).' AS status;
