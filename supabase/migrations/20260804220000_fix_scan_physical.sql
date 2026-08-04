-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE — FIX scan des billets PHYSIQUES + verrou séparation canaux
-- ═══════════════════════════════════════════════════════════════════════════════
-- Cause racine : « buyer_user_id IS NULL → TICKET_INVALID » écrit AVANT les billets physiques.
-- Nouvelle règle : VALIDE AU SCAN = status='valid' (l'acheteur n'est plus un critère d'entrée).
-- Anti-double-entrée INTACT : used → ALREADY_USED ; refunded/void → TICKET_INVALID.
-- + Course impression/vente fermée : la liste à imprimer est construite à partir des lignes
--   VERROUILLÉES (UPDATE … RETURNING) — un billet en cours d'achat (SKIP LOCKED) est exclu.

-- ── Scan organisateur/prestataire/contrôleur(code) ──
CREATE OR REPLACE FUNCTION public.scan_event_ticket(p_qr_code text, p_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_t event_tickets%ROWTYPE;
BEGIN
  SELECT * INTO v_t FROM event_tickets WHERE qr_code = p_qr_code FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_NOT_FOUND'); END IF;
  IF NOT public.event_can_scan(v_t.event_id, p_code) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  IF v_t.status = 'used' THEN
    RETURN jsonb_build_object('success', false, 'error', 'ALREADY_USED', 'scanned_at', v_t.scanned_at);
  END IF;
  IF v_t.status <> 'valid' THEN
    RETURN jsonb_build_object('success', false, 'error', 'TICKET_INVALID');
  END IF;
  UPDATE event_tickets SET status = 'used', scanned_at = now(), scanned_by = auth.uid() WHERE id = v_t.id;
  IF p_code IS NOT NULL THEN
    UPDATE event_controllers SET scans_count = scans_count + 1
     WHERE event_id = v_t.event_id AND is_active AND code_hash = extensions.crypt(btrim(p_code), code_hash);
  END IF;
  RETURN jsonb_build_object('success', true, 'ticket_id', v_t.id, 'used_at', now(), 'channel', v_t.channel);
END; $$;

-- ── Scan par SESSION contrôleur ──
CREATE OR REPLACE FUNCTION public.scan_event_ticket_session(p_token text, p_qr_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c event_controllers; v_t event_tickets%ROWTYPE;
BEGIN
  v_c := public.controller_from_token(p_token);
  IF v_c.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_SESSION'); END IF;
  SELECT * INTO v_t FROM event_tickets WHERE qr_code = p_qr_code AND event_id = v_c.event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_NOT_FOUND'); END IF;
  IF v_t.status = 'used' THEN RETURN jsonb_build_object('success', false, 'error', 'ALREADY_USED', 'scanned_at', v_t.scanned_at); END IF;
  IF v_t.status <> 'valid' THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_INVALID'); END IF;
  UPDATE event_tickets SET status = 'used', scanned_at = now() WHERE id = v_t.id;
  UPDATE event_controllers SET scans_count = scans_count + 1 WHERE id = v_c.id;
  RETURN jsonb_build_object('success', true, 'ticket_id', v_t.id, 'used_at', now(), 'channel', v_t.channel);
END; $$;

-- ── Sync hors-ligne : même règle (status='valid'), 2 variantes ──
CREATE OR REPLACE FUNCTION public.sync_offline_scans(p_event_id uuid, p_scans jsonb, p_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_item jsonb; v_qr text; v_at timestamptz; v_t event_tickets%ROWTYPE;
        v_results jsonb := '[]'::jsonb; v_res text;
BEGIN
  IF NOT public.event_can_scan(p_event_id, p_code) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  IF p_scans IS NULL OR jsonb_typeof(p_scans) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'BAD_PAYLOAD');
  END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_scans) LOOP
    v_qr := v_item->>'qr';
    v_at := LEAST(COALESCE((v_item->>'at')::timestamptz, now()), now());
    SELECT * INTO v_t FROM event_tickets WHERE qr_code = v_qr AND event_id = p_event_id FOR UPDATE;
    IF NOT FOUND THEN v_res := 'not_found';
    ELSIF v_t.status = 'used' THEN
      IF v_at < v_t.scanned_at THEN UPDATE event_tickets SET scanned_at = v_at WHERE id = v_t.id; END IF;
      v_res := 'conflict';
    ELSIF v_t.status = 'valid' THEN
      UPDATE event_tickets SET status = 'used', scanned_at = v_at, scanned_by = auth.uid() WHERE id = v_t.id;
      v_res := 'ok';
    ELSE v_res := 'invalid';
    END IF;
    v_results := v_results || jsonb_build_object('qr', v_qr, 'result', v_res);
  END LOOP;
  RETURN jsonb_build_object('success', true, 'results', v_results);
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
    ELSIF v_t.status = 'valid' THEN
      UPDATE event_tickets SET status = 'used', scanned_at = v_at WHERE id = v_t.id;
      UPDATE event_controllers SET scans_count = scans_count + 1 WHERE id = v_c.id;
      v_res := 'ok';
    ELSE v_res := 'invalid';
    END IF;
    v_results := v_results || jsonb_build_object('qr', v_qr, 'result', v_res);
  END LOOP;
  RETURN jsonb_build_object('success', true, 'results', v_results);
END; $$;

-- ── Manifests hors-ligne : inclure TOUS les billets (physiques compris), pas seulement vendus ──
CREATE OR REPLACE FUNCTION public.get_event_scan_manifest(p_event_id uuid, p_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.event_can_scan(p_event_id, p_code) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  RETURN jsonb_build_object('success', true, 'tickets', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('qr', t.qr_code, 'status', t.status))
    FROM event_tickets t WHERE t.event_id = p_event_id), '[]'::jsonb));
END; $$;

CREATE OR REPLACE FUNCTION public.get_event_scan_manifest_session(p_token text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c event_controllers;
BEGIN
  v_c := public.controller_from_token(p_token);
  IF v_c.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_SESSION'); END IF;
  RETURN jsonb_build_object('success', true, 'event_id', v_c.event_id, 'tickets', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('qr', t.qr_code, 'status', t.status))
    FROM event_tickets t WHERE t.event_id = v_c.event_id), '[]'::jsonb));
END; $$;

-- ── Impression : liste construite depuis les lignes VERROUILLÉES (course impression/vente fermée) ──
CREATE OR REPLACE FUNCTION public.get_physical_tickets_for_print(p_event_id uuid, p_ticket_type_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE; v_list jsonb;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF auth.uid() NOT IN (v_e.organizer_user_id, v_e.provider_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  -- UPDATE d'abord (verrous de lignes) : un billet en cours d'achat (verrouillé) fait ATTENDRE ici,
  -- puis le WHERE ré-évalué (buyer non nul) l'EXCLUT. Ré-impression = mêmes billets, mêmes numéros
  -- (printed_at conservé via COALESCE) — jamais de doublon.
  WITH stamped AS (
    UPDATE event_tickets t SET printed_at = COALESCE(t.printed_at, now())
     WHERE t.event_id = p_event_id AND t.buyer_user_id IS NULL AND t.status = 'valid'
       AND (p_ticket_type_id IS NULL OR t.ticket_type_id = p_ticket_type_id)
    RETURNING t.qr_code, t.ticket_number, t.ticket_type_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'qr', s.qr_code, 'number', s.ticket_number, 'type_name', tt.name, 'price', tt.price, 'currency', tt.currency)
           ORDER BY tt.name, s.ticket_number), '[]'::jsonb)
    INTO v_list
    FROM stamped s JOIN event_ticket_types tt ON tt.id = s.ticket_type_id;
  RETURN jsonb_build_object('success', true, 'event_title', v_e.title, 'cover_image', v_e.cover_image,
                            'venue', v_e.venue, 'event_date', v_e.event_date, 'tickets', v_list);
END; $$;

-- ── Récap par type : en ligne vendus / imprimés / imprimables (UI organisateur) ──
CREATE OR REPLACE FUNCTION public.get_event_channel_stats(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id;
  IF NOT FOUND OR auth.uid() NOT IN (v_e.organizer_user_id, v_e.provider_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  RETURN jsonb_build_object('success', true, 'types', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'type_name', tt.name,
      'online_sold',   (SELECT count(*) FROM event_tickets t WHERE t.ticket_type_id = tt.id AND t.channel = 'online'),
      'printed',       (SELECT count(*) FROM event_tickets t WHERE t.ticket_type_id = tt.id AND t.buyer_user_id IS NULL AND t.printed_at IS NOT NULL AND t.status = 'valid'),
      'printable',     (SELECT count(*) FROM event_tickets t WHERE t.ticket_type_id = tt.id AND t.buyer_user_id IS NULL AND t.printed_at IS NULL AND t.status = 'valid'),
      'total',         (SELECT count(*) FROM event_tickets t WHERE t.ticket_type_id = tt.id)
    ) ORDER BY tt.name)
    FROM event_ticket_types tt WHERE tt.event_id = p_event_id), '[]'::jsonb));
END; $$;

REVOKE ALL ON FUNCTION public.get_event_channel_stats(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_event_channel_stats(uuid) TO authenticated, service_role;
