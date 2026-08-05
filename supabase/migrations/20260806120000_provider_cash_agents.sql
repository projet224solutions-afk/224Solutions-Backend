-- ============================================================================
-- 💰 CAISSE PRESTATAIRE + 👥 AGENTS (équipe du centre) — 06/08/2026
-- Caisse comptoir : ventes (espèces/wallet référencé/agrégateur — l'argent wallet
-- bouge par le circuit existant, ici on TRACE), dépenses, reçus REC-YYYY-NNNN
-- atomiques immuables. Agents = modèle event_controllers GÉNÉRALISÉ : code+mdp
-- (pas de compte client), session à jeton 12 h, rôle agent/gérant, désactivation
-- immédiate (token annulé). TRAÇABILITÉ : performed_by_agent_id sur chaque vente/
-- dépense (NULL = le patron). Un agent n'a AUCUN accès wallet : ses écritures
-- passent par des RPC token-scopées qui ne touchent QUE la caisse ; toute route
-- d'argent (verifyJWT) refuse d'office une session agent (pas de JWT).
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── AGENTS ──
CREATE TABLE IF NOT EXISTS public.provider_agents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
  phone text CHECK (char_length(phone) <= 50),
  role text NOT NULL DEFAULT 'agent' CHECK (role IN ('agent', 'gerant')),
  login_code text NOT NULL UNIQUE,
  password_hash text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  session_token text,
  session_expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pagents_owner ON public.provider_agents (provider_user_id);
ALTER TABLE public.provider_agents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pagents_owner_all ON public.provider_agents;
CREATE POLICY pagents_owner_all ON public.provider_agents
  FOR ALL TO authenticated
  USING (provider_user_id = auth.uid()) WITH CHECK (provider_user_id = auth.uid());

-- ── CAISSE : compteur de reçus (atomique par prestataire/année) ──
CREATE TABLE IF NOT EXISTS public.provider_receipt_counters (
  provider_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  year int NOT NULL,
  counter int NOT NULL DEFAULT 0,
  PRIMARY KEY (provider_user_id, year)
);
ALTER TABLE public.provider_receipt_counters ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS prcnt_owner_all ON public.provider_receipt_counters;
CREATE POLICY prcnt_owner_all ON public.provider_receipt_counters
  FOR ALL TO authenticated
  USING (provider_user_id = auth.uid()) WITH CHECK (provider_user_id = auth.uid());

-- ── VENTES au comptoir ──
CREATE TABLE IF NOT EXISTS public.provider_cash_sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  offering_id uuid,
  label text NOT NULL CHECK (char_length(label) BETWEEN 1 AND 300),
  quantity int NOT NULL DEFAULT 1 CHECK (quantity > 0),
  amount numeric NOT NULL CHECK (amount > 0), -- montant TOTAL encaissé
  currency text NOT NULL CHECK (char_length(currency) = 3),
  discount numeric CHECK (discount IS NULL OR discount >= 0),
  method text NOT NULL CHECK (method IN ('especes', 'wallet', 'agregateur', 'autre')),
  client_name text CHECK (char_length(client_name) <= 120),
  client_phone text CHECK (char_length(client_phone) <= 50),
  receipt_number text NOT NULL,
  wallet_tx_ref text CHECK (char_length(wallet_tx_ref) <= 200), -- RÉFÉRENCE la transaction wallet (jamais dupliquée)
  performed_by_agent_id uuid REFERENCES public.provider_agents(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider_user_id, receipt_number)
);
CREATE INDEX IF NOT EXISTS idx_pcsales_owner_date ON public.provider_cash_sales (provider_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pcsales_agent ON public.provider_cash_sales (performed_by_agent_id);
ALTER TABLE public.provider_cash_sales ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pcsales_owner_all ON public.provider_cash_sales;
CREATE POLICY pcsales_owner_all ON public.provider_cash_sales
  FOR ALL TO authenticated
  USING (provider_user_id = auth.uid()) WITH CHECK (provider_user_id = auth.uid());

-- Numéro de reçu auto REC-YYYY-NNNN, IMMUABLE.
CREATE OR REPLACE FUNCTION public.assign_provider_receipt_number()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_year int := EXTRACT(YEAR FROM now())::int;
  v_next int;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.receipt_number IS DISTINCT FROM OLD.receipt_number THEN
      RAISE EXCEPTION 'RECEIPT_NUMBER_IMMUTABLE';
    END IF;
    RETURN NEW;
  END IF;
  INSERT INTO public.provider_receipt_counters AS c (provider_user_id, year, counter)
  VALUES (NEW.provider_user_id, v_year, 1)
  ON CONFLICT (provider_user_id, year) DO UPDATE SET counter = c.counter + 1
  RETURNING counter INTO v_next;
  NEW.receipt_number := 'REC-' || v_year || '-' || lpad(v_next::text, 4, '0');
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_pcsales_receipt ON public.provider_cash_sales;
CREATE TRIGGER trg_pcsales_receipt
  BEFORE INSERT OR UPDATE ON public.provider_cash_sales
  FOR EACH ROW EXECUTE FUNCTION public.assign_provider_receipt_number();

-- ── DÉPENSES ──
CREATE TABLE IF NOT EXISTS public.provider_cash_expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  label text NOT NULL CHECK (char_length(label) BETWEEN 1 AND 300),
  amount numeric NOT NULL CHECK (amount > 0),
  currency text NOT NULL CHECK (char_length(currency) = 3),
  performed_by_agent_id uuid REFERENCES public.provider_agents(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pcexp_owner_date ON public.provider_cash_expenses (provider_user_id, created_at DESC);
ALTER TABLE public.provider_cash_expenses ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pcexp_owner_all ON public.provider_cash_expenses;
CREATE POLICY pcexp_owner_all ON public.provider_cash_expenses
  FOR ALL TO authenticated
  USING (provider_user_id = auth.uid()) WITH CHECK (provider_user_id = auth.uid());

-- ════════ RPC AGENTS (modèle contrôleurs : SECURITY DEFINER, fail-closed) ════════

-- Création par le PATRON : code AGT-XXXX + mot de passe générés, retournés UNE FOIS.
CREATE OR REPLACE FUNCTION public.create_provider_agent(p_name text, p_phone text, p_role text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_owner uuid := auth.uid();
  v_code text;
  v_password text;
  v_id uuid;
BEGIN
  IF v_owner IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF p_role NOT IN ('agent', 'gerant') THEN RAISE EXCEPTION 'INVALID_ROLE'; END IF;
  v_code := 'AGT-' || upper(substr(md5(gen_random_uuid()::text), 1, 4));
  WHILE EXISTS (SELECT 1 FROM public.provider_agents WHERE login_code = v_code) LOOP
    v_code := 'AGT-' || upper(substr(md5(gen_random_uuid()::text), 1, 4));
  END LOOP;
  v_password := upper(substr(md5(gen_random_uuid()::text), 1, 8));
  INSERT INTO public.provider_agents (provider_user_id, name, phone, role, login_code, password_hash)
  VALUES (v_owner, trim(p_name), nullif(trim(coalesce(p_phone, '')), ''), p_role, v_code, crypt(v_password, gen_salt('bf')))
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'login_code', v_code, 'password', v_password);
END;
$$;
REVOKE ALL ON FUNCTION public.create_provider_agent(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_provider_agent(text, text, text) TO authenticated;

-- Connexion agent (PAS de compte client) : code + mdp → jeton 12 h. Refus GÉNÉRIQUE.
CREATE OR REPLACE FUNCTION public.verify_provider_agent_login(p_code text, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_agent public.provider_agents%ROWTYPE;
  v_token text;
  v_provider_name text;
BEGIN
  SELECT * INTO v_agent FROM public.provider_agents
  WHERE login_code = upper(trim(p_code)) AND is_active = true;
  IF NOT FOUND OR v_agent.password_hash IS DISTINCT FROM crypt(p_password, v_agent.password_hash) THEN
    RAISE EXCEPTION 'LOGIN_FAILED';
  END IF;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  UPDATE public.provider_agents
  SET session_token = v_token, session_expires_at = now() + interval '12 hours', updated_at = now()
  WHERE id = v_agent.id;
  SELECT coalesce(nullif(trim(concat(first_name, ' ', last_name)), ''), 'Centre') INTO v_provider_name
  FROM public.profiles WHERE id = v_agent.provider_user_id;
  RETURN jsonb_build_object('token', v_token, 'name', v_agent.name, 'role', v_agent.role,
    'provider_name', v_provider_name);
END;
$$;
REVOKE ALL ON FUNCTION public.verify_provider_agent_login(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_provider_agent_login(text, text) TO anon, authenticated;

-- Validation d'un jeton (désactivation = chute IMMÉDIATE : token annulé au set_active).
CREATE OR REPLACE FUNCTION public.provider_agent_from_token(p_token text)
RETURNS public.provider_agents LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_agent public.provider_agents%ROWTYPE;
BEGIN
  SELECT * INTO v_agent FROM public.provider_agents
  WHERE session_token = p_token AND is_active = true AND session_expires_at > now();
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_SESSION_INVALID'; END IF;
  RETURN v_agent;
END;
$$;
REVOKE ALL ON FUNCTION public.provider_agent_from_token(text) FROM PUBLIC, anon, authenticated;

-- Désactivation / réactivation (patron) — token ANNULÉ à la désactivation.
CREATE OR REPLACE FUNCTION public.set_provider_agent_active(p_agent_id uuid, p_active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.provider_agents
  SET is_active = p_active,
      session_token = CASE WHEN p_active THEN session_token ELSE NULL END,
      updated_at = now()
  WHERE id = p_agent_id AND provider_user_id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.set_provider_agent_active(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_provider_agent_active(uuid, boolean) TO authenticated;

-- Réinitialisation du mot de passe (patron) — retourné UNE FOIS.
CREATE OR REPLACE FUNCTION public.reset_provider_agent_password(p_agent_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_password text := upper(substr(md5(gen_random_uuid()::text), 1, 8));
BEGIN
  UPDATE public.provider_agents
  SET password_hash = crypt(v_password, gen_salt('bf')), session_token = NULL, updated_at = now()
  WHERE id = p_agent_id AND provider_user_id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  RETURN v_password;
END;
$$;
REVOKE ALL ON FUNCTION public.reset_provider_agent_password(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reset_provider_agent_password(uuid) TO authenticated;

-- ── Actions CAISSE en session AGENT (token-scopées — ne touchent QUE la caisse) ──
CREATE OR REPLACE FUNCTION public.agent_record_cash_sale(
  p_token text, p_label text, p_amount numeric, p_currency text, p_method text,
  p_quantity int DEFAULT 1, p_client_name text DEFAULT NULL, p_client_phone text DEFAULT NULL,
  p_wallet_tx_ref text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_agent public.provider_agents%ROWTYPE;
  v_id uuid; v_receipt text;
BEGIN
  v_agent := public.provider_agent_from_token(p_token);
  INSERT INTO public.provider_cash_sales
    (provider_user_id, label, quantity, amount, currency, method, client_name, client_phone,
     wallet_tx_ref, performed_by_agent_id, receipt_number)
  VALUES (v_agent.provider_user_id, trim(p_label), greatest(1, coalesce(p_quantity, 1)), p_amount,
     upper(p_currency), p_method, nullif(trim(coalesce(p_client_name, '')), ''),
     nullif(trim(coalesce(p_client_phone, '')), ''), nullif(trim(coalesce(p_wallet_tx_ref, '')), ''),
     v_agent.id, 'AUTO')
  RETURNING id, receipt_number INTO v_id, v_receipt;
  RETURN jsonb_build_object('id', v_id, 'receipt_number', v_receipt, 'agent_name', v_agent.name);
END;
$$;
REVOKE ALL ON FUNCTION public.agent_record_cash_sale(text, text, numeric, text, text, int, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.agent_record_cash_sale(text, text, numeric, text, text, int, text, text, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.agent_record_cash_expense(p_token text, p_label text, p_amount numeric, p_currency text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_agent public.provider_agents%ROWTYPE; v_id uuid;
BEGIN
  v_agent := public.provider_agent_from_token(p_token);
  INSERT INTO public.provider_cash_expenses (provider_user_id, label, amount, currency, performed_by_agent_id)
  VALUES (v_agent.provider_user_id, trim(p_label), p_amount, upper(p_currency), v_agent.id)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.agent_record_cash_expense(text, text, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.agent_record_cash_expense(text, text, numeric, text) TO anon, authenticated;

-- L'agent voit SES ventes du jour UNIQUEMENT (jamais celles des autres ni le global).
CREATE OR REPLACE FUNCTION public.agent_my_sales_today(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_agent public.provider_agents%ROWTYPE; v_out jsonb;
BEGIN
  v_agent := public.provider_agent_from_token(p_token);
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'label', s.label, 'amount', s.amount, 'currency', s.currency,
      'method', s.method, 'receipt_number', s.receipt_number, 'client_name', s.client_name,
      'created_at', s.created_at) ORDER BY s.created_at DESC), '[]'::jsonb)
  INTO v_out
  FROM public.provider_cash_sales s
  WHERE s.performed_by_agent_id = v_agent.id AND s.created_at >= date_trunc('day', now());
  RETURN jsonb_build_object('agent_name', v_agent.name, 'provider_user_id', NULL, 'sales', v_out);
END;
$$;
REVOKE ALL ON FUNCTION public.agent_my_sales_today(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.agent_my_sales_today(text) TO anon, authenticated;
