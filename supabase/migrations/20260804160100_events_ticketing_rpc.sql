-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE ÉVÉNEMENTS — RPC atomiques fail-closed (génération prépayée, achat, scan, retrait, archive)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — appliqué en prod via l'API Management (même canal que le déploiement).
-- Briques RÉUTILISÉES (aucun chemin d'argent parallèle) :
--   • wallet_debit_internal(user, montant, desc, clé)   → débit atomique idempotent (wallet standard)
--   • record_pdg_revenue(...)                            → journalise revenus_pdg → coffre PDG (trigger)
--   • ledger organizer_withdrawals + machine à états     → même modèle que le verrou retraits standard
-- Le portefeuille organisateur est TEMPORAIRE et RETRAIT-ONLY : crédité UNIQUEMENT par buy_event_ticket,
-- débité UNIQUEMENT par withdraw_organizer_wallet (CHECK balance >= 0 → jamais négatif).

-- ── Helper : l'appelant est-il le prestataire de l'événement ? ───────────────
CREATE OR REPLACE FUNCTION public.event_is_provider(p_event_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM events e WHERE e.id = p_event_id AND e.provider_user_id = auth.uid());
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1) RATTACHER l'organisateur (compte créé côté backend Node via auth admin — voir rapport).
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.attach_event_organizer(p_event_id uuid, p_organizer_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF v_e.provider_user_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_PROVIDER');
  END IF;
  IF v_e.status IN ('archived','cancelled') THEN
    RETURN jsonb_build_object('success', false, 'error', 'EVENT_CLOSED');
  END IF;
  UPDATE events SET organizer_user_id = p_organizer_user_id WHERE id = p_event_id;
  -- Portefeuille temporaire de l'événement (retrait-only), créé dès le rattachement.
  INSERT INTO organizer_wallets (organizer_user_id, event_id)
  VALUES (p_organizer_user_id, p_event_id)
  ON CONFLICT (event_id) DO UPDATE SET organizer_user_id = EXCLUDED.organizer_user_id;
  RETURN jsonb_build_object('success', true);
END; $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2) GÉNÉRATION PRÉPAYÉE — le point clé du modèle : commission PDG payée AVANT, sinon 0 ticket.
--    N × X débité du wallet PRESTATAIRE (fail-closed : le débit lève si solde insuffisant →
--    la transaction entière est annulée → AUCUN ticket). Commission NON REMBOURSABLE.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.generate_tickets_prepaid(
  p_event_id uuid, p_ticket_type_id uuid, p_quantity integer, p_idempotency text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_e events%ROWTYPE;
  v_tt event_ticket_types%ROWTYPE;
  v_actor uuid := auth.uid();
  v_x numeric;              -- commission PDG par ticket (pdg_settings)
  v_total numeric;
  v_batch uuid;
  i integer;
BEGIN
  IF v_actor IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED'); END IF;
  IF COALESCE(p_quantity, 0) <= 0 OR p_quantity > 100000 THEN
    RETURN jsonb_build_object('success', false, 'error', 'BAD_QUANTITY');
  END IF;

  -- Idempotence : un rejeu (même clé) ne régénère PAS et ne redébite pas.
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

  -- Commission unitaire configurable (défaut 500 GNF).
  SELECT COALESCE((setting_value->>'value')::numeric, 500) INTO v_x
  FROM pdg_settings WHERE setting_key = 'event_ticket_commission_gnf';
  v_x := COALESCE(v_x, 500);
  v_total := p_quantity * v_x;

  -- PAIEMENT D'ABORD : débit wallet prestataire (lève si insuffisant → rollback → 0 ticket).
  IF v_total > 0 THEN
    PERFORM public.wallet_debit_internal(
      v_actor, v_total,
      'Commission billetterie : ' || p_quantity || ' tickets × ' || v_x || ' GNF — ' || v_e.title,
      'event-batch-' || p_idempotency);
    -- Revenu plateforme → coffre PDG (canal officiel revenus_pdg, NON REMBOURSABLE).
    -- percentage_applied = 0 : commission FIXE par ticket (pas un pourcentage).
    PERFORM public.record_pdg_revenue(
      'event_ticket_commission', v_total, 0, NULL, v_actor, NULL,
      jsonb_build_object('event_id', p_event_id, 'quantity', p_quantity,
                         'commission_per_ticket', v_x, 'non_refundable', true), 'GNF');
  END IF;

  -- SEULEMENT APRÈS le paiement : génération des N tickets (QR = jeton aléatoire 48 hex, non devinable).
  INSERT INTO event_ticket_batches (event_id, ticket_type_id, quantity, commission_per_ticket,
                                    total_commission_paid, payment_ref)
  VALUES (p_event_id, p_ticket_type_id, p_quantity, v_x, v_total, 'event-batch-' || p_idempotency)
  RETURNING id INTO v_batch;

  FOR i IN 1..p_quantity LOOP
    INSERT INTO event_tickets (event_id, ticket_type_id, batch_id, qr_code)
    VALUES (p_event_id, p_ticket_type_id, v_batch, encode(extensions.gen_random_bytes(24), 'hex'));
  END LOOP;

  UPDATE event_ticket_types SET quantity_total = quantity_total + p_quantity WHERE id = p_ticket_type_id;
  -- L'événement devient vendable (modération légère : actif = tickets générés + payés).
  UPDATE events SET status = 'active' WHERE id = p_event_id AND status = 'draft';

  RETURN jsonb_build_object('success', true, 'batch_id', v_batch, 'tickets_generated', p_quantity,
                            'commission_per_ticket', v_x, 'total_commission_paid', v_total);
END; $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3) ACHAT (rail WALLET — le rail agrégateur appellera la MÊME fonction à la confirmation webhook,
--    via service_role avec p_buyer explicite ; jamais de crédit avant confirmation).
--    Atomique : débit acheteur → crédit portefeuille organisateur → assignation d'UN ticket libre.
-- ═══════════════════════════════════════════════════════════════════════════════
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
BEGIN
  IF v_buyer IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED'); END IF;
  -- p_buyer explicite réservé au backend (rail agrégateur service_role) — jamais un client pour autrui.
  IF p_buyer IS NOT NULL AND auth.uid() IS NOT NULL AND p_buyer IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN');
  END IF;

  -- Idempotence achat : rejeu → renvoie le MÊME billet (pas de double vente ni double débit).
  SELECT * INTO v_ticket FROM event_tickets WHERE purchase_ref = v_ref;
  IF FOUND THEN
    RETURN jsonb_build_object('success', true, 'already', true, 'ticket_id', v_ticket.id, 'qr_code', v_ticket.qr_code);
  END IF;

  SELECT * INTO v_tt FROM event_ticket_types WHERE id = p_ticket_type_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_TYPE_NOT_FOUND'); END IF;
  SELECT * INTO v_e FROM events WHERE id = v_tt.event_id;
  IF v_e.status <> 'active' THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_ACTIVE'); END IF;
  IF v_e.organizer_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NO_ORGANIZER'); END IF;

  -- Un ticket LIBRE du stock prépayé (le stock affiché = stock réel : impossible de survendre).
  SELECT * INTO v_ticket FROM event_tickets
   WHERE ticket_type_id = p_ticket_type_id AND buyer_user_id IS NULL AND status = 'valid'
   ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'SOLD_OUT'); END IF;

  -- Débit acheteur (wallet standard, atomique, lève si insuffisant → rollback complet).
  IF v_tt.price > 0 THEN
    PERFORM public.wallet_debit_internal(
      v_buyer, v_tt.price, 'Billet ' || v_tt.name || ' — ' || v_e.title, v_ref);
  END IF;

  -- Crédit du PORTEFEUILLE TEMPORAIRE organisateur (retrait-only).
  UPDATE organizer_wallets SET balance = balance + v_tt.price, updated_at = now()
   WHERE event_id = v_e.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORGANIZER_WALLET_MISSING'; END IF;

  -- Assignation du billet + compteur vendu.
  UPDATE event_tickets SET buyer_user_id = v_buyer, purchase_ref = v_ref WHERE id = v_ticket.id;
  UPDATE event_ticket_types SET quantity_sold = quantity_sold + 1 WHERE id = p_ticket_type_id;

  -- Notification in-app cliquable → billet (lien privé /billet/:token).
  BEGIN
    INSERT INTO notifications (user_id, title, message, type, metadata)
    VALUES (v_buyer, '🎫 Votre billet est prêt',
            v_e.title || ' — ' || v_tt.name || '. Présentez le QR à l''entrée.',
            'event_ticket', jsonb_build_object('ticket_id', v_ticket.id, 'link', '/billet/' || v_ticket.qr_code));
  EXCEPTION WHEN OTHERS THEN NULL; END;

  RETURN jsonb_build_object('success', true, 'ticket_id', v_ticket.id, 'qr_code', v_ticket.qr_code,
                            'price', v_tt.price);
END; $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4) SCAN — anti double-entrée : un QR 'used' est REFUSÉ. Vérifié serveur (le QR = jeton en base).
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.scan_event_ticket(p_qr_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_t event_tickets%ROWTYPE;
  v_e events%ROWTYPE;
  v_actor uuid := auth.uid();
BEGIN
  IF v_actor IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED'); END IF;
  SELECT * INTO v_t FROM event_tickets WHERE qr_code = p_qr_code FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'TICKET_NOT_FOUND'); END IF;
  SELECT * INTO v_e FROM events WHERE id = v_t.event_id;
  -- Seuls l'organisateur et le prestataire scannent.
  IF v_actor NOT IN (v_e.organizer_user_id, v_e.provider_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  IF v_t.status = 'used' THEN
    RETURN jsonb_build_object('success', false, 'error', 'ALREADY_USED', 'scanned_at', v_t.scanned_at);
  END IF;
  IF v_t.status <> 'valid' OR v_t.buyer_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TICKET_INVALID');
  END IF;
  UPDATE event_tickets SET status = 'used', scanned_at = now(), scanned_by = v_actor WHERE id = v_t.id;
  RETURN jsonb_build_object('success', true, 'ticket_id', v_t.id, 'used_at', now());
END; $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5) RETRAIT organisateur — SEULE action possible sur le portefeuille temporaire.
--    Fail-closed : montant ≤ solde (CHECK balance >= 0 en dernier rempart), idempotent (clé unique),
--    ledger organizer_withdrawals en 'pending' → payout exécuté par l'infra retraits backend.
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.withdraw_organizer_wallet(
  p_event_id uuid, p_amount numeric, p_method text, p_destination text, p_idempotency text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_w organizer_wallets%ROWTYPE;
  v_actor uuid := auth.uid();
  v_id uuid;
BEGIN
  IF v_actor IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED'); END IF;
  IF COALESCE(p_amount, 0) <= 0 THEN RETURN jsonb_build_object('success', false, 'error', 'BAD_AMOUNT'); END IF;
  IF p_method NOT IN ('orange_money','card','bank_transfer') THEN
    RETURN jsonb_build_object('success', false, 'error', 'BAD_METHOD');
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
  INSERT INTO organizer_withdrawals (organizer_wallet_id, organizer_user_id, amount, method, destination,
                                     status, idempotency_key)
  VALUES (v_w.id, v_actor, p_amount, p_method, p_destination, 'pending', p_idempotency)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'withdrawal_id', v_id, 'new_balance', v_w.balance - p_amount);
END; $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6) ARCHIVAGE — soft : événement archivé + compte organisateur désactivé (JAMAIS supprimé).
--    Historique financier + billets conservés (traçabilité/compta).
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.archive_event(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e events%ROWTYPE;
BEGIN
  SELECT * INTO v_e FROM events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'EVENT_NOT_FOUND'); END IF;
  IF v_e.provider_user_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_PROVIDER');
  END IF;
  UPDATE events SET status = 'archived' WHERE id = p_event_id;
  -- Désactivation SOFT du compte organisateur (plus de connexion applicative ; données conservées).
  IF v_e.organizer_user_id IS NOT NULL THEN
    UPDATE profiles SET is_active = false WHERE id = v_e.organizer_user_id;
  END IF;
  RETURN jsonb_build_object('success', true);
END; $$;

-- ── Grants : SECURITY DEFINER exposés via PostgREST → verrouiller. ───────────
REVOKE ALL ON FUNCTION public.event_is_provider(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.attach_event_organizer(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.generate_tickets_prepaid(uuid, uuid, integer, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.buy_event_ticket(uuid, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.scan_event_ticket(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.withdraw_organizer_wallet(uuid, numeric, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.archive_event(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.event_is_provider(uuid)                                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.attach_event_organizer(uuid, uuid)                      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.generate_tickets_prepaid(uuid, uuid, integer, text)     TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.buy_event_ticket(uuid, text, uuid)                      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.scan_event_ticket(text)                                 TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.withdraw_organizer_wallet(uuid, numeric, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.archive_event(uuid)                                     TO authenticated, service_role;
