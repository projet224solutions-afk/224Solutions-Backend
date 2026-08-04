-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE — TERRAIN : contrôleurs + limite/acheteur + scan hors-ligne (manifest+sync) + remboursement
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — appliqué en prod via l'API Management (même canal que le déploiement).

-- ── A3 : limite d'achat par personne (anti-marché noir) ─────────────────────
ALTER TABLE public.event_ticket_types ADD COLUMN IF NOT EXISTS max_per_buyer integer;

-- ── A2 : CONTRÔLEURS (scan-only, par événement) — codes hachés, jamais en clair ──
CREATE TABLE IF NOT EXISTS public.event_controllers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  name text NOT NULL,
  code_hash text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  scans_count integer NOT NULL DEFAULT 0,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ectrl_event ON public.event_controllers(event_id);
ALTER TABLE public.event_controllers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ectrl_read ON public.event_controllers;
CREATE POLICY ectrl_read ON public.event_controllers FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.events e WHERE e.id = event_id
    AND (e.provider_user_id = auth.uid() OR e.organizer_user_id = auth.uid())));

-- L'appelant peut-il scanner cet événement ? organisateur/prestataire OU contrôleur (code).
CREATE OR REPLACE FUNCTION public.event_can_scan(p_event_id uuid, p_code text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id;
  IF NOT FOUND THEN RETURN false; END IF;
  IF auth.uid() IS NOT NULL AND auth.uid() IN (v_e.organizer_user_id, v_e.provider_user_id) THEN RETURN true; END IF;
  IF p_code IS NOT NULL AND btrim(p_code) <> '' THEN
    RETURN EXISTS (SELECT 1 FROM event_controllers c WHERE c.event_id = p_event_id AND c.is_active
                     AND c.code_hash = extensions.crypt(btrim(p_code), c.code_hash));
  END IF;
  RETURN false;
END; $$;

-- L'organisateur (ou le prestataire) crée un contrôleur : nom + code (haché bcrypt).
CREATE OR REPLACE FUNCTION public.create_event_controller(p_event_id uuid, p_name text, p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE; v_id uuid;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF auth.uid() NOT IN (v_e.organizer_user_id, v_e.provider_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  IF length(btrim(p_code)) < 4 THEN RETURN jsonb_build_object('success', false, 'error', 'CODE_TOO_SHORT'); END IF;
  INSERT INTO event_controllers (event_id, name, code_hash, created_by)
  VALUES (p_event_id, btrim(p_name), extensions.crypt(btrim(p_code), extensions.gen_salt('bf')), auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('success', true, 'controller_id', v_id);
END; $$;

-- ── A1 : SCAN HORS-LIGNE — manifest (pré-téléchargement) + sync en lot ──────
-- Manifest : billets VENDUS de l'événement (token + statut) pour vérification LOCALE.
-- Accessible organisateur/prestataire OU contrôleur (code) — jamais public.
CREATE OR REPLACE FUNCTION public.get_event_scan_manifest(p_event_id uuid, p_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.event_can_scan(p_event_id, p_code) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  RETURN jsonb_build_object('success', true, 'tickets', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('qr', t.qr_code, 'status', t.status))
    FROM event_tickets t WHERE t.event_id = p_event_id AND t.buyer_user_id IS NOT NULL), '[]'::jsonb));
END; $$;

-- Scan UNITAIRE (en ligne) — organisateur/prestataire OU contrôleur (code). Anti double-entrée.
DROP FUNCTION IF EXISTS public.scan_event_ticket(text);
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
  IF v_t.status <> 'valid' OR v_t.buyer_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TICKET_INVALID');
  END IF;
  UPDATE event_tickets SET status = 'used', scanned_at = now(), scanned_by = auth.uid() WHERE id = v_t.id;
  IF p_code IS NOT NULL THEN
    UPDATE event_controllers SET scans_count = scans_count + 1
     WHERE event_id = v_t.event_id AND is_active AND code_hash = extensions.crypt(btrim(p_code), code_hash);
  END IF;
  RETURN jsonb_build_object('success', true, 'ticket_id', v_t.id, 'used_at', now());
END; $$;

-- SYNC EN LOT des scans hors-ligne. Conflit multi-appareils : le PLUS TÔT gagne (horodatage client
-- borné par now()) ; un billet déjà 'used' renvoie 'conflict' avec l'horodatage retenu.
CREATE OR REPLACE FUNCTION public.sync_offline_scans(p_event_id uuid, p_scans jsonb, p_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_item jsonb; v_qr text; v_at timestamptz; v_t event_tickets%ROWTYPE;
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
    v_at := LEAST(COALESCE((v_item->>'at')::timestamptz, now()), now());  -- jamais dans le futur
    SELECT * INTO v_t FROM event_tickets WHERE qr_code = v_qr AND event_id = p_event_id FOR UPDATE;
    IF NOT FOUND THEN v_res := 'not_found';
    ELSIF v_t.status = 'used' THEN
      -- Déjà scanné (autre appareil) : le plus TÔT gagne l'horodatage ; signaler le litige.
      IF v_at < v_t.scanned_at THEN
        UPDATE event_tickets SET scanned_at = v_at WHERE id = v_t.id;
      END IF;
      v_res := 'conflict';
    ELSIF v_t.status = 'valid' AND v_t.buyer_user_id IS NOT NULL THEN
      UPDATE event_tickets SET status = 'used', scanned_at = v_at, scanned_by = auth.uid() WHERE id = v_t.id;
      v_res := 'ok';
    ELSE v_res := 'invalid';
    END IF;
    v_results := v_results || jsonb_build_object('qr', v_qr, 'result', v_res,
      'scanned_at', (SELECT scanned_at FROM event_tickets WHERE qr_code = v_qr AND event_id = p_event_id));
  END LOOP;
  RETURN jsonb_build_object('success', true, 'results', v_results);
END; $$;

-- ── A3 : buy_event_ticket + MAX_PER_BUYER ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.buy_event_ticket(
  p_ticket_type_id uuid, p_idempotency text, p_buyer uuid DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_buyer uuid := COALESCE(p_buyer, auth.uid());
  v_tt event_ticket_types%ROWTYPE;
  v_e events%ROWTYPE;
  v_ticket event_tickets%ROWTYPE;
  v_ref text := 'event-buy-' || p_idempotency;
  v_owned integer;
BEGIN
  IF v_buyer IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED'); END IF;
  IF p_buyer IS NOT NULL AND auth.uid() IS NOT NULL AND p_buyer IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
  END IF;
  SELECT * INTO v_ticket FROM event_tickets WHERE purchase_ref = v_ref;
  IF FOUND THEN
    RETURN jsonb_build_object('success', true, 'already', true, 'ticket_id', v_ticket.id, 'qr_code', v_ticket.qr_code);
  END IF;
  SELECT * INTO v_tt FROM event_ticket_types WHERE id = p_ticket_type_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_TYPE_NOT_FOUND'); END IF;
  SELECT * INTO v_e FROM events WHERE id = v_tt.event_id;
  IF v_e.status <> 'active' THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_ACTIVE'); END IF;
  IF v_e.organizer_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NO_ORGANIZER'); END IF;

  -- A3 : limite par acheteur (anti-revente) — billets déjà détenus pour CE type.
  IF v_tt.max_per_buyer IS NOT NULL AND v_tt.max_per_buyer > 0 THEN
    SELECT count(*) INTO v_owned FROM event_tickets
     WHERE ticket_type_id = p_ticket_type_id AND buyer_user_id = v_buyer AND status <> 'refunded';
    IF v_owned >= v_tt.max_per_buyer THEN
      RETURN jsonb_build_object('success', false, 'error', 'MAX_PER_BUYER', 'max', v_tt.max_per_buyer);
    END IF;
  END IF;

  SELECT * INTO v_ticket FROM event_tickets
   WHERE ticket_type_id = p_ticket_type_id AND buyer_user_id IS NULL AND status = 'valid'
   ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'SOLD_OUT'); END IF;

  IF v_tt.price > 0 THEN
    PERFORM public.wallet_debit_internal(
      v_buyer, v_tt.price, 'Billet ' || v_tt.name || ' — ' || v_e.title, v_ref);
  END IF;
  UPDATE organizer_wallets SET balance = balance + v_tt.price, updated_at = now() WHERE event_id = v_e.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORGANIZER_WALLET_MISSING'; END IF;
  UPDATE event_tickets SET buyer_user_id = v_buyer, purchase_ref = v_ref WHERE id = v_ticket.id;
  UPDATE event_ticket_types SET quantity_sold = quantity_sold + 1 WHERE id = p_ticket_type_id;
  BEGIN
    INSERT INTO notifications (user_id, title, message, type, metadata)
    VALUES (v_buyer, '🎫 Votre billet est prêt',
            v_e.title || ' — ' || v_tt.name || '. Présentez le QR à l''entrée.',
            'event_ticket', jsonb_build_object('ticket_id', v_ticket.id, 'link', '/billet/' || v_ticket.qr_code));
  EXCEPTION WHEN OTHERS THEN NULL; END;
  RETURN jsonb_build_object('success', true, 'ticket_id', v_ticket.id, 'qr_code', v_ticket.qr_code, 'price', v_tt.price);
END; $$;

-- ── A4 : ANNULATION + REMBOURSEMENT clients (commission PDG NON remboursée) ──
-- Rembourse chaque billet vendu depuis le portefeuille ORGANISATEUR (wallet acheteur via
-- credit_user_wallet_safe, idempotent par billet). Si solde insuffisant → billets marqués DUS
-- (refund_due) + alerte PDG. Les retraits sont BLOQUÉS dès que l'événement est annulé.
ALTER TABLE public.event_tickets ADD COLUMN IF NOT EXISTS refund_due boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.cancel_event_with_refund(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_e events%ROWTYPE; v_w organizer_wallets%ROWTYPE; v_t record;
  v_price numeric; v_refunded int := 0; v_due int := 0;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF auth.uid() NOT IN (v_e.provider_user_id, v_e.organizer_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  IF v_e.status = 'archived' THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_CLOSED'); END IF;

  UPDATE events SET status = 'cancelled' WHERE id = p_event_id;
  SELECT * INTO v_w FROM organizer_wallets WHERE event_id = p_event_id FOR UPDATE;

  -- Idempotent : billets déjà 'refunded' ignorés ; relance = tente de solder les refund_due.
  FOR v_t IN
    SELECT t.id, t.buyer_user_id, t.qr_code, tt.price, tt.name
      FROM event_tickets t JOIN event_ticket_types tt ON tt.id = t.ticket_type_id
     WHERE t.event_id = p_event_id AND t.buyer_user_id IS NOT NULL AND t.status IN ('valid','used')
     ORDER BY t.created_at
  LOOP
    v_price := COALESCE(v_t.price, 0);
    IF v_w.id IS NOT NULL AND v_w.balance >= v_price THEN
      UPDATE organizer_wallets SET balance = balance - v_price, updated_at = now() WHERE id = v_w.id;
      v_w.balance := v_w.balance - v_price;
      IF v_price > 0 THEN
        PERFORM public.credit_user_wallet_safe(v_t.buyer_user_id, v_price, 'GNF', 'event_refund', 'refund-' || v_t.id::text);
      END IF;
      UPDATE event_tickets SET status = 'refunded', refund_due = false WHERE id = v_t.id;
      v_refunded := v_refunded + 1;
      BEGIN
        INSERT INTO notifications (user_id, title, message, type, metadata)
        VALUES (v_t.buyer_user_id, 'Événement annulé — remboursé',
                v_e.title || ' : votre billet ' || v_t.name || ' est remboursé sur votre wallet.',
                'event_refund', jsonb_build_object('link', '/wallet'));
      EXCEPTION WHEN OTHERS THEN NULL; END;
    ELSE
      UPDATE event_tickets SET refund_due = true WHERE id = v_t.id;
      v_due := v_due + 1;
    END IF;
  END LOOP;

  IF v_due > 0 THEN
    BEGIN
      INSERT INTO system_alerts (severity, module, title, message, metadata)
      VALUES ('critical', 'event_ticketing', 'Remboursements billetterie en souffrance',
              v_e.title || ' annulé : ' || v_due || ' billet(s) non remboursés (portefeuille organisateur insuffisant).',
              jsonb_build_object('event_id', p_event_id, 'refund_due', v_due));
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END IF;

  RETURN jsonb_build_object('success', true, 'refunded', v_refunded, 'refund_due', v_due);
END; $$;

-- Retraits organisateur BLOQUÉS si événement annulé (protège les remboursements dus).
CREATE OR REPLACE FUNCTION public.withdraw_organizer_wallet(
  p_event_id uuid, p_amount numeric, p_method text, p_destination text, p_idempotency text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_w organizer_wallets%ROWTYPE; v_actor uuid := auth.uid(); v_id uuid; v_status text;
BEGIN
  IF v_actor IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED'); END IF;
  IF COALESCE(p_amount, 0) <= 0 THEN RETURN jsonb_build_object('success', false, 'error', 'BAD_AMOUNT'); END IF;
  IF p_method NOT IN ('orange_money','card','bank_transfer') THEN
    RETURN jsonb_build_object('success', false, 'error', 'BAD_METHOD');
  END IF;
  SELECT status INTO v_status FROM events WHERE id = p_event_id;
  IF v_status = 'cancelled' THEN
    RETURN jsonb_build_object('success', false, 'error', 'EVENT_CANCELLED_REFUNDS_FIRST');
  END IF;
  IF EXISTS (SELECT 1 FROM organizer_withdrawals WHERE idempotency_key = p_idempotency) THEN
    RETURN jsonb_build_object('success', true, 'already', true);
  END IF;
  SELECT * INTO v_w FROM organizer_wallets WHERE event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'WALLET_NOT_FOUND'); END IF;
  IF v_w.organizer_user_id IS DISTINCT FROM v_actor THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ORGANIZER');
  END IF;
  IF p_amount > v_w.balance THEN
    RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_BALANCE', 'balance', v_w.balance);
  END IF;
  UPDATE organizer_wallets SET balance = balance - p_amount, updated_at = now() WHERE id = v_w.id;
  INSERT INTO organizer_withdrawals (organizer_wallet_id, organizer_user_id, amount, method, destination, status, idempotency_key)
  VALUES (v_w.id, v_actor, p_amount, p_method, p_destination, 'pending', p_idempotency)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('success', true, 'withdrawal_id', v_id, 'new_balance', v_w.balance - p_amount);
END; $$;

-- ── Grants ──────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.event_can_scan(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_event_controller(uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_event_scan_manifest(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.scan_event_ticket(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sync_offline_scans(uuid, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_event_with_refund(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.buy_event_ticket(uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.withdraw_organizer_wallet(uuid, numeric, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.event_can_scan(uuid, text)                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_event_controller(uuid, text, text)  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_event_scan_manifest(uuid, text)        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.scan_event_ticket(text, text)              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.sync_offline_scans(uuid, jsonb, text)      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_event_with_refund(uuid)             TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.buy_event_ticket(uuid, text, uuid)         TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.withdraw_organizer_wallet(uuid, numeric, text, text, text) TO authenticated, service_role;
