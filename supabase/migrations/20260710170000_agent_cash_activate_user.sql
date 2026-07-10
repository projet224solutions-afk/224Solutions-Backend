-- ============================================================================
-- 💵 AGENT CASH — Activation d'un utilisateur QUELCONQUE en agent cash
-- ----------------------------------------------------------------------------
-- Besoin (validé PDG) : n'importe quel utilisateur (client, vendeur, prestataire…)
-- peut être ACTIVÉ comme agent cash. Une fois activé il garde son rôle d'origine
-- (capacité indépendante du rôle) et peut faire dépôts/retraits + toucher des
-- commissions. Peuvent activer : le PDG, OU un agent cash déjà actif (parrainage).
--
-- CHOIX D'IMPLÉMENTATION (sûrs, minimalistes) :
--  • On NE recrée PAS les RPC d'argent (dépôt/retrait) déjà en prod. Le grand gate
--    opérationnel reste `cash_agent_active`. L'activation pose `cash_agent_active=true`
--    (grant) → opérations débloquées ; la seule barrière restante = le float
--    (min_float_for_operations), inhérente au modèle float classique.
--  • `cash_agent_enabled` (nouveau) = trace d'audit « accordé par PDG/agent » (distinct
--    du simple fait d'avoir atteint le seuil de float historiquement).
--  • Parrainage tracé via `parent_agent_id` (colonne existante). AUCUN partage d'argent
--    avec le parrain : l'agent activé touche SES propres commissions (modèle inchangé).
--  • `role='agent'` est posé sur la FICHE agents_management uniquement — le rôle du
--    profil (profiles.role) n'est JAMAIS modifié (un vendeur reste vendeur).
-- ============================================================================

-- ── 1) Colonnes d'audit d'activation ────────────────────────────────────────
ALTER TABLE public.agents_management
  ADD COLUMN IF NOT EXISTS cash_agent_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS cash_enabled_at    timestamptz,
  ADD COLUMN IF NOT EXISTS cash_enabled_by    uuid;

-- Backfill : ne pas casser les agents déjà opérationnels (float atteint ou solde présent).
UPDATE public.agents_management
   SET cash_agent_enabled = true
 WHERE cash_agent_enabled = false
   AND (cash_agent_active = true OR cash_float_balance > 0);

-- ── 2) agent_activate_cash : ne JAMAIS rétrograder un agent déjà actif ───────
-- (un top-up de float sous le seuil ne doit pas désactiver un agent activé par grant)
CREATE OR REPLACE FUNCTION public.agent_activate_cash(
  p_agent_id uuid, p_topup_amount numeric, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_parent uuid; v_agent RECORD; v_wallet_id bigint; v_cfg public.agent_cash_config;
BEGIN
  IF p_topup_amount IS NULL OR p_topup_amount <= 0 THEN RAISE EXCEPTION 'MONTANT_INVALIDE'; END IF;
  v_cfg := public.agent_cash_active_config();

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

  PERFORM public._acash_debit_wallet(v_wallet_id, p_topup_amount, 'SOLDE_PERSO_INSUFFISANT');
  UPDATE public.agents_management
  SET cash_float_balance = cash_float_balance + p_topup_amount,
      -- ✓ ne downgrade jamais : reste actif si déjà actif OU si le seuil est atteint
      cash_agent_active = (cash_agent_active OR (cash_float_balance + p_topup_amount) >= v_cfg.activation_float_threshold),
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

-- ── 3) activate_cash_agent : promeut un utilisateur quelconque en agent cash ──
-- Autorité vérifiée DANS la fonction : p_actor_is_pdg (fait foi côté endpoint, PDG),
-- OU l'acteur est un agent cash activé & non suspendu (parrainage). Idempotent.
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

SELECT 'activate_cash_agent + cash_agent_enabled : agent cash activable pour tout utilisateur.' AS status;
