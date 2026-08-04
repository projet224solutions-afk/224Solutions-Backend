-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE — Billets PHYSIQUES : canal + numéro d'ordre par type+canal + impression groupée
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — appliqué en prod via l'API Management.
-- Modèle : les tickets générés (prépayés) = inventaire 'physical' numéroté PHY à la génération.
-- Un achat EN LIGNE assigne un ticket NON IMPRIMÉ et le re-numérote ONL (séquence indépendante).
-- « Télécharger pour imprimer » ESTAMPILLE printed_at → ces billets sont réservés à la vente
-- physique (plus jamais vendus en ligne → un même QR ne peut pas exister papier + en ligne).
-- Atomicité des numéros : le type de billet est verrouillé FOR UPDATE dans les 2 RPC.

ALTER TABLE public.event_tickets
  ADD COLUMN IF NOT EXISTS channel text NOT NULL DEFAULT 'physical' CHECK (channel IN ('physical','online')),
  ADD COLUMN IF NOT EXISTS ticket_number integer,
  ADD COLUMN IF NOT EXISTS printed_at timestamptz;

-- Backfill idempotent des tickets existants : vendus = online, libres = physical, numéros par ordre de création.
DO $$
DECLARE r record; n int;
BEGIN
  FOR r IN SELECT DISTINCT ticket_type_id FROM event_tickets WHERE ticket_number IS NULL LOOP
    n := 0;
    UPDATE event_tickets t SET channel = 'online', ticket_number = s.rn
      FROM (SELECT id, row_number() OVER (ORDER BY created_at) rn FROM event_tickets
             WHERE ticket_type_id = r.ticket_type_id AND buyer_user_id IS NOT NULL AND ticket_number IS NULL) s
     WHERE t.id = s.id;
    UPDATE event_tickets t SET channel = 'physical', ticket_number = s.rn
      FROM (SELECT id, row_number() OVER (ORDER BY created_at) rn FROM event_tickets
             WHERE ticket_type_id = r.ticket_type_id AND buyer_user_id IS NULL AND ticket_number IS NULL) s
     WHERE t.id = s.id;
  END LOOP;
END $$;

-- ── generate_tickets_prepaid : numérote PHY-001… à la génération (type verrouillé FOR UPDATE) ──
CREATE OR REPLACE FUNCTION public.generate_tickets_prepaid(
  p_event_id uuid, p_ticket_type_id uuid, p_quantity integer, p_idempotency text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_e events%ROWTYPE; v_tt event_ticket_types%ROWTYPE; v_actor uuid := auth.uid();
  v_x numeric; v_total numeric; v_batch uuid; i integer; v_base int;
BEGIN
  IF v_actor IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED'); END IF;
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
  v_total := p_quantity * v_x;
  IF v_total > 0 THEN
    PERFORM public.wallet_debit_internal(
      v_actor, v_total,
      'Commission billetterie : ' || p_quantity || ' tickets × ' || v_x || ' GNF — ' || v_e.title,
      'event-batch-' || p_idempotency);
    PERFORM public.record_pdg_revenue(
      'event_ticket_commission', v_total, 0, NULL, v_actor, NULL,
      jsonb_build_object('event_id', p_event_id, 'quantity', p_quantity,
                         'commission_per_ticket', v_x, 'non_refundable', true), 'GNF');
  END IF;
  INSERT INTO event_ticket_batches (event_id, ticket_type_id, quantity, commission_per_ticket,
                                    total_commission_paid, payment_ref)
  VALUES (p_event_id, p_ticket_type_id, p_quantity, v_x, v_total, 'event-batch-' || p_idempotency)
  RETURNING id INTO v_batch;
  -- Numéro PHY suivant (type verrouillé → pas de collision).
  SELECT COALESCE(MAX(ticket_number), 0) INTO v_base
    FROM event_tickets WHERE ticket_type_id = p_ticket_type_id AND channel = 'physical';
  FOR i IN 1..p_quantity LOOP
    INSERT INTO event_tickets (event_id, ticket_type_id, batch_id, qr_code, channel, ticket_number)
    VALUES (p_event_id, p_ticket_type_id, v_batch, encode(extensions.gen_random_bytes(24), 'hex'), 'physical', v_base + i);
  END LOOP;
  UPDATE event_ticket_types SET quantity_total = quantity_total + p_quantity WHERE id = p_ticket_type_id;
  UPDATE events SET status = 'active' WHERE id = p_event_id AND status = 'draft';
  RETURN jsonb_build_object('success', true, 'batch_id', v_batch, 'tickets_generated', p_quantity,
                            'commission_per_ticket', v_x, 'total_commission_paid', v_total);
END; $$;

-- ── buy_event_ticket : achat EN LIGNE = ticket NON imprimé, re-numéroté ONL-001… ──
CREATE OR REPLACE FUNCTION public.buy_event_ticket(
  p_ticket_type_id uuid, p_idempotency text, p_buyer uuid DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_buyer uuid := COALESCE(p_buyer, auth.uid());
  v_tt event_ticket_types%ROWTYPE; v_e events%ROWTYPE; v_ticket event_tickets%ROWTYPE;
  v_ref text := 'event-buy-' || p_idempotency; v_owned integer; v_onl int;
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
  -- NON imprimé uniquement : un billet papier ne peut JAMAIS être revendu en ligne (pas de QR en double).
  SELECT * INTO v_ticket FROM event_tickets
   WHERE ticket_type_id = p_ticket_type_id AND buyer_user_id IS NULL AND status = 'valid' AND printed_at IS NULL
   ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'SOLD_OUT'); END IF;
  IF v_tt.price > 0 THEN
    PERFORM public.wallet_debit_internal(
      v_buyer, v_tt.price, 'Billet ' || v_tt.name || ' — ' || v_e.title, v_ref);
  END IF;
  UPDATE organizer_wallets SET balance = balance + v_tt.price, updated_at = now() WHERE event_id = v_e.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORGANIZER_WALLET_MISSING'; END IF;
  -- Re-numérotation canal EN LIGNE (séquence indépendante ; type verrouillé → atomique).
  SELECT COALESCE(MAX(ticket_number), 0) + 1 INTO v_onl
    FROM event_tickets WHERE ticket_type_id = p_ticket_type_id AND channel = 'online';
  UPDATE event_tickets SET buyer_user_id = v_buyer, purchase_ref = v_ref,
         channel = 'online', ticket_number = v_onl
   WHERE id = v_ticket.id;
  UPDATE event_ticket_types SET quantity_sold = quantity_sold + 1 WHERE id = p_ticket_type_id;
  BEGIN
    INSERT INTO notifications (user_id, title, message, type, metadata)
    VALUES (v_buyer, '🎫 Votre billet est prêt',
            v_e.title || ' — ' || v_tt.name || '. Présentez le QR à l''entrée.',
            'event_ticket', jsonb_build_object('ticket_id', v_ticket.id, 'link', '/billet/' || v_ticket.qr_code));
  EXCEPTION WHEN OTHERS THEN NULL; END;
  RETURN jsonb_build_object('success', true, 'ticket_id', v_ticket.id, 'qr_code', v_ticket.qr_code, 'price', v_tt.price);
END; $$;

-- ── Impression groupée : renvoie les billets NON assignés (+filtre type) et les ESTAMPILLE printed_at ──
CREATE OR REPLACE FUNCTION public.get_physical_tickets_for_print(p_event_id uuid, p_ticket_type_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE; v_list jsonb;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF auth.uid() NOT IN (v_e.organizer_user_id, v_e.provider_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'qr', t.qr_code, 'number', t.ticket_number, 'type_name', tt.name, 'price', tt.price, 'currency', tt.currency)
           ORDER BY tt.name, t.ticket_number), '[]'::jsonb)
    INTO v_list
    FROM event_tickets t JOIN event_ticket_types tt ON tt.id = t.ticket_type_id
   WHERE t.event_id = p_event_id AND t.buyer_user_id IS NULL AND t.status = 'valid'
     AND (p_ticket_type_id IS NULL OR t.ticket_type_id = p_ticket_type_id);
  -- Estampille : réservés au canal PHYSIQUE (plus vendables en ligne).
  UPDATE event_tickets SET printed_at = COALESCE(printed_at, now())
   WHERE event_id = p_event_id AND buyer_user_id IS NULL AND status = 'valid'
     AND (p_ticket_type_id IS NULL OR ticket_type_id = p_ticket_type_id);
  RETURN jsonb_build_object('success', true, 'event_title', v_e.title, 'cover_image', v_e.cover_image,
                            'venue', v_e.venue, 'event_date', v_e.event_date, 'tickets', v_list);
END; $$;

REVOKE ALL ON FUNCTION public.get_physical_tickets_for_print(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_physical_tickets_for_print(uuid, uuid) TO authenticated, service_role;
