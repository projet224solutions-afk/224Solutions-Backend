-- ============================================================================
-- Commission agent : TAUX GLOBAUX (PDG) + base = FRAIS + plafond (fix A, v2)
-- ----------------------------------------------------------------------------
-- Modèle métier (validé PDG) :
--   • La commission agent est un % des FRAIS DE TRANSACTION (commission acheteur),
--     PAS du montant brut. La base (p_amount) reçue ICI = déjà les frais.
--   • Les taux sont GLOBAUX (un seul réglage PDG pour tous les agents) :
--       - agent_sub_commission_percent        (défaut 15) → part du SOUS-AGENT
--       - agent_principal_commission_percent  (défaut  5) → part de l'AGENT PRINCIPAL
--     Total agents = somme des deux (ex. 20 % des frais). La plateforme garde le reste.
--   • Sous-agent dont l'utilisateur transige : sous-agent prend sa part (15 %),
--     son parent prend la part principal (5 %). Total plafonné (sécurité).
--   • Agent principal DIRECT (utilisateur sans sous-agent) : touche la part TOTALE
--     (sub + principal), car il n'y a personne avec qui partager.
--
-- Reste IDENTIQUE : anti-doublon ON CONFLICT, logs agent_commissions_log, crédit
-- via credit_agent_wallet_gnf, format de retour jsonb. Non destructif, rejouable.
-- ============================================================================

-- Helper : lit un réglage numérique de pdg_settings en gérant les DEUX formats de
-- setting_value (objet jsonb {"value": X} comme la plupart des réglages, OU scalaire jsonb).
-- Renvoie p_default si absent/illisible.
CREATE OR REPLACE FUNCTION public.pdg_setting_numeric(p_key text, p_default numeric)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT COALESCE(
    (SELECT (CASE
               WHEN jsonb_typeof(setting_value) = 'object' THEN NULLIF(setting_value->>'value', '')
               ELSE NULLIF(setting_value #>> '{}', '')
             END)::numeric
     FROM public.pdg_settings
     WHERE setting_key = p_key
     LIMIT 1),
    p_default);
$$;
GRANT EXECUTE ON FUNCTION public.pdg_setting_numeric(text, numeric) TO authenticated, service_role;

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
        END IF;
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
      'total_commissions', v_agent_commission + COALESCE(v_parent_commission, 0)
    );
  END IF;

  -- ========================= AGENT PRINCIPAL DIRECT =========================
  -- Pas de sous-agent intermédiaire -> il touche la part TOTALE (sub + principal), plafonnée.
  v_total_rate := LEAST(v_sub_rate + v_principal_rate, v_max_total_rate);
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
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true, 'has_agent', true,
    'already_processed', (NOT v_any_inserted AND v_agent_duplicate),
    'agent_type', COALESCE(v_agent.type_agent, 'principal'),
    'agent_id', v_agent.id, 'agent_name', v_agent.name,
    'agent_commission', v_agent_commission, 'agent_rate', v_total_rate,
    'capped_total_rate', v_max_total_rate,
    'total_commissions', v_agent_commission
  );
END;
$$;

REVOKE ALL ON FUNCTION public.credit_agent_commission(uuid, numeric, text, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.credit_agent_commission(uuid, numeric, text, uuid, jsonb) TO service_role;

-- Réglages globaux (le PDG les gère depuis l'interface). Défauts 15 / 5 / 100.
DO $seed$
BEGIN
  -- Format {"value": X} comme tous les autres réglages pdg_settings.
  INSERT INTO public.pdg_settings (setting_key, setting_value) VALUES
    ('agent_sub_commission_percent', jsonb_build_object('value', 15)),
    ('agent_principal_commission_percent', jsonb_build_object('value', 5)),
    ('max_total_agent_commission_percentage', jsonb_build_object('value', 100))
  ON CONFLICT (setting_key) DO NOTHING;

  -- Répare un éventuel format scalaire (pollué par une version antérieure) -> {value: X}.
  UPDATE public.pdg_settings
    SET setting_value = jsonb_build_object('value', (setting_value #>> '{}')::numeric)
    WHERE setting_key = 'max_total_agent_commission_percentage'
      AND jsonb_typeof(setting_value) <> 'object';
EXCEPTION WHEN OTHERS THEN
  NULL; -- structure pdg_settings différente : la fonction utilise déjà les défauts.
END
$seed$;
