-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE — CONTRÔLEUR : connexion par CODE + mot de passe (SANS compte client)
--            + ARCHIVAGE bloqué tant que le portefeuille organisateur n'est pas vide
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — appliqué en prod via l'API Management (même canal que le déploiement).

-- ── Identifiant de connexion lisible (CTRL-XXXX) ; code_hash = hash du MOT DE PASSE ──
ALTER TABLE public.event_controllers ADD COLUMN IF NOT EXISTS login_code text UNIQUE;

-- ── Sessions contrôleur (jeton scopé à UN événement, scan uniquement) ───────
CREATE TABLE IF NOT EXISTS public.controller_sessions (
  token text PRIMARY KEY,
  controller_id uuid NOT NULL REFERENCES public.event_controllers(id) ON DELETE CASCADE,
  event_id uuid NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.controller_sessions ENABLE ROW LEVEL SECURITY;  -- aucune policy : RPC-only

-- Session valide → ligne contrôleur ; sinon NULL. (Fail-closed, ne lève jamais.)
CREATE OR REPLACE FUNCTION public.controller_from_token(p_token text)
RETURNS public.event_controllers LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c event_controllers%ROWTYPE;
BEGIN
  IF p_token IS NULL OR length(p_token) < 20 THEN RETURN NULL; END IF;
  SELECT c.* INTO v_c FROM controller_sessions s JOIN event_controllers c ON c.id = s.controller_id
   WHERE s.token = p_token AND s.expires_at > now() AND c.is_active;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN v_c;
END; $$;

-- ── Création contrôleur v2 : l'organisateur donne nom + MOT DE PASSE → code généré ──
DROP FUNCTION IF EXISTS public.create_event_controller(uuid, text, text);
CREATE OR REPLACE FUNCTION public.create_event_controller(p_event_id uuid, p_name text, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE; v_id uuid; v_code text;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF auth.uid() NOT IN (v_e.organizer_user_id, v_e.provider_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  IF length(btrim(p_password)) < 4 THEN RETURN jsonb_build_object('success', false, 'error', 'CODE_TOO_SHORT'); END IF;
  -- Code de connexion UNIQUE lisible : CTRL-XXXX (boucle anti-collision).
  LOOP
    v_code := 'CTRL-' || lpad((floor(random() * 10000))::int::text, 4, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM event_controllers WHERE login_code = v_code);
  END LOOP;
  INSERT INTO event_controllers (event_id, name, login_code, code_hash, created_by)
  VALUES (p_event_id, btrim(p_name), v_code, extensions.crypt(btrim(p_password), extensions.gen_salt('bf')), auth.uid())
  RETURNING id INTO v_id;
  -- Le code est retourné UNE fois (le mot de passe n'est jamais stocké en clair).
  RETURN jsonb_build_object('success', true, 'controller_id', v_id, 'login_code', v_code);
END; $$;

-- ── CONNEXION par code + mot de passe → jeton de session (48h). Refus GÉNÉRIQUE. ──
CREATE OR REPLACE FUNCTION public.verify_controller_login(p_code text, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c event_controllers%ROWTYPE; v_token text; v_status text;
BEGIN
  SELECT * INTO v_c FROM event_controllers
   WHERE upper(btrim(login_code)) = upper(btrim(p_code)) AND is_active;
  IF NOT FOUND OR v_c.code_hash <> extensions.crypt(btrim(COALESCE(p_password, '')), v_c.code_hash) THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_LOGIN');  -- générique (pas de fuite)
  END IF;
  SELECT status INTO v_status FROM events WHERE id = v_c.event_id;
  IF v_status = 'archived' THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_LOGIN'); END IF;
  v_token := encode(extensions.gen_random_bytes(24), 'hex');
  INSERT INTO controller_sessions (token, controller_id, event_id, expires_at)
  VALUES (v_token, v_c.id, v_c.event_id, now() + interval '48 hours');
  RETURN jsonb_build_object('success', true, 'token', v_token, 'event_id', v_c.event_id, 'name', v_c.name);
END; $$;

-- ── Scan / manifest / sync PAR SESSION (le jeton n'ouvre QUE le scan de SON événement) ──
CREATE OR REPLACE FUNCTION public.scan_event_ticket_session(p_token text, p_qr_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c event_controllers; v_t event_tickets%ROWTYPE;
BEGIN
  v_c := public.controller_from_token(p_token);
  IF v_c.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_SESSION'); END IF;
  SELECT * INTO v_t FROM event_tickets WHERE qr_code = p_qr_code AND event_id = v_c.event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_NOT_FOUND'); END IF;
  IF v_t.status = 'used' THEN RETURN jsonb_build_object('success', false, 'error', 'ALREADY_USED', 'scanned_at', v_t.scanned_at); END IF;
  IF v_t.status <> 'valid' OR v_t.buyer_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_INVALID'); END IF;
  UPDATE event_tickets SET status = 'used', scanned_at = now() WHERE id = v_t.id;
  UPDATE event_controllers SET scans_count = scans_count + 1 WHERE id = v_c.id;
  RETURN jsonb_build_object('success', true, 'ticket_id', v_t.id, 'used_at', now());
END; $$;

CREATE OR REPLACE FUNCTION public.get_event_scan_manifest_session(p_token text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c event_controllers;
BEGIN
  v_c := public.controller_from_token(p_token);
  IF v_c.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_SESSION'); END IF;
  RETURN jsonb_build_object('success', true, 'event_id', v_c.event_id, 'tickets', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('qr', t.qr_code, 'status', t.status))
    FROM event_tickets t WHERE t.event_id = v_c.event_id AND t.buyer_user_id IS NOT NULL), '[]'::jsonb));
END; $$;

CREATE OR REPLACE FUNCTION public.sync_offline_scans_session(p_token text, p_scans jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c event_controllers; v_item jsonb; v_qr text; v_at timestamptz; v_t event_tickets%ROWTYPE;
        v_results jsonb := '[]'::jsonb; v_res text;
BEGIN
  v_c := public.controller_from_token(p_token);
  IF v_c.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_SESSION'); END IF;
  IF p_scans IS NULL OR jsonb_typeof(p_scans) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'BAD_PAYLOAD');
  END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_scans) LOOP
    v_qr := v_item->>'qr';
    v_at := LEAST(COALESCE((v_item->>'at')::timestamptz, now()), now());
    SELECT * INTO v_t FROM event_tickets WHERE qr_code = v_qr AND event_id = v_c.event_id FOR UPDATE;
    IF NOT FOUND THEN v_res := 'not_found';
    ELSIF v_t.status = 'used' THEN
      IF v_at < v_t.scanned_at THEN UPDATE event_tickets SET scanned_at = v_at WHERE id = v_t.id; END IF;
      v_res := 'conflict';
    ELSIF v_t.status = 'valid' AND v_t.buyer_user_id IS NOT NULL THEN
      UPDATE event_tickets SET status = 'used', scanned_at = v_at WHERE id = v_t.id;
      UPDATE event_controllers SET scans_count = scans_count + 1 WHERE id = v_c.id;
      v_res := 'ok';
    ELSE v_res := 'invalid';
    END IF;
    v_results := v_results || jsonb_build_object('qr', v_qr, 'result', v_res);
  END LOOP;
  RETURN jsonb_build_object('success', true, 'results', v_results);
END; $$;

-- ── Désactivation IMMÉDIATE (tue aussi les sessions du contrôleur) ──────────
CREATE OR REPLACE FUNCTION public.set_event_controller_active(p_controller_id uuid, p_active boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c event_controllers%ROWTYPE; v_e events%ROWTYPE;
BEGIN
  SELECT * INTO v_c FROM event_controllers WHERE id = p_controller_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND'); END IF;
  SELECT * INTO v_e FROM events WHERE id = v_c.event_id;
  IF auth.uid() NOT IN (v_e.organizer_user_id, v_e.provider_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  UPDATE event_controllers SET is_active = p_active WHERE id = p_controller_id;
  IF NOT p_active THEN DELETE FROM controller_sessions WHERE controller_id = p_controller_id; END IF;
  RETURN jsonb_build_object('success', true);
END; $$;

-- ── ARCHIVAGE bloqué si portefeuille non vide OU remboursements dus ─────────
CREATE OR REPLACE FUNCTION public.archive_event(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE; v_w organizer_wallets%ROWTYPE; v_due int;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF v_e.provider_user_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_PROVIDER');
  END IF;
  -- Verrou FOR UPDATE : pas de course avec un retrait simultané.
  SELECT * INTO v_w FROM organizer_wallets WHERE event_id = p_event_id FOR UPDATE;
  IF FOUND AND v_w.balance > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'WALLET_NOT_EMPTY',
      'balance', v_w.balance, 'currency', v_w.currency);
  END IF;
  -- Remboursements d'annulation encore dus → pas d'archivage non plus.
  SELECT count(*) INTO v_due FROM event_tickets WHERE event_id = p_event_id AND refund_due;
  IF v_due > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'REFUNDS_PENDING', 'refund_due', v_due);
  END IF;
  UPDATE events SET status = 'archived' WHERE id = p_event_id;
  IF v_e.organizer_user_id IS NOT NULL THEN
    UPDATE profiles SET is_active = false WHERE id = v_e.organizer_user_id;
    DELETE FROM controller_sessions WHERE event_id = p_event_id;
  END IF;
  RETURN jsonb_build_object('success', true);
END; $$;

-- ── Grants : login + RPC session accessibles SANS compte (anon) — fail-closed par jeton/hachage ──
REVOKE ALL ON FUNCTION public.controller_from_token(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.controller_from_token(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.create_event_controller(uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.verify_controller_login(text, text)          TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.scan_event_ticket_session(text, text)        TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_event_scan_manifest_session(text)        TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.sync_offline_scans_session(text, jsonb)      TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_event_controller_active(uuid, boolean)   TO authenticated, service_role;
