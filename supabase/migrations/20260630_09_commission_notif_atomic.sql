-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 9 — COMMISSION : notifications de réception + ledger de conservation +
--            alerte provisionnement PDG. Le moteur reste ATOMIQUE et FAIL-CLOSED.
-- ════════════════════════════════════════════════════════════════════════════
-- Reproduit credit_agent_commission (20260630_01) À L'IDENTIQUE en n'ajoutant QUE :
--   • NOTIFS (Partie 1) : sous-agent / agent principal / agent direct reçoivent
--     « Commission reçue 💰 ». NON BLOQUANTES (try/exception) : une notif ratée
--     n'annule JAMAIS la commission (elle reste dans la transaction, mais son
--     échec est avalé).
--   • LEDGER DE CONSERVATION (Partie 3) : à chaque débit PDG, on trace une ligne
--     platform_revenue (revenue_type='agent_commission_payout', montant NÉGATIF).
--     C'est un ENREGISTREMENT (audit trail) — il N'ALTÈRE PAS le wallet (déjà
--     débité directement juste avant). Permet la réconciliation « entre = sort »
--     et révèle la dette du mint passé (les vieilles commissions n'ont pas de
--     ligne payout).
--   • ALERTE PROVISIONNEMENT (Partie 4) : après le débit, si le solde PDG restant
--     passe sous le seuil (pdg_wallet_low_threshold, défaut 100000) → notif PDG.
--     Et si une commission est bloquée (SOLDE_PDG_INSUFFISANT) → notif PDG. Non
--     bloquant.
-- Aucun COMMIT intermédiaire : crédit agent + débit PDG + ledger + notifs = 1 seule
-- transaction. Le débit PDG reste = total réellement crédité (conservation).
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.credit_agent_commission(
  p_user_id uuid,
  p_amount numeric,
  p_source_type text,
  p_transaction_id uuid DEFAULT NULL::uuid,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_affiliation RECORD;
  v_agent RECORD;
  v_parent_agent RECORD;
  v_has_parent boolean := false;
  v_sub_rate numeric;
  v_principal_rate numeric;
  v_max_total_rate numeric;
  v_total_rate numeric;
  v_scale numeric;
  v_sub_applied numeric;
  v_principal_applied numeric;
  v_agent_commission numeric := 0;
  v_parent_commission numeric := 0;
  v_agent_log_id uuid;
  v_parent_log_id uuid;
  v_any_inserted boolean := false;
  v_agent_duplicate boolean := false;
  v_parent_duplicate boolean := false;
  v_currency text := COALESCE(NULLIF(p_metadata->>'currency', ''), 'GNF');
  -- ✅ ÉTAPE 1 — débit PDG
  v_pdg_user_id uuid;
  v_pdg_balance numeric;
  v_planned numeric;
  v_total_agent numeric;
  -- ✅ ÉTAPE 9 — alerte provisionnement PDG
  v_low_threshold numeric := public.pdg_setting_numeric('pdg_wallet_low_threshold', 100000);
BEGIN
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Utilisateur requis');
  END IF;
  IF COALESCE(p_amount, 0) <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Montant invalide');
  END IF;

  -- Taux GLOBAUX configurés par le PDG (pdg_settings), bornés 0-100. Défauts 15 / 5.
  v_sub_rate       := GREATEST(0, LEAST(public.pdg_setting_numeric('agent_sub_commission_percent', 15), 100));
  v_principal_rate := GREATEST(0, LEAST(public.pdg_setting_numeric('agent_principal_commission_percent', 5), 100));
  -- Plafond de sécurité : la plateforme ne verse jamais plus que la base (= les frais). Défaut 100 %.
  v_max_total_rate := GREATEST(0, LEAST(public.pdg_setting_numeric('max_total_agent_commission_percentage', 100), 100));

  SELECT * INTO v_affiliation FROM public.get_user_agent(p_user_id);
  IF v_affiliation.agent_id IS NULL THEN
    RETURN jsonb_build_object('success', true, 'has_agent', false, 'message', 'Utilisateur non affilie a un agent');
  END IF;

  SELECT * INTO v_agent FROM public.agents_management
  WHERE id = v_affiliation.agent_id AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent non trouve ou inactif');
  END IF;

  -- ✅ IDEMPOTENCE PRÉCOCE : commission déjà versée pour ce paiement+utilisateur → sortir
  -- sans rien re-débiter/re-créditer (protège contre le rejeu, même base que l'unique index).
  IF p_transaction_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.agent_commissions_log
    WHERE transaction_id = p_transaction_id AND related_user_id = p_user_id
  ) THEN
    RETURN jsonb_build_object('success', true, 'has_agent', true, 'already_processed', true);
  END IF;

  -- ✅ Wallet PDG (source du transfert). FAIL-CLOSED : si absent → on NE crédite PAS
  -- (jamais de mint). Verrou FOR UPDATE pour atomicité avec le crédit agent.
  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management
  WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  IF v_pdg_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PDG_INTROUVABLE', 'has_agent', true);
  END IF;
  SELECT balance INTO v_pdg_balance FROM public.wallets
  WHERE user_id = v_pdg_user_id AND currency = 'GNF' FOR UPDATE;
  IF v_pdg_balance IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PDG_WALLET_GNF_INTROUVABLE', 'has_agent', true);
  END IF;

  -- ========================= SOUS-AGENT =========================
  IF v_agent.type_agent = 'sous_agent' THEN
    IF v_agent.parent_agent_id IS NOT NULL THEN
      SELECT * INTO v_parent_agent FROM public.agents_management
      WHERE id = v_agent.parent_agent_id AND is_active = true;
      IF FOUND THEN v_has_parent := true; END IF;
    END IF;

    v_sub_applied := v_sub_rate;
    v_principal_applied := CASE WHEN v_has_parent THEN v_principal_rate ELSE 0 END;

    -- Plafond : réduction proportionnelle si sous% + principal% dépasse le max.
    v_total_rate := v_sub_applied + v_principal_applied;
    IF v_total_rate > v_max_total_rate AND v_total_rate > 0 THEN
      v_scale := v_max_total_rate / v_total_rate;
      v_sub_applied := ROUND(v_sub_applied * v_scale, 4);
      v_principal_applied := ROUND(v_principal_applied * v_scale, 4);
    END IF;

    -- ✅ Pré-check solde PDG (sur le total PLANIFIÉ, avant tout crédit).
    v_planned := ROUND(p_amount * (v_sub_applied / 100), 2)
                 + CASE WHEN v_has_parent THEN ROUND(p_amount * (v_principal_applied / 100), 2) ELSE 0 END;
    IF v_planned > v_pdg_balance THEN
      RAISE NOTICE 'Solde PDG insuffisant (% < %) — commission sous-agent non versee', v_pdg_balance, v_planned;
      -- ✅ ÉTAPE 9 (4.2) — prévenir le PDG que la commission est bloquée (non bloquant).
      BEGIN
        PERFORM public.create_notification(
          v_pdg_user_id, 'pdg_commission_blocked', '⛔ Commission agent bloquée',
          format('Une commission agent (%s GNF) n''a pas pu être versée : solde PDG insuffisant. Approvisionnez le wallet PDG.',
                 ROUND(v_planned, 2)),
          jsonb_build_object('needed', ROUND(v_planned, 2), 'balance', ROUND(v_pdg_balance, 2),
                             'source_type', p_source_type, 'reference', p_transaction_id));
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
      RETURN jsonb_build_object('success', false, 'error', 'SOLDE_PDG_INSUFFISANT', 'has_agent', true);
    END IF;

    -- Commission du sous-agent
    v_agent_commission := ROUND(p_amount * (v_sub_applied / 100), 2);
    IF v_agent_commission > 0 THEN
      INSERT INTO public.agent_commissions_log (
        agent_id, amount, source_type, related_user_id, transaction_id,
        description, status, commission_rate, transaction_amount, currency
      ) VALUES (
        v_agent.id, v_agent_commission, p_source_type, p_user_id, p_transaction_id,
        'Commission sous-agent ' || v_sub_applied || '% des frais sur ' || p_source_type,
        'validated', v_sub_applied, ROUND(p_amount, 2), v_currency
      )
      ON CONFLICT DO NOTHING
      RETURNING id INTO v_agent_log_id;

      IF v_agent_log_id IS NULL THEN
        v_agent_duplicate := true; v_agent_commission := 0;
      ELSE
        PERFORM public.credit_agent_wallet_gnf(v_agent.id, v_agent_commission);
        v_any_inserted := true;
        -- ✅ ÉTAPE 9 (1.1) — notifier le SOUS-AGENT (non bloquant).
        IF v_agent.user_id IS NOT NULL THEN
          BEGIN
            PERFORM public.create_notification(
              v_agent.user_id, 'commission_received', 'Commission reçue 💰',
              format('Vous avez reçu une commission de %s GNF (achat de votre filleul).', v_agent_commission),
              jsonb_build_object('amount', v_agent_commission, 'source', p_source_type,
                                 'reference', p_transaction_id, 'role', 'sous_agent'));
          EXCEPTION WHEN OTHERS THEN NULL;
          END;
        END IF;
      END IF;
    END IF;

    -- Commission du parent (agent principal)
    IF v_has_parent THEN
      v_parent_commission := ROUND(p_amount * (v_principal_applied / 100), 2);
      IF v_parent_commission > 0 THEN
        INSERT INTO public.agent_commissions_log (
          agent_id, amount, source_type, related_user_id, transaction_id,
          description, status, commission_rate, transaction_amount, currency
        ) VALUES (
          v_parent_agent.id, v_parent_commission, p_source_type, p_user_id, p_transaction_id,
          'Commission agent principal ' || v_principal_applied || '% des frais via sous-agent ' || v_agent.name,
          'validated', v_principal_applied, ROUND(p_amount, 2), v_currency
        )
        ON CONFLICT DO NOTHING
        RETURNING id INTO v_parent_log_id;

        IF v_parent_log_id IS NULL THEN
          v_parent_duplicate := true; v_parent_commission := 0;
        ELSE
          PERFORM public.credit_agent_wallet_gnf(v_parent_agent.id, v_parent_commission);
          v_any_inserted := true;
          -- ✅ ÉTAPE 9 (1.2) — notifier l'AGENT PRINCIPAL (non bloquant).
          IF v_parent_agent.user_id IS NOT NULL THEN
            BEGIN
              PERFORM public.create_notification(
                v_parent_agent.user_id, 'commission_received', 'Commission reçue 💰',
                format('Vous avez reçu %s GNF (commission sur l''activité de votre sous-agent).', v_parent_commission),
                jsonb_build_object('amount', v_parent_commission, 'source', p_source_type,
                                   'reference', p_transaction_id, 'role', 'agent_principal'));
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
          END IF;
        END IF;
      END IF;
    END IF;

    -- ✅ DÉBIT PDG du total RÉELLEMENT crédité (transfert, fin du mint). Une seule fois.
    v_total_agent := ROUND(COALESCE(v_agent_commission, 0) + COALESCE(v_parent_commission, 0), 2);
    IF v_total_agent > 0 THEN
      UPDATE public.wallets SET balance = balance - v_total_agent, updated_at = now()
      WHERE user_id = v_pdg_user_id AND currency = 'GNF';

      -- ✅ ÉTAPE 9 (3) — LEDGER de conservation (audit trail du débit PDG). Montant
      -- NÉGATIF = sortie. N'ALTÈRE PAS le wallet (déjà débité ci-dessus).
      BEGIN
        INSERT INTO public.platform_revenue (revenue_type, amount, source_transaction_id, metadata)
        VALUES ('agent_commission_payout', -v_total_agent, p_transaction_id,
                jsonb_build_object('user_id', p_user_id, 'source_type', p_source_type,
                                   'agent_id', v_agent.id, 'parent_agent_id', v_agent.parent_agent_id));
      EXCEPTION WHEN OTHERS THEN NULL;  -- le ledger ne doit jamais casser la commission
      END;

      -- ✅ ÉTAPE 9 (4.1) — alerte provisionnement : solde restant sous le seuil (non bloquant).
      IF (v_pdg_balance - v_total_agent) < v_low_threshold THEN
        BEGIN
          PERFORM public.create_notification(
            v_pdg_user_id, 'pdg_wallet_low', '⚠️ Solde PDG bas',
            format('Le wallet PDG est bas (%s GNF). Approvisionnez-le pour ne pas bloquer les commissions agents.',
                   ROUND(v_pdg_balance - v_total_agent, 2)),
            jsonb_build_object('balance', ROUND(v_pdg_balance - v_total_agent, 2), 'threshold', v_low_threshold));
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
      END IF;
    END IF;

    RETURN jsonb_build_object(
      'success', true, 'has_agent', true,
      'already_processed', (NOT v_any_inserted AND (v_agent_duplicate OR v_parent_duplicate)),
      'agent_type', 'sous_agent',
      'agent_id', v_agent.id, 'agent_name', v_agent.name,
      'agent_commission', v_agent_commission, 'agent_rate', v_sub_applied,
      'parent_agent_id', v_agent.parent_agent_id,
      'parent_commission', COALESCE(v_parent_commission, 0),
      'parent_rate', v_principal_applied,
      'parent_already_processed', v_parent_duplicate,
      'capped_total_rate', v_max_total_rate,
      'pdg_debited', v_total_agent,
      'total_commissions', v_agent_commission + COALESCE(v_parent_commission, 0)
    );
  END IF;

  -- ========================= AGENT PRINCIPAL DIRECT =========================
  -- Pas de sous-agent intermédiaire -> il touche la part TOTALE (sub + principal), plafonnée.
  v_total_rate := LEAST(v_sub_rate + v_principal_rate, v_max_total_rate);

  -- ✅ Pré-check solde PDG (sur le total planifié).
  v_planned := ROUND(p_amount * (v_total_rate / 100), 2);
  IF v_planned > v_pdg_balance THEN
    RAISE NOTICE 'Solde PDG insuffisant (% < %) — commission agent non versee', v_pdg_balance, v_planned;
    -- ✅ ÉTAPE 9 (4.2) — prévenir le PDG que la commission est bloquée (non bloquant).
    BEGIN
      PERFORM public.create_notification(
        v_pdg_user_id, 'pdg_commission_blocked', '⛔ Commission agent bloquée',
        format('Une commission agent (%s GNF) n''a pas pu être versée : solde PDG insuffisant. Approvisionnez le wallet PDG.',
               ROUND(v_planned, 2)),
        jsonb_build_object('needed', ROUND(v_planned, 2), 'balance', ROUND(v_pdg_balance, 2),
                           'source_type', p_source_type, 'reference', p_transaction_id));
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RETURN jsonb_build_object('success', false, 'error', 'SOLDE_PDG_INSUFFISANT', 'has_agent', true);
  END IF;

  v_agent_commission := ROUND(p_amount * (v_total_rate / 100), 2);

  IF v_agent_commission > 0 THEN
    INSERT INTO public.agent_commissions_log (
      agent_id, amount, source_type, related_user_id, transaction_id,
      description, status, commission_rate, transaction_amount, currency
    ) VALUES (
      v_agent.id, v_agent_commission, p_source_type, p_user_id, p_transaction_id,
      'Commission agent ' || v_total_rate || '% des frais sur ' || p_source_type,
      'validated', v_total_rate, ROUND(p_amount, 2), v_currency
    )
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_agent_log_id;

    IF v_agent_log_id IS NULL THEN
      v_agent_duplicate := true; v_agent_commission := 0;
    ELSE
      PERFORM public.credit_agent_wallet_gnf(v_agent.id, v_agent_commission);
      v_any_inserted := true;
      -- ✅ ÉTAPE 9 (1.3) — notifier l'AGENT DIRECT (non bloquant).
      IF v_agent.user_id IS NOT NULL THEN
        BEGIN
          PERFORM public.create_notification(
            v_agent.user_id, 'commission_received', 'Commission reçue 💰',
            format('Vous avez reçu une commission de %s GNF.', v_agent_commission),
            jsonb_build_object('amount', v_agent_commission, 'source', p_source_type,
                               'reference', p_transaction_id, 'role', 'agent_direct'));
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
      END IF;
    END IF;
  END IF;

  -- ✅ DÉBIT PDG du total réellement crédité.
  v_total_agent := ROUND(COALESCE(v_agent_commission, 0), 2);
  IF v_total_agent > 0 THEN
    UPDATE public.wallets SET balance = balance - v_total_agent, updated_at = now()
    WHERE user_id = v_pdg_user_id AND currency = 'GNF';

    -- ✅ ÉTAPE 9 (3) — LEDGER de conservation (audit trail du débit PDG). Négatif = sortie.
    BEGIN
      INSERT INTO public.platform_revenue (revenue_type, amount, source_transaction_id, metadata)
      VALUES ('agent_commission_payout', -v_total_agent, p_transaction_id,
              jsonb_build_object('user_id', p_user_id, 'source_type', p_source_type, 'agent_id', v_agent.id));
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- ✅ ÉTAPE 9 (4.1) — alerte provisionnement (non bloquant).
    IF (v_pdg_balance - v_total_agent) < v_low_threshold THEN
      BEGIN
        PERFORM public.create_notification(
          v_pdg_user_id, 'pdg_wallet_low', '⚠️ Solde PDG bas',
          format('Le wallet PDG est bas (%s GNF). Approvisionnez-le pour ne pas bloquer les commissions agents.',
                 ROUND(v_pdg_balance - v_total_agent, 2)),
          jsonb_build_object('balance', ROUND(v_pdg_balance - v_total_agent, 2), 'threshold', v_low_threshold));
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true, 'has_agent', true,
    'already_processed', (NOT v_any_inserted AND v_agent_duplicate),
    'agent_type', COALESCE(v_agent.type_agent, 'principal'),
    'agent_id', v_agent.id, 'agent_name', v_agent.name,
    'agent_commission', v_agent_commission, 'agent_rate', v_total_rate,
    'capped_total_rate', v_max_total_rate,
    'pdg_debited', v_total_agent,
    'total_commissions', v_agent_commission
  );
END;
$$;

REVOKE ALL ON FUNCTION public.credit_agent_commission(uuid, numeric, text, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_agent_commission(uuid, numeric, text, uuid, jsonb) TO service_role;

DO $$ BEGIN
  RAISE NOTICE '✅ credit_agent_commission : notifs réception + ledger conservation + alerte solde PDG';
END $$;

COMMIT;
