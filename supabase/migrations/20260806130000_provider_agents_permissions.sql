-- ============================================================================
-- 👥 AGENTS PRESTATAIRE v2 — alignement modèle vendeur (06/08/2026) :
-- identité complète (nom/email/téléphone/mot de passe DÉFINI PAR LE PATRON) +
-- PERMISSIONS granulaires (tableau) + JOURNAL D'ACTIVITÉ append-only visible
-- par le PATRON SEUL. Migration des agents existants (rôles → permissions).
-- Finances/retraits : permission DÉCLARÉE (décochée par défaut) mais AUCUNE
-- route d'argent n'accepte une session agent (refus serveur TOTAL — le
-- branchement d'un retrait agent serait un chemin d'argent nouveau : non fait
-- sans validation explicite).
-- ============================================================================

ALTER TABLE public.provider_agents
  ADD COLUMN IF NOT EXISTS email text CHECK (char_length(email) <= 200),
  ADD COLUMN IF NOT EXISTS permissions text[] NOT NULL DEFAULT '{}';

-- Conversion des rôles existants → permissions équivalentes (agents conservés).
UPDATE public.provider_agents SET permissions = CASE role
  WHEN 'gerant' THEN ARRAY['caisse','studio','scans','commandes','prestations','billetterie','marketplace','messages','stats']
  ELSE ARRAY['caisse','studio','scans','commandes'] END
WHERE permissions = '{}';

-- ── JOURNAL D'ACTIVITÉ (append-only ABSOLU, lecture PATRON SEUL) ──
CREATE TABLE IF NOT EXISTS public.provider_agent_activity_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  agent_id uuid REFERENCES public.provider_agents(id) ON DELETE SET NULL,
  agent_name text,
  action text NOT NULL CHECK (char_length(action) <= 60),
  detail jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_paal_owner_date ON public.provider_agent_activity_log (provider_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_paal_agent ON public.provider_agent_activity_log (agent_id, created_at DESC);
ALTER TABLE public.provider_agent_activity_log ENABLE ROW LEVEL SECURITY;
-- LECTURE : le patron uniquement (aucun accès agent — pas de JWT de toute façon).
DROP POLICY IF EXISTS paal_owner_select ON public.provider_agent_activity_log;
CREATE POLICY paal_owner_select ON public.provider_agent_activity_log
  FOR SELECT TO authenticated USING (provider_user_id = auth.uid());
-- ÉCRITURE : par les fonctions SECURITY DEFINER seulement (aucune policy INSERT).
-- APPEND-ONLY absolu : ni UPDATE ni DELETE, pour PERSONNE (trigger).
CREATE OR REPLACE FUNCTION public.protect_agent_activity_log()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'ACTIVITY_LOG_APPEND_ONLY';
END;
$$;
DROP TRIGGER IF EXISTS trg_paal_protect ON public.provider_agent_activity_log;
CREATE TRIGGER trg_paal_protect
  BEFORE UPDATE OR DELETE ON public.provider_agent_activity_log
  FOR EACH ROW EXECUTE FUNCTION public.protect_agent_activity_log();

-- Journalisation interne (appelée par les RPC agent + création/gestion).
CREATE OR REPLACE FUNCTION public.log_agent_activity(p_owner uuid, p_agent_id uuid, p_agent_name text, p_action text, p_detail jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.provider_agent_activity_log (provider_user_id, agent_id, agent_name, action, detail)
  VALUES (p_owner, p_agent_id, p_agent_name, p_action, p_detail);
END;
$$;
REVOKE ALL ON FUNCTION public.log_agent_activity(uuid, uuid, text, text, jsonb) FROM PUBLIC, anon, authenticated;

-- ── CRÉATION v2 : identité complète + mot de passe DU PATRON + permissions ──
DROP FUNCTION IF EXISTS public.create_provider_agent(text, text, text);
CREATE OR REPLACE FUNCTION public.create_provider_agent(
  p_name text, p_phone text, p_email text, p_password text, p_permissions text[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_owner uuid := auth.uid();
  v_code text;
  v_id uuid;
BEGIN
  IF v_owner IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF char_length(coalesce(p_password, '')) < 8 THEN RAISE EXCEPTION 'PASSWORD_TOO_SHORT'; END IF;
  IF p_name IS NULL OR trim(p_name) = '' THEN RAISE EXCEPTION 'NAME_REQUIRED'; END IF;
  v_code := 'AGT-' || upper(substr(md5(gen_random_uuid()::text), 1, 4));
  WHILE EXISTS (SELECT 1 FROM public.provider_agents WHERE login_code = v_code) LOOP
    v_code := 'AGT-' || upper(substr(md5(gen_random_uuid()::text), 1, 4));
  END LOOP;
  INSERT INTO public.provider_agents (provider_user_id, name, phone, email, role, login_code, password_hash, permissions)
  VALUES (v_owner, trim(p_name), nullif(trim(coalesce(p_phone, '')), ''), nullif(trim(coalesce(p_email, '')), ''),
          'agent', v_code, crypt(p_password, gen_salt('bf')), coalesce(p_permissions, '{}'))
  RETURNING id INTO v_id;
  PERFORM public.log_agent_activity(v_owner, v_id, trim(p_name), 'agent_cree', jsonb_build_object('permissions', p_permissions));
  RETURN jsonb_build_object('id', v_id, 'login_code', v_code);
END;
$$;
REVOKE ALL ON FUNCTION public.create_provider_agent(text, text, text, text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_provider_agent(text, text, text, text, text[]) TO authenticated;

-- ── ÉDITION (identité + permissions — effet immédiat : lues à CHAQUE action) ──
CREATE OR REPLACE FUNCTION public.update_provider_agent(
  p_agent_id uuid, p_name text, p_phone text, p_email text, p_permissions text[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.provider_agents
  SET name = coalesce(nullif(trim(p_name), ''), name),
      phone = nullif(trim(coalesce(p_phone, '')), ''),
      email = nullif(trim(coalesce(p_email, '')), ''),
      permissions = coalesce(p_permissions, permissions),
      updated_at = now()
  WHERE id = p_agent_id AND provider_user_id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  PERFORM public.log_agent_activity(auth.uid(), p_agent_id, NULL, 'agent_modifie', jsonb_build_object('permissions', p_permissions));
END;
$$;
REVOKE ALL ON FUNCTION public.update_provider_agent(uuid, text, text, text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_provider_agent(uuid, text, text, text, text[]) TO authenticated;

-- ── CONNEXION v2 : code AGT- OU téléphone OU email + mot de passe ──
CREATE OR REPLACE FUNCTION public.verify_provider_agent_login(p_code text, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_agent public.provider_agents%ROWTYPE;
  v_token text;
  v_provider_name text;
  v_ident text := trim(p_code);
BEGIN
  SELECT * INTO v_agent FROM public.provider_agents
  WHERE is_active = true
    AND (login_code = upper(v_ident) OR phone = v_ident OR lower(email) = lower(v_ident))
  LIMIT 1;
  IF NOT FOUND OR v_agent.password_hash IS DISTINCT FROM crypt(p_password, v_agent.password_hash) THEN
    RAISE EXCEPTION 'LOGIN_FAILED';
  END IF;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  UPDATE public.provider_agents
  SET session_token = v_token, session_expires_at = now() + interval '12 hours', updated_at = now()
  WHERE id = v_agent.id;
  SELECT coalesce(nullif(trim(concat(first_name, ' ', last_name)), ''), 'Centre') INTO v_provider_name
  FROM public.profiles WHERE id = v_agent.provider_user_id;
  PERFORM public.log_agent_activity(v_agent.provider_user_id, v_agent.id, v_agent.name, 'connexion', NULL);
  RETURN jsonb_build_object('token', v_token, 'name', v_agent.name, 'role', v_agent.role,
    'permissions', to_jsonb(v_agent.permissions), 'provider_name', v_provider_name);
END;
$$;
REVOKE ALL ON FUNCTION public.verify_provider_agent_login(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_provider_agent_login(text, text) TO anon, authenticated;

-- ── Contrôle de permission SERVEUR à CHAQUE action (pas seulement l'UI) ──
CREATE OR REPLACE FUNCTION public.agent_require_permission(p_token text, p_permission text)
RETURNS public.provider_agents LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_agent public.provider_agents%ROWTYPE;
BEGIN
  v_agent := public.provider_agent_from_token(p_token);
  IF NOT (p_permission = ANY (v_agent.permissions)) THEN
    RAISE EXCEPTION 'PERMISSION_DENIED';
  END IF;
  RETURN v_agent;
END;
$$;
REVOKE ALL ON FUNCTION public.agent_require_permission(text, text) FROM PUBLIC, anon, authenticated;

-- Vente en session agent : permission 'caisse' VÉRIFIÉE SERVEUR + journalisée.
CREATE OR REPLACE FUNCTION public.agent_record_cash_sale(
  p_token text, p_label text, p_amount numeric, p_currency text, p_method text,
  p_quantity int DEFAULT 1, p_client_name text DEFAULT NULL, p_client_phone text DEFAULT NULL,
  p_wallet_tx_ref text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_agent public.provider_agents%ROWTYPE;
  v_id uuid; v_receipt text;
BEGIN
  v_agent := public.agent_require_permission(p_token, 'caisse');
  INSERT INTO public.provider_cash_sales
    (provider_user_id, label, quantity, amount, currency, method, client_name, client_phone,
     wallet_tx_ref, performed_by_agent_id, receipt_number)
  VALUES (v_agent.provider_user_id, trim(p_label), greatest(1, coalesce(p_quantity, 1)), p_amount,
     upper(p_currency), p_method, nullif(trim(coalesce(p_client_name, '')), ''),
     nullif(trim(coalesce(p_client_phone, '')), ''), nullif(trim(coalesce(p_wallet_tx_ref, '')), ''),
     v_agent.id, 'AUTO')
  RETURNING id, receipt_number INTO v_id, v_receipt;
  PERFORM public.log_agent_activity(v_agent.provider_user_id, v_agent.id, v_agent.name, 'vente_encaissee',
    jsonb_build_object('receipt', v_receipt, 'label', trim(p_label), 'amount', p_amount, 'currency', upper(p_currency), 'method', p_method));
  RETURN jsonb_build_object('id', v_id, 'receipt_number', v_receipt, 'agent_name', v_agent.name);
END;
$$;

CREATE OR REPLACE FUNCTION public.agent_record_cash_expense(p_token text, p_label text, p_amount numeric, p_currency text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_agent public.provider_agents%ROWTYPE; v_id uuid;
BEGIN
  v_agent := public.agent_require_permission(p_token, 'caisse');
  INSERT INTO public.provider_cash_expenses (provider_user_id, label, amount, currency, performed_by_agent_id)
  VALUES (v_agent.provider_user_id, trim(p_label), p_amount, upper(p_currency), v_agent.id)
  RETURNING id INTO v_id;
  PERFORM public.log_agent_activity(v_agent.provider_user_id, v_agent.id, v_agent.name, 'depense_enregistree',
    jsonb_build_object('label', trim(p_label), 'amount', p_amount, 'currency', upper(p_currency)));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.agent_my_sales_today(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_agent public.provider_agents%ROWTYPE; v_out jsonb;
BEGIN
  v_agent := public.agent_require_permission(p_token, 'caisse');
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'label', s.label, 'amount', s.amount, 'currency', s.currency,
      'method', s.method, 'receipt_number', s.receipt_number, 'client_name', s.client_name,
      'created_at', s.created_at) ORDER BY s.created_at DESC), '[]'::jsonb)
  INTO v_out
  FROM public.provider_cash_sales s
  WHERE s.performed_by_agent_id = v_agent.id AND s.created_at >= date_trunc('day', now());
  RETURN jsonb_build_object('agent_name', v_agent.name, 'permissions', to_jsonb(v_agent.permissions), 'sales', v_out);
END;
$$;

-- Notification TEMPS RÉEL au patron sur les actions sensibles de ses agents
-- (en plus du journal append-only — règle Thierno).
CREATE OR REPLACE FUNCTION public.log_agent_activity(p_owner uuid, p_agent_id uuid, p_agent_name text, p_action text, p_detail jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.provider_agent_activity_log (provider_user_id, agent_id, agent_name, action, detail)
  VALUES (p_owner, p_agent_id, p_agent_name, p_action, p_detail);
  IF p_action IN ('vente_encaissee', 'depense_enregistree', 'prix_modifie', 'retrait', 'transfert') THEN
    INSERT INTO public.notifications (user_id, title, message, type, category, metadata)
    VALUES (p_owner,
      'Activité agent : ' || coalesce(p_agent_name, 'agent'),
      coalesce(p_agent_name, 'Un agent') || ' — ' || p_action ||
        coalesce(' · ' || (p_detail->>'amount') || ' ' || (p_detail->>'currency'), ''),
      'info', 'team', p_detail);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.log_agent_activity(uuid, uuid, text, text, jsonb) FROM PUBLIC, anon, authenticated;
