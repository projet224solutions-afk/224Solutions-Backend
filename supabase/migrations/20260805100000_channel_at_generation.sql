-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE — Canal choisi à la GÉNÉRATION (online/physical) + bascule SENS UNIQUE online→physical
-- ═══════════════════════════════════════════════════════════════════════════════
-- Fin du « pot commun » : le prestataire choisit le canal en générant (numérotation posée d'emblée).
-- Vente en ligne = UNIQUEMENT channel='online' ; impression = UNIQUEMENT channel='physical'.
-- Bascule : SEULS les billets EN LIGNE NON VENDUS → physique (jamais l'inverse — aucune fonction).
-- Même commission (déjà prépayée) — la bascule ne re-facture rien.
-- Données existantes : vendus=online, imprimés/libres=physical (état actuel) — rien à migrer.

-- ── 1) Génération : p_channel OBLIGATOIRE, numérotation du canal posée d'emblée ──
DROP FUNCTION IF EXISTS public.generate_tickets_prepaid(uuid, uuid, integer, text);
CREATE OR REPLACE FUNCTION public.generate_tickets_prepaid(
  p_event_id uuid, p_ticket_type_id uuid, p_quantity integer, p_idempotency text, p_channel text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_e events%ROWTYPE; v_tt event_ticket_types%ROWTYPE; v_actor uuid := auth.uid();
  v_x numeric; v_total numeric; v_batch uuid; i integer; v_base int;
BEGIN
  IF v_actor IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED'); END IF;
  IF p_channel IS NULL OR p_channel NOT IN ('online','physical') THEN
    RETURN jsonb_build_object('success', false, 'error', 'CHANNEL_REQUIRED');
  END IF;
  IF COALESCE(p_quantity, 0) <= 0 OR p_quantity > 100000 THEN
    RETURN jsonb_build_object('success', false, 'error', 'BAD_QUANTITY');
  END IF;
  IF EXISTS (SELECT 1 FROM event_ticket_batches WHERE payment_ref = 'event-batch-' || p_idempotency) THEN
    RETURN jsonb_build_object('success', true, 'already', true);
  END IF;
  SELECT * INTO v_e FROM events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF v_e.provider_user_id IS DISTINCT FROM v_actor THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_PROVIDER');
  END IF;
  IF v_e.status IN ('archived','cancelled','ended') THEN
    RETURN jsonb_build_object('success', false, 'error', 'EVENT_CLOSED');
  END IF;
  SELECT * INTO v_tt FROM event_ticket_types WHERE id = p_ticket_type_id AND event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_TYPE_NOT_FOUND'); END IF;
  SELECT COALESCE((setting_value->>'value')::numeric, 500) INTO v_x
  FROM pdg_settings WHERE setting_key = 'event_ticket_commission_gnf';
  v_x := COALESCE(v_x, 500);
  v_total := p_quantity * v_x;   -- MÊME commission pour les 2 canaux
  IF v_total > 0 THEN
    PERFORM public.wallet_debit_internal(
      v_actor, v_total,
      'Commission billetterie (' || p_channel || ') : ' || p_quantity || ' tickets × ' || v_x || ' GNF — ' || v_e.title,
      'event-batch-' || p_idempotency);
    PERFORM public.record_pdg_revenue(
      'event_ticket_commission', v_total, 0, NULL, v_actor, NULL,
      jsonb_build_object('event_id', p_event_id, 'quantity', p_quantity, 'channel', p_channel,
                         'commission_per_ticket', v_x, 'non_refundable', true), 'GNF');
  END IF;
  INSERT INTO event_ticket_batches (event_id, ticket_type_id, quantity, commission_per_ticket,
                                    total_commission_paid, payment_ref)
  VALUES (p_event_id, p_ticket_type_id, p_quantity, v_x, v_total, 'event-batch-' || p_idempotency)
  RETURNING id INTO v_batch;
  -- Numérotation DU CANAL (type verrouillé → atomique).
  SELECT COALESCE(MAX(ticket_number), 0) INTO v_base
    FROM event_tickets WHERE ticket_type_id = p_ticket_type_id AND channel = p_channel;
  FOR i IN 1..p_quantity LOOP
    INSERT INTO event_tickets (event_id, ticket_type_id, batch_id, qr_code, channel, ticket_number)
    VALUES (p_event_id, p_ticket_type_id, v_batch, encode(extensions.gen_random_bytes(24), 'hex'), p_channel, v_base + i);
  END LOOP;
  UPDATE event_ticket_types SET quantity_total = quantity_total + p_quantity WHERE id = p_ticket_type_id;
  UPDATE events SET status = 'active' WHERE id = p_event_id AND status = 'draft';
  RETURN jsonb_build_object('success', true, 'batch_id', v_batch, 'tickets_generated', p_quantity,
                            'channel', p_channel, 'commission_per_ticket', v_x, 'total_commission_paid', v_total);
END; $$;
GRANT EXECUTE ON FUNCTION public.generate_tickets_prepaid(uuid, uuid, integer, text, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.generate_tickets_prepaid(uuid, uuid, integer, text, text) FROM PUBLIC, anon;

-- ── 2) Vente EN LIGNE : puise UNIQUEMENT dans channel='online' (plus de re-bascule à l'achat) ──
CREATE OR REPLACE FUNCTION public.buy_event_ticket(
  p_ticket_type_id uuid, p_idempotency text, p_buyer uuid DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_buyer uuid := COALESCE(p_buyer, auth.uid());
  v_tt event_ticket_types%ROWTYPE; v_e events%ROWTYPE; v_ticket event_tickets%ROWTYPE;
  v_ref text := 'event-buy-' || p_idempotency; v_owned integer;
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
  IF v_tt.max_per_buyer IS NOT NULL AND v_tt.max_per_buyer > 0 THEN
    SELECT count(*) INTO v_owned FROM event_tickets
     WHERE ticket_type_id = p_ticket_type_id AND buyer_user_id = v_buyer AND status <> 'refunded';
    IF v_owned >= v_tt.max_per_buyer THEN
      RETURN jsonb_build_object('success', false, 'error', 'MAX_PER_BUYER', 'max', v_tt.max_per_buyer);
    END IF;
  END IF;
  -- CANAL EN LIGNE UNIQUEMENT : le stock physique n'est jamais vendu dans l'app.
  SELECT * INTO v_ticket FROM event_tickets
   WHERE ticket_type_id = p_ticket_type_id AND channel = 'online'
     AND buyer_user_id IS NULL AND status = 'valid'
   ORDER BY ticket_number LIMIT 1 FOR UPDATE SKIP LOCKED;
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

-- ── 3) Impression : UNIQUEMENT channel='physical' ──
CREATE OR REPLACE FUNCTION public.get_physical_tickets_for_print(p_event_id uuid, p_ticket_type_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE; v_list jsonb;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF auth.uid() NOT IN (v_e.organizer_user_id, v_e.provider_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  WITH stamped AS (
    UPDATE event_tickets t SET printed_at = COALESCE(t.printed_at, now())
     WHERE t.event_id = p_event_id AND t.channel = 'physical'
       AND t.buyer_user_id IS NULL AND t.status = 'valid'
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

-- ── 4) BASCULE SENS UNIQUE : N billets EN LIGNE NON VENDUS → PHYSIQUE (re-numérotés PHY suivants) ──
-- Autorisation : prestataire OU organisateur (les deux pilotent le stock — rapporté).
-- Anciens numéros ONL libérés = trous acceptés (documenté). AUCUNE fonction inverse n'existe.
CREATE OR REPLACE FUNCTION public.switch_tickets_to_physical(
  p_event_id uuid, p_ticket_type_id uuid, p_quantity integer
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE; v_tt event_ticket_types%ROWTYPE; v_base int; v_n int;
BEGIN
  IF COALESCE(p_quantity, 0) <= 0 THEN RETURN jsonb_build_object('success', false, 'error', 'BAD_QUANTITY'); END IF;
  SELECT * INTO v_e FROM events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF auth.uid() NOT IN (v_e.provider_user_id, v_e.organizer_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  SELECT * INTO v_tt FROM event_ticket_types WHERE id = p_ticket_type_id AND event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_TYPE_NOT_FOUND'); END IF;
  -- Assez de billets EN LIGNE non vendus ? (vendus/imprimés/scannés JAMAIS basculables par ces filtres)
  SELECT count(*) INTO v_n FROM event_tickets
   WHERE ticket_type_id = p_ticket_type_id AND channel = 'online'
     AND buyer_user_id IS NULL AND status = 'valid';
  IF v_n < p_quantity THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ENOUGH_UNSOLD', 'available', v_n);
  END IF;
  SELECT COALESCE(MAX(ticket_number), 0) INTO v_base
    FROM event_tickets WHERE ticket_type_id = p_ticket_type_id AND channel = 'physical';
  -- Bascule atomique (lignes verrouillées) + re-numérotation PHY consécutive.
  WITH locked AS (
    SELECT id, ticket_number
      FROM event_tickets
     WHERE ticket_type_id = p_ticket_type_id AND channel = 'online'
       AND buyer_user_id IS NULL AND status = 'valid'
     ORDER BY ticket_number LIMIT p_quantity
     FOR UPDATE SKIP LOCKED
  ), picked AS (
    SELECT id, row_number() OVER (ORDER BY ticket_number) AS rn FROM locked
  )
  UPDATE event_tickets t SET channel = 'physical', ticket_number = v_base + p.rn, printed_at = NULL
    FROM picked p WHERE t.id = p.id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n < p_quantity THEN
    -- Course (billets verrouillés par des achats simultanés) → tout annuler, refus clair.
    RAISE EXCEPTION 'NOT_ENOUGH_UNSOLD';
  END IF;
  RETURN jsonb_build_object('success', true, 'switched', v_n, 'first_number', v_base + 1, 'last_number', v_base + v_n);
END; $$;
REVOKE ALL ON FUNCTION public.switch_tickets_to_physical(uuid, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.switch_tickets_to_physical(uuid, uuid, integer) TO authenticated, service_role;

-- ── 5) Stats par TYPE et par CANAL (dashboard : deux stocks distincts) ──
CREATE OR REPLACE FUNCTION public.get_event_channel_stats(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id;
  IF NOT FOUND OR auth.uid() NOT IN (v_e.organizer_user_id, v_e.provider_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  RETURN jsonb_build_object('success', true, 'types', COALESCE((
    SELECT jsonb_agg(x ORDER BY x->>'type_name') FROM (
      SELECT jsonb_build_object(
        'type_name', tt.name,
        'total',          count(t.id),
        'online_sold',    count(t.id) FILTER (WHERE t.channel = 'online' AND t.buyer_user_id IS NOT NULL),
        'online_to_sell', count(t.id) FILTER (WHERE t.channel = 'online' AND t.buyer_user_id IS NULL AND t.status = 'valid'),
        'printed',        count(t.id) FILTER (WHERE t.channel = 'physical' AND t.printed_at IS NOT NULL),
        'printable',      count(t.id) FILTER (WHERE t.channel = 'physical' AND t.printed_at IS NULL AND t.status = 'valid'),
        'distributed',    count(t.id) FILTER (WHERE t.buyer_user_id IS NOT NULL OR t.printed_at IS NOT NULL),
        'scanned',        count(t.id) FILTER (WHERE t.status = 'used'),
        'to_scan',        count(t.id) FILTER (WHERE (t.buyer_user_id IS NOT NULL OR t.printed_at IS NOT NULL) AND t.status = 'valid'),
        'to_sell',        count(t.id) FILTER (WHERE t.buyer_user_id IS NULL AND t.printed_at IS NULL AND t.status = 'valid')
      ) AS x
      FROM event_ticket_types tt LEFT JOIN event_tickets t ON t.ticket_type_id = tt.id
      WHERE tt.event_id = p_event_id GROUP BY tt.id, tt.name
    ) s), '[]'::jsonb));
END; $$;
