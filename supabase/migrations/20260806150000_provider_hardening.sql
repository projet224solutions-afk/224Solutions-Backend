-- ═══════════════════════════════════════════════════════════════════════════
-- BLINDAGE GLOBAL PRESTATAIRE — invariants d'argent, agents, entrées.
-- ① Caisse : wallet_tx_ref UNIQUE (une tx wallet = UNE vente), clé d'idempotence
--    (anti-double-encaissement), plafonds de montants (CHECK), remises bornées.
-- ② Agents : rate-limit login (anti force brute, délais croissants, message
--    générique), QR de pointage à secret FORT (64 bits), anti-spam pointage
--    (TOO_FAST < 15 s). Reset mdp → token annulé (déjà en place — reprouvé).
-- ③ Entrées : longueurs bornées manquantes (correction_note, qr_secret).
-- Chiffrage devis : le front passe par edit_service_quote (RPC existante —
-- ownership + recalcul serveur + refus payé) : AUCUN doublon de fonction créé.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── ① CAISSE ────────────────────────────────────────────────────────────────

-- Une transaction wallet ne peut être référencée que par UNE vente (contrainte, pas convention).
CREATE UNIQUE INDEX IF NOT EXISTS uq_pcsales_wallet_tx_ref
  ON public.provider_cash_sales (wallet_tx_ref) WHERE wallet_tx_ref IS NOT NULL;

-- Clé d'idempotence : un uuid généré par SAISIE de formulaire — rejouer la même
-- vente (double-tap, retry réseau) = UNE seule écriture.
ALTER TABLE public.provider_cash_sales ADD COLUMN IF NOT EXISTS client_key uuid;
CREATE UNIQUE INDEX IF NOT EXISTS uq_pcsales_client_key
  ON public.provider_cash_sales (provider_user_id, client_key) WHERE client_key IS NOT NULL;

-- Plafonds serveur (une vente comptoir > 100 M GNF = erreur de saisie, pas une vente).
ALTER TABLE public.provider_cash_sales DROP CONSTRAINT IF EXISTS pcsales_amount_cap;
ALTER TABLE public.provider_cash_sales ADD CONSTRAINT pcsales_amount_cap
  CHECK (amount <= 100000000);
ALTER TABLE public.provider_cash_sales DROP CONSTRAINT IF EXISTS pcsales_discount_cap;
ALTER TABLE public.provider_cash_sales ADD CONSTRAINT pcsales_discount_cap
  CHECK (discount IS NULL OR discount <= 100000000);
ALTER TABLE public.provider_cash_expenses DROP CONSTRAINT IF EXISTS pcexp_amount_cap;
ALTER TABLE public.provider_cash_expenses ADD CONSTRAINT pcexp_amount_cap
  CHECK (amount <= 100000000);

-- agent_record_cash_sale : + p_client_key (idempotence) + bornes de montant explicites.
DROP FUNCTION IF EXISTS public.agent_record_cash_sale(text, text, numeric, text, text, int, text, text, text);
CREATE OR REPLACE FUNCTION public.agent_record_cash_sale(
  p_token text, p_label text, p_amount numeric, p_currency text, p_method text,
  p_quantity int DEFAULT 1, p_client_name text DEFAULT NULL, p_client_phone text DEFAULT NULL,
  p_wallet_tx_ref text DEFAULT NULL, p_client_key uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_agent public.provider_agents%ROWTYPE;
  v_id uuid; v_receipt text;
BEGIN
  v_agent := public.agent_require_permission(p_token, 'caisse');
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount > 100000000 THEN
    RAISE EXCEPTION 'AMOUNT_INVALID';
  END IF;
  -- IDEMPOTENCE : la même clé = la même vente, sans double écriture.
  IF p_client_key IS NOT NULL THEN
    SELECT id, receipt_number INTO v_id, v_receipt FROM public.provider_cash_sales
    WHERE provider_user_id = v_agent.provider_user_id AND client_key = p_client_key;
    IF FOUND THEN
      RETURN jsonb_build_object('id', v_id, 'receipt_number', v_receipt, 'agent_name', v_agent.name, 'idempotent', true);
    END IF;
  END IF;
  INSERT INTO public.provider_cash_sales
    (provider_user_id, label, quantity, amount, currency, method, client_name, client_phone,
     wallet_tx_ref, performed_by_agent_id, receipt_number, client_key)
  VALUES (v_agent.provider_user_id, trim(p_label), greatest(1, coalesce(p_quantity, 1)), p_amount,
     upper(p_currency), p_method, nullif(trim(coalesce(p_client_name, '')), ''),
     nullif(trim(coalesce(p_client_phone, '')), ''), nullif(trim(coalesce(p_wallet_tx_ref, '')), ''),
     v_agent.id, 'AUTO', p_client_key)
  RETURNING id, receipt_number INTO v_id, v_receipt;
  PERFORM public.log_agent_activity(v_agent.provider_user_id, v_agent.id, v_agent.name, 'vente_encaissee',
    jsonb_build_object('receipt', v_receipt, 'label', trim(p_label), 'amount', p_amount, 'currency', upper(p_currency), 'method', p_method));
  RETURN jsonb_build_object('id', v_id, 'receipt_number', v_receipt, 'agent_name', v_agent.name);
END;
$$;
REVOKE ALL ON FUNCTION public.agent_record_cash_sale(text, text, numeric, text, text, int, text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.agent_record_cash_sale(text, text, numeric, text, text, int, text, text, text, uuid) TO anon, authenticated;

-- ── ② AGENTS — anti force brute au login ────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.provider_agent_login_attempts (
  identifier text PRIMARY KEY,
  fails int NOT NULL DEFAULT 0,
  locked_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.provider_agent_login_attempts ENABLE ROW LEVEL SECURITY;
-- AUCUNE policy : la table n'est lisible/modifiable QUE par les fonctions SECURITY DEFINER.

CREATE OR REPLACE FUNCTION public.verify_provider_agent_login(p_code text, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_agent public.provider_agents%ROWTYPE;
  v_token text;
  v_provider_name text;
  v_ident text := trim(p_code);
  v_key text := lower(trim(p_code));
  v_locked timestamptz;
BEGIN
  -- THROTTLE : 5 échecs → verrou à délais croissants (2 min × échecs au-delà de 4, plafonné 20 min).
  -- ⚠️ Les échecs sont RETOURNÉS (pas levés) : une exception annulerait l'écriture du compteur
  -- d'échecs dans la même transaction (bug trouvé au test d'intrusion — le throttle ne persistait pas).
  SELECT locked_until INTO v_locked FROM public.provider_agent_login_attempts WHERE identifier = v_key;
  IF v_locked IS NOT NULL AND v_locked > now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'LOGIN_THROTTLED');
  END IF;

  SELECT * INTO v_agent FROM public.provider_agents
  WHERE is_active = true
    AND (login_code = upper(v_ident) OR phone = v_ident OR lower(email) = lower(v_ident))
  LIMIT 1;
  -- Message GÉNÉRIQUE dans les deux cas : ne révèle jamais si l'identifiant existe.
  IF NOT FOUND OR v_agent.password_hash IS DISTINCT FROM crypt(p_password, v_agent.password_hash) THEN
    INSERT INTO public.provider_agent_login_attempts AS a (identifier, fails, locked_until, updated_at)
    VALUES (v_key, 1, NULL, now())
    ON CONFLICT (identifier) DO UPDATE SET
      fails = a.fails + 1,
      locked_until = CASE WHEN a.fails + 1 >= 5
        THEN now() + least(a.fails + 1 - 4, 10) * interval '2 minutes' ELSE NULL END,
      updated_at = now();
    RETURN jsonb_build_object('success', false, 'error', 'LOGIN_FAILED');
  END IF;

  DELETE FROM public.provider_agent_login_attempts WHERE identifier = v_key;
  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  UPDATE public.provider_agents
  SET session_token = v_token, session_expires_at = now() + interval '12 hours', updated_at = now()
  WHERE id = v_agent.id;
  SELECT coalesce(nullif(trim(concat(first_name, ' ', last_name)), ''), 'Centre') INTO v_provider_name
  FROM public.profiles WHERE id = v_agent.provider_user_id;
  PERFORM public.log_agent_activity(v_agent.provider_user_id, v_agent.id, v_agent.name, 'connexion', NULL);
  RETURN jsonb_build_object('success', true, 'token', v_token, 'name', v_agent.name, 'role', v_agent.role,
    'permissions', to_jsonb(v_agent.permissions), 'provider_name', v_provider_name);
END;
$$;

-- ── ② QR de pointage : secret FORT (64 bits aléatoires, 16 hex) ─────────────
CREATE OR REPLACE FUNCTION public.regenerate_center_qr()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_secret text := upper(encode(gen_random_bytes(8), 'hex'));
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  INSERT INTO public.provider_time_settings (provider_user_id, qr_secret, updated_at)
  VALUES (auth.uid(), v_secret, now())
  ON CONFLICT (provider_user_id) DO UPDATE SET qr_secret = v_secret, updated_at = now();
  RETURN v_secret;
END;
$$;

-- ── ② Pointage : anti-spam (2 pointages < 15 s = double-tap, pas un humain) ─
CREATE OR REPLACE FUNCTION public.agent_clock(p_token text, p_type text, p_qr_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_agent public.provider_agents%ROWTYPE;
  v_settings public.provider_time_settings%ROWTYPE;
  v_last text;
  v_last_at timestamptz;
  v_id uuid;
  v_at timestamptz;
BEGIN
  v_agent := public.provider_agent_from_token(p_token); -- session valide = SOI-MÊME uniquement
  IF p_type NOT IN ('arrivee', 'depart', 'pause_debut', 'pause_fin') THEN
    RAISE EXCEPTION 'INVALID_TYPE';
  END IF;
  SELECT * INTO v_settings FROM public.provider_time_settings WHERE provider_user_id = v_agent.provider_user_id;
  -- Preuve de présence : le QR du CENTRE est exigé → scanner (ou saisir) le code.
  IF coalesce(v_settings.require_qr, false) THEN
    IF v_settings.qr_secret IS NULL OR upper(trim(coalesce(p_qr_code, ''))) <> v_settings.qr_secret THEN
      RAISE EXCEPTION 'QR_REQUIRED';
    END IF;
  END IF;
  -- Anti-double : transitions valides depuis le DERNIER pointage du jour (heure serveur).
  SELECT entry_type, at INTO v_last, v_last_at FROM public.provider_time_entries
  WHERE agent_id = v_agent.id AND invalidated = false AND at >= date_trunc('day', now())
  ORDER BY at DESC LIMIT 1;
  -- ANTI-SPAM : un humain ne pointe pas 2 fois en 15 secondes.
  IF v_last_at IS NOT NULL AND v_last_at > now() - interval '15 seconds' THEN
    RAISE EXCEPTION 'TOO_FAST';
  END IF;
  IF p_type = 'arrivee' AND v_last IN ('arrivee', 'pause_debut', 'pause_fin') THEN RAISE EXCEPTION 'ALREADY_IN'; END IF;
  IF p_type = 'depart' AND (v_last IS NULL OR v_last = 'depart') THEN RAISE EXCEPTION 'NOT_IN'; END IF;
  IF p_type = 'pause_debut' AND (NOT coalesce(v_settings.breaks_enabled, false) OR v_last NOT IN ('arrivee', 'pause_fin')) THEN RAISE EXCEPTION 'INVALID_TRANSITION'; END IF;
  IF p_type = 'pause_fin' AND v_last <> 'pause_debut' THEN RAISE EXCEPTION 'INVALID_TRANSITION'; END IF;

  INSERT INTO public.provider_time_entries (provider_user_id, agent_id, entry_type, method)
  VALUES (v_agent.provider_user_id, v_agent.id, p_type,
          CASE WHEN coalesce(v_settings.require_qr, false) THEN 'qr' ELSE 'simple' END)
  RETURNING id, at INTO v_id, v_at;
  PERFORM public.log_agent_activity(v_agent.provider_user_id, v_agent.id, v_agent.name,
    'pointage_' || p_type, jsonb_build_object('at', v_at));
  RETURN jsonb_build_object('id', v_id, 'at', v_at, 'type', p_type);
END;
$$;

-- ── ③ ENTRÉES — longueurs bornées manquantes ────────────────────────────────
ALTER TABLE public.provider_time_entries DROP CONSTRAINT IF EXISTS pte_note_len;
ALTER TABLE public.provider_time_entries ADD CONSTRAINT pte_note_len
  CHECK (correction_note IS NULL OR char_length(correction_note) <= 300);
ALTER TABLE public.provider_time_settings DROP CONSTRAINT IF EXISTS pts_qr_len;
ALTER TABLE public.provider_time_settings ADD CONSTRAINT pts_qr_len
  CHECK (qr_secret IS NULL OR char_length(qr_secret) <= 64);
