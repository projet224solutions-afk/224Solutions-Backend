-- 20260722140000_validate_stock_purchase_received.sql
-- CHANTIER 2.1 — L'achat MANUEL aligne enfin les manquants sur le modèle B2B (par LIGNE).
--
-- Avant : validate_stock_purchase intégrait le stock à 100 % du COMMANDÉ et dépensait le total
-- commandé ; les manquants saisis dans MissingProductsVerificationDialog (par catégorie, sans
-- product_id) n'étaient JAMAIS envoyés au backend = note morte.
--
-- Après : chaque ligne porte une quantité REÇUE (`received_quantity`, défaut = commandée -> zéro
-- régression). Le stock entre à hauteur du REÇU, la dépense/dette = MONTANT REÇU (jamais commandé),
-- et un rapport de réception par ligne (commandé/reçu/écart/raison/notes) est tracé + consultable
-- sur l'achat (stock_purchases.reception_report). Pas de reliquat automatique côté fournisseur
-- (l'achat manuel n'a aucune réservation fournisseur, contrairement au B2B) : l'écart est une note tracée.
-- Signature INCHANGÉE (received_quantity lu depuis p_items) -> la route existante reste compatible.

CREATE OR REPLACE FUNCTION public.validate_stock_purchase(
  p_purchase_id uuid, p_vendor_id uuid, p_items jsonb, p_purchase_number text, p_total_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid; v_expense_id uuid; v_item jsonb;
  v_supplier_ids uuid[]; v_supplier_names text; v_desc text; v_purchase record;
  v_debt_supplier uuid; v_debt_id uuid; v_pmp jsonb;
  v_ordered int; v_recv int; v_missing int; v_price numeric;
  v_received_total numeric := 0; v_has_missing boolean := false; v_report jsonb := '[]'::jsonb;
BEGIN
  IF p_purchase_id IS NULL OR p_vendor_id IS NULL OR p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Paramètres manquants');
  END IF;

  SELECT user_id INTO v_user_id FROM public.vendors WHERE id = p_vendor_id;
  IF v_user_id IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Vendor non trouvé'); END IF;

  SELECT id, status, is_locked, expense_id, payment_mode, supplier_id, due_date, minimum_installment
  INTO v_purchase FROM public.stock_purchases WHERE id = p_purchase_id AND vendor_id = p_vendor_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Achat introuvable pour ce vendeur'); END IF;
  IF v_purchase.status = 'validated' OR COALESCE(v_purchase.is_locked, false) = true THEN
    RETURN jsonb_build_object('success', true, 'already_validated', true, 'expense_id', v_purchase.expense_id, 'message', 'Achat déjà validé');
  END IF;

  SELECT array_agg(DISTINCT (e->>'supplier_id')::uuid) INTO v_supplier_ids
  FROM jsonb_array_elements(p_items) e WHERE NULLIF(e->>'supplier_id', '') IS NOT NULL;

  v_desc := 'Achat de stock - ' || p_purchase_number;
  IF v_supplier_ids IS NOT NULL AND array_length(v_supplier_ids, 1) > 0 THEN
    SELECT string_agg(name, ', ') INTO v_supplier_names FROM public.vendor_suppliers WHERE id = ANY(v_supplier_ids);
    IF v_supplier_names IS NOT NULL THEN v_desc := v_desc || ' - Fournisseur(s): ' || v_supplier_names; END IF;
  END IF;

  -- ── 0) RÉCEPTION PAR LIGNE : quantité REÇUE (défaut = commandée), écart, rapport, total reçu ──
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_ordered := COALESCE(NULLIF(v_item->>'quantity', '')::numeric, 0)::int;
    v_recv    := COALESCE(NULLIF(v_item->>'received_quantity', '')::numeric, v_ordered)::int;  -- défaut = commandé
    IF v_recv < 0 THEN v_recv := 0; END IF;
    IF v_recv > v_ordered THEN v_recv := v_ordered; END IF;   -- jamais plus que commandé
    v_missing := v_ordered - v_recv;
    IF v_missing > 0 THEN v_has_missing := true; END IF;
    v_price := COALESCE(NULLIF(v_item->>'purchase_price', '')::numeric, 0);
    v_received_total := v_received_total + (v_recv * v_price);
    v_report := v_report || jsonb_build_object(
      'product_id',   NULLIF(v_item->>'product_id', ''),
      'product_name', v_item->>'product_name',
      'ordered',      v_ordered,
      'received',     v_recv,
      'missing',      v_missing,
      'reason',       NULLIF(v_item->>'missing_reason', ''),
      'notes',        NULLIF(v_item->>'missing_notes', ''),
      'supplier_id',  NULLIF(v_item->>'supplier_id', '')
    );
  END LOOP;

  -- ── 1) Dépense / Dette = MONTANT REÇU (jamais le commandé) ──
  IF COALESCE(v_purchase.payment_mode, 'cash') = 'credit' THEN
    v_debt_supplier := COALESCE(v_purchase.supplier_id, v_supplier_ids[1]);
    INSERT INTO public.supplier_debts (vendor_id, supplier_id, purchase_id, total_amount, paid_amount,
      minimum_installment, due_date, status)
    VALUES (p_vendor_id, v_debt_supplier, p_purchase_id, v_received_total, 0,
      COALESCE(v_purchase.minimum_installment, 0), v_purchase.due_date, 'in_progress')
    RETURNING id INTO v_debt_id;
    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date, payment_method, status, is_locked, purchase_reference)
    VALUES (v_user_id, v_desc || ' (à crédit)', v_received_total, CURRENT_DATE, 'credit', 'pending', true, p_purchase_number)
    RETURNING id INTO v_expense_id;
  ELSE
    INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date, payment_method, status, is_locked, purchase_reference)
    VALUES (v_user_id, v_desc, v_received_total, CURRENT_DATE, 'cash', 'paid', true, p_purchase_number)
    RETURNING id INTO v_expense_id;
  END IF;

  -- ── 2) Stock en PMP + prix de vente (scopé vendeur) — à hauteur du REÇU ──
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF NULLIF(v_item->>'product_id', '') IS NOT NULL THEN
      v_ordered := COALESCE(NULLIF(v_item->>'quantity', '')::numeric, 0)::int;
      v_recv    := COALESCE(NULLIF(v_item->>'received_quantity', '')::numeric, v_ordered)::int;
      IF v_recv < 0 THEN v_recv := 0; END IF;
      IF v_recv > v_ordered THEN v_recv := v_ordered; END IF;
      IF v_recv > 0 THEN
        v_pmp := public.apply_purchase_to_product_stock(
          (v_item->>'product_id')::uuid, p_vendor_id, v_recv,
          COALESCE(NULLIF(v_item->>'purchase_price', '')::numeric, 0));
        -- Produit d'un autre vendeur / introuvable → ligne ignorée (comportement historique).
      END IF;
      UPDATE public.products SET
        price = COALESCE(NULLIF(v_item->>'selling_price', '')::numeric, price)
      WHERE id = (v_item->>'product_id')::uuid AND vendor_id = p_vendor_id;
    END IF;
  END LOOP;

  -- ── 3) fournisseurs marqués validés ──
  IF v_supplier_ids IS NOT NULL AND array_length(v_supplier_ids, 1) > 0 THEN
    UPDATE public.vendor_suppliers SET has_validated_purchases = true WHERE id = ANY(v_supplier_ids) AND vendor_id = p_vendor_id;
  END IF;

  -- ── 4) valider + verrouiller + TRACER la réception (rapport par ligne, consultable) ──
  UPDATE public.stock_purchases SET
    status = 'validated', validated_at = NOW(), expense_id = v_expense_id, is_locked = true,
    received_at = NOW(),
    reception_report = jsonb_build_object(
      'lines', v_report, 'has_missing', v_has_missing,
      'received_total', v_received_total, 'ordered_total', p_total_amount,
      'verified_by', v_user_id, 'verified_at', NOW())
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object('success', true, 'expense_id', v_expense_id, 'debt_id', v_debt_id,
    'mode', COALESCE(v_purchase.payment_mode, 'cash'),
    'has_missing', v_has_missing, 'received_total', v_received_total,
    'message', 'Achat ' || p_purchase_number || ' validé'
      || CASE WHEN v_has_missing THEN ' (manquants tracés)' ELSE '' END
      || CASE WHEN v_debt_id IS NOT NULL THEN ' (dette créée)' ELSE '' END);
END;
$function$;
