-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE — Types d'ÉVÉNEMENTS + type de billet VISIBLE AU SCAN
-- ═══════════════════════════════════════════════════════════════════════════════
-- event_type sur events (existants → 'autre', aucun cassé). Le scan renvoie le NOM DU TYPE de billet
-- (« ✅ VALIDE — VIP ») pour orienter à la porte. Billets GRATUITS : déjà supportés (prix 0 → aucun débit
-- client) — la commission prépayée du PDG s'applique à la GÉNÉRATION quel que soit le prix (inchangé).

ALTER TABLE public.events ADD COLUMN IF NOT EXISTS event_type text NOT NULL DEFAULT 'autre'
  CHECK (event_type IN ('concert','mariage','conference','sport','festival','religieux','soiree','autre'));
CREATE INDEX IF NOT EXISTS idx_events_type ON public.events(event_type);

-- Scan organisateur/contrôleur(code) : + type_name
CREATE OR REPLACE FUNCTION public.scan_event_ticket(p_qr_code text, p_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_t event_tickets%ROWTYPE; v_type text;
BEGIN
  SELECT * INTO v_t FROM event_tickets WHERE qr_code = p_qr_code FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_NOT_FOUND'); END IF;
  IF NOT public.event_can_scan(v_t.event_id, p_code) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  SELECT name INTO v_type FROM event_ticket_types WHERE id = v_t.ticket_type_id;
  IF v_t.status = 'used' THEN
    RETURN jsonb_build_object('success', false, 'error', 'ALREADY_USED', 'scanned_at', v_t.scanned_at, 'type_name', v_type);
  END IF;
  IF v_t.status <> 'valid' THEN
    RETURN jsonb_build_object('success', false, 'error', 'TICKET_INVALID', 'type_name', v_type);
  END IF;
  UPDATE event_tickets SET status = 'used', scanned_at = now(), scanned_by = auth.uid() WHERE id = v_t.id;
  IF p_code IS NOT NULL THEN
    UPDATE event_controllers SET scans_count = scans_count + 1
     WHERE event_id = v_t.event_id AND is_active AND code_hash = extensions.crypt(btrim(p_code), code_hash);
  END IF;
  RETURN jsonb_build_object('success', true, 'ticket_id', v_t.id, 'used_at', now(), 'channel', v_t.channel, 'type_name', v_type);
END; $$;

-- Scan par SESSION : + type_name
CREATE OR REPLACE FUNCTION public.scan_event_ticket_session(p_token text, p_qr_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c event_controllers; v_t event_tickets%ROWTYPE; v_type text;
BEGIN
  v_c := public.controller_from_token(p_token);
  IF v_c.id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'INVALID_SESSION'); END IF;
  SELECT * INTO v_t FROM event_tickets WHERE qr_code = p_qr_code AND event_id = v_c.event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_NOT_FOUND'); END IF;
  SELECT name INTO v_type FROM event_ticket_types WHERE id = v_t.ticket_type_id;
  IF v_t.status = 'used' THEN RETURN jsonb_build_object('success', false, 'error', 'ALREADY_USED', 'scanned_at', v_t.scanned_at, 'type_name', v_type); END IF;
  IF v_t.status <> 'valid' THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_INVALID', 'type_name', v_type); END IF;
  UPDATE event_tickets SET status = 'used', scanned_at = now() WHERE id = v_t.id;
  UPDATE event_controllers SET scans_count = scans_count + 1 WHERE id = v_c.id;
  RETURN jsonb_build_object('success', true, 'ticket_id', v_t.id, 'used_at', now(), 'channel', v_t.channel, 'type_name', v_type);
END; $$;
