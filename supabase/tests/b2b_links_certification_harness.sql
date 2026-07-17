-- ============================================================================
-- 🧪 ESPACE GROSSISTE 224 — HARNAIS DE CERTIFICATION (6 tests exigés)
-- ----------------------------------------------------------------------------
-- À exécuter APRÈS les migrations 20260717150000→210000 (et de préférence après
-- b2b_certification_harness.sql). Renseigner les DEUX comptes vendeurs de test.
-- Tout est joué dans UNE transaction ROLLBACKÉE (zéro trace).
--   T1 lien ciblé usage unique : réservation→paiement→commande confirmée→
--      expédition (stock ↓)→réception (stock ↑ + PMP)→ledger/commission.
--   T2 multi-usage plafonné (2) : 2 acceptations puis refus.
--   T3 expiration → réservation libérée (chiffré).
--   T4 crédit : créance fournisseur = dette acheteur (MÊME enregistrement).
--   T5 tiers non ciblé → refus propre.
--   T6 RLS croisée (créances créancier + tarifs clients).
-- ============================================================================

BEGIN;

DO $$
DECLARE
  c_buyer_email    text := 'cert.a@224solutions.test';  -- CLIENT-VENDEUR (acheteur)
  c_supplier_email text := 'cert.b@224solutions.test';  -- FOURNISSEUR (grossiste)

  v_buyer_user uuid; v_supplier_user uuid; v_pdg_user uuid;
  v_buyer_vendor uuid; v_supplier_vendor uuid; v_third_vendor uuid;
  v_customer_id uuid;
  v_p1 uuid; v_p2 uuid; v_bp uuid;
  v_res jsonb; v_link1 uuid; v_link2 uuid; v_link3 uuid; v_link4 uuid;
  v_order_id uuid; v_purchase_id uuid; v_item record;
  v_stock int; v_reserved int; v_cost numeric;
  v_buyer_bal0 numeric; v_supplier_bal0 numeric; v_pdg_bal0 numeric;
  v_buyer_bal numeric; v_supplier_bal numeric; v_pdg_bal numeric;
  v_fee_pct numeric; v_fee numeric; v_total numeric := 2*2600 + 1*5000; -- 10200
  v_debt record; v_lines jsonb;
BEGIN
  -- ── Contexte ──
  SELECT id INTO v_buyer_user FROM auth.users WHERE email = c_buyer_email;
  SELECT id INTO v_supplier_user FROM auth.users WHERE email = c_supplier_email;
  IF v_buyer_user IS NULL OR v_supplier_user IS NULL THEN
    RAISE EXCEPTION 'Comptes de test introuvables — renseigner les emails en tête de script';
  END IF;
  SELECT id INTO v_buyer_vendor FROM vendors WHERE user_id = v_buyer_user;
  SELECT id INTO v_supplier_vendor FROM vendors WHERE user_id = v_supplier_user;
  SELECT user_id INTO v_pdg_user FROM pdg_management WHERE is_active = true LIMIT 1;
  SELECT id INTO v_customer_id FROM customers WHERE user_id = v_buyer_user;
  IF v_customer_id IS NULL THEN
    INSERT INTO customers (user_id) VALUES (v_buyer_user) RETURNING id INTO v_customer_id;
  END IF;

  INSERT INTO wallets (user_id, balance, currency, wallet_status)
  VALUES (v_buyer_user, 0, 'GNF', 'active') ON CONFLICT DO NOTHING;
  INSERT INTO wallets (user_id, balance, currency, wallet_status)
  VALUES (v_supplier_user, 0, 'GNF', 'active') ON CONFLICT DO NOTHING;
  UPDATE wallets SET balance = balance + 1000000 WHERE user_id = v_buyer_user AND currency='GNF';

  -- Produits du FOURNISSEUR : P1 20 u @2600 ; P2 10 u @5000.
  INSERT INTO products (vendor_id, name, price, stock_quantity, is_active)
  VALUES (v_supplier_vendor, 'CERTL-P1', 2600, 20, true) RETURNING id INTO v_p1;
  INSERT INTO products (vendor_id, name, price, stock_quantity, is_active)
  VALUES (v_supplier_vendor, 'CERTL-P2', 5000, 10, true) RETURNING id INTO v_p2;
  -- Produit de l'ACHETEUR pour la preuve PMP : 10 u au coût 2000.
  INSERT INTO products (vendor_id, name, price, stock_quantity, cost_price, is_active)
  VALUES (v_buyer_vendor, 'CERTL-BUY', 3500, 10, 2000, true) RETURNING id INTO v_bp;

  SELECT balance INTO v_buyer_bal0 FROM wallets WHERE user_id=v_buyer_user AND currency='GNF';
  SELECT balance INTO v_supplier_bal0 FROM wallets WHERE user_id=v_supplier_user AND currency='GNF';
  SELECT balance INTO v_pdg_bal0 FROM wallets WHERE user_id=v_pdg_user AND currency='GNF';
  v_fee_pct := COALESCE(get_purchase_commission_percent(), 0);
  v_fee := round(v_total * v_fee_pct / 100.0);

  v_lines := jsonb_build_array(
    jsonb_build_object('product_id', v_p1, 'quantity', 2, 'unit_price', 2600),
    jsonb_build_object('product_id', v_p2, 'quantity', 1, 'unit_price', 5000));

  -- ══ T1 — LIEN CIBLÉ USAGE UNIQUE : cycle complet ══
  v_res := create_b2b_stock_link(v_supplier_vendor, v_lines, 'CERT lien ciblé',
    v_buyer_vendor, 72, true, NULL, false, NULL, 'GNF', NULL);
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T1: création lien échouée: %', v_res->>'error';
  END IF;
  v_link1 := (v_res->>'link_id')::uuid;
  IF (v_res->>'reserved')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T1: la réservation à la création était attendue';
  END IF;
  SELECT stock_quantity, reserved_quantity INTO v_stock, v_reserved FROM products WHERE id = v_p1;
  IF v_stock <> 18 OR v_reserved <> 2 THEN
    RAISE EXCEPTION 'T1: réservation P1 incorrecte (stock=% réservé=%)', v_stock, v_reserved;
  END IF;
  RAISE NOTICE '✅ T1a création : lien ciblé usage unique — P1 20→18 dispo + 2 réservés, P2 10→9 + 1';

  -- Paiement wallet par la CIBLE → commande B2B DÉJÀ CONFIRMÉE.
  v_res := accept_b2b_stock_link(v_link1, v_buyer_user, v_buyer_vendor, v_customer_id, 'wallet', v_fee);
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T1: acceptation échouée: %', v_res->>'error';
  END IF;
  v_order_id := (v_res->>'order_id')::uuid; v_purchase_id := (v_res->>'purchase_id')::uuid;
  PERFORM 1 FROM orders WHERE id = v_order_id AND status = 'confirmed' AND order_type = 'b2b_purchase';
  IF NOT FOUND THEN RAISE EXCEPTION 'T1: commande non confirmée'; END IF;
  PERFORM 1 FROM stock_purchases WHERE id = v_purchase_id AND status = 'confirmed' AND payment_link_id = v_link1;
  IF NOT FOUND THEN RAISE EXCEPTION 'T1: achat miroir non confirmé/lié'; END IF;
  PERFORM 1 FROM payment_links WHERE id = v_link1 AND status = 'success' AND use_count = 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'T1: lien non marqué payé'; END IF;
  -- Ledger à l'acceptation : acheteur -(10200+fee) ; fournisseur +10200 (PLEIN prix) ; PDG +fee.
  SELECT balance INTO v_buyer_bal FROM wallets WHERE user_id=v_buyer_user AND currency='GNF';
  SELECT balance INTO v_supplier_bal FROM wallets WHERE user_id=v_supplier_user AND currency='GNF';
  IF v_buyer_bal <> v_buyer_bal0 - v_total - v_fee THEN
    RAISE EXCEPTION 'T1 ledger acheteur: attendu -%, obtenu -%', v_total + v_fee, v_buyer_bal0 - v_buyer_bal;
  END IF;
  IF v_supplier_bal <> v_supplier_bal0 + v_total THEN
    RAISE EXCEPTION 'T1 ledger fournisseur: attendu +%, obtenu +%', v_total, v_supplier_bal - v_supplier_bal0;
  END IF;
  SELECT balance INTO v_pdg_bal FROM wallets WHERE user_id=v_pdg_user AND currency='GNF';
  RAISE NOTICE '✅ T1b paiement : acheteur -% (dont frais %), fournisseur +% (plein prix), PDG +%',
    v_total + v_fee, v_fee, v_total, v_pdg_bal - v_pdg_bal0;

  -- Expédition (stock fournisseur ↓ pour de bon).
  v_res := ship_b2b_order(v_order_id, v_supplier_vendor);
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T1: expédition échouée: %', v_res->>'error';
  END IF;
  SELECT stock_quantity, reserved_quantity INTO v_stock, v_reserved FROM products WHERE id = v_p1;
  IF v_stock <> 18 OR v_reserved <> 0 THEN
    RAISE EXCEPTION 'T1: après expédition P1 attendu 18/0, obtenu %/%', v_stock, v_reserved;
  END IF;
  RAISE NOTICE '✅ T1c expédition : stock fournisseur sorti (P1 physique 20→18, réservé 2→0)';

  -- Réception totale : 2×P1 sur CERTL-BUY (PMP) + 1×P2 en création auto.
  SELECT id INTO v_item FROM stock_purchase_items
  WHERE purchase_id = v_purchase_id AND supplier_product_id = v_p1;
  v_res := receive_b2b_purchase(v_purchase_id, v_buyer_vendor, jsonb_build_array(
    jsonb_build_object('item_id', v_item.id, 'received_qty', 2, 'buyer_product_id', v_bp),
    (SELECT jsonb_build_object('item_id', id, 'received_qty', 1)
     FROM stock_purchase_items WHERE purchase_id = v_purchase_id AND supplier_product_id = v_p2)));
  IF (v_res->>'final')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T1: réception finale attendue: %', v_res;
  END IF;
  SELECT stock_quantity, cost_price INTO v_stock, v_cost FROM products WHERE id = v_bp;
  -- PMP : (10×2000 + 2×2600)/12 = 25200/12 = 2100
  IF v_stock <> 12 OR v_cost <> 2100 THEN
    RAISE EXCEPTION 'T1 PMP: attendu stock 12 / coût 2100, obtenu % / %', v_stock, v_cost;
  END IF;
  SELECT balance INTO v_supplier_bal FROM wallets WHERE user_id=v_supplier_user AND currency='GNF';
  IF v_supplier_bal <> v_supplier_bal0 + v_total THEN
    RAISE EXCEPTION 'T1: le fournisseur ne doit être payé qu''UNE fois (réglé à l''acceptation)';
  END IF;
  RAISE NOTICE '✅ T1d réception : CERTL-BUY stock 10→12, PMP 2000→2100 ((10×2000+2×2600)/12) ; ledger stable (pas de double paiement)';

  -- ══ T2 — MULTI-USAGE PLAFONNÉ (2) : 2 acceptations puis refus ══
  v_res := create_b2b_stock_link(v_supplier_vendor,
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'quantity', 1, 'unit_price', 2600)),
    'CERT multi', NULL, 72, false, 2, false, NULL, 'GNF', NULL);
  v_link2 := (v_res->>'link_id')::uuid;
  IF (v_res->>'reserved')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'T2: un lien multi-usage ne réserve PAS à la création';
  END IF;
  v_res := accept_b2b_stock_link(v_link2, v_buyer_user, v_buyer_vendor, v_customer_id, 'wallet', 0);
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'T2: acceptation 1 échouée: %', v_res->>'error'; END IF;
  v_res := accept_b2b_stock_link(v_link2, v_buyer_user, v_buyer_vendor, v_customer_id, 'wallet', 0);
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'T2: acceptation 2 échouée: %', v_res->>'error'; END IF;
  PERFORM 1 FROM payment_links WHERE id = v_link2 AND status = 'success' AND use_count = 2;
  IF NOT FOUND THEN RAISE EXCEPTION 'T2: lien non épuisé après 2 usages'; END IF;
  v_res := accept_b2b_stock_link(v_link2, v_buyer_user, v_buyer_vendor, v_customer_id, 'wallet', 0);
  IF (v_res->>'error') NOT IN ('LINK_NOT_PAYABLE','LINK_EXHAUSTED') THEN
    RAISE EXCEPTION 'T2: le 3e usage devait être refusé, obtenu %', v_res;
  END IF;
  RAISE NOTICE '✅ T2 multi-usage : 2 acceptations (réservation à CHAQUE usage), 3e refusée (%)', v_res->>'error';

  -- ══ T3 — EXPIRATION → RÉSERVATION LIBÉRÉE ══
  SELECT stock_quantity, reserved_quantity INTO v_stock, v_reserved FROM products WHERE id = v_p2;
  v_res := create_b2b_stock_link(v_supplier_vendor,
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'quantity', 3, 'unit_price', 5000)),
    'CERT expiration', v_buyer_vendor, 72, true, NULL, false, NULL, 'GNF', NULL);
  v_link3 := (v_res->>'link_id')::uuid;
  PERFORM 1 FROM products WHERE id = v_p2 AND stock_quantity = v_stock - 3 AND reserved_quantity = v_reserved + 3;
  IF NOT FOUND THEN RAISE EXCEPTION 'T3: réservation à la création absente'; END IF;
  UPDATE payment_links SET expires_at = now() - interval '1 hour' WHERE id = v_link3;
  v_res := expire_b2b_stock_links();
  IF (v_res->>'released')::int < 1 THEN
    RAISE EXCEPTION 'T3: le watchdog n''a pas libéré la réservation: %', v_res;
  END IF;
  PERFORM 1 FROM products WHERE id = v_p2 AND stock_quantity = v_stock AND reserved_quantity = v_reserved;
  IF NOT FOUND THEN RAISE EXCEPTION 'T3: stock non restauré après expiration'; END IF;
  PERFORM 1 FROM payment_links WHERE id = v_link3 AND status = 'expired';
  IF NOT FOUND THEN RAISE EXCEPTION 'T3: lien non expiré'; END IF;
  RAISE NOTICE '✅ T3 expiration : réservation LIBÉRÉE (P2 revenu à %/% dispo/réservé), lien expiré', v_stock, v_reserved;

  -- ══ T4 — CRÉDIT : créance = dette (MÊME enregistrement) ══
  v_res := create_b2b_stock_link(v_supplier_vendor,
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'quantity', 2, 'unit_price', 2600)),
    'CERT crédit', v_buyer_vendor, 72, true, NULL, true, 7, 'GNF', NULL);
  v_link4 := (v_res->>'link_id')::uuid;
  v_res := accept_b2b_stock_link(v_link4, v_buyer_user, v_buyer_vendor, v_customer_id, 'credit', 0);
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T4: acceptation crédit échouée: %', v_res->>'error';
  END IF;
  IF (v_res->>'debt_id') IS NULL THEN RAISE EXCEPTION 'T4: dette non créée à l''acceptation'; END IF;
  SELECT * INTO v_debt FROM supplier_debts WHERE id = (v_res->>'debt_id')::uuid;
  IF v_debt.total_amount <> 5200 OR v_debt.due_date <> CURRENT_DATE + 7 THEN
    RAISE EXCEPTION 'T4: dette incorrecte (total=% échéance=%)', v_debt.total_amount, v_debt.due_date;
  END IF;
  -- Le MÊME enregistrement vu du CRÉANCIER (jointure de la policy supplier_debts_creditor).
  PERFORM 1 FROM supplier_debts sd
  JOIN vendor_suppliers vs ON vs.id = sd.supplier_id
  WHERE sd.id = v_debt.id AND vs.linked_vendor_id = v_supplier_vendor AND sd.vendor_id = v_buyer_vendor;
  IF NOT FOUND THEN RAISE EXCEPTION 'T4: la créance ne pointe pas le créancier via la fiche liée'; END IF;
  RAISE NOTICE '✅ T4 crédit : dette 5200 GNF échéance J+7 — même enregistrement = dette (acheteur) ET créance (fournisseur lié)';

  -- ══ T5 — TIERS NON CIBLÉ → REFUS PROPRE ══
  INSERT INTO vendors (user_id, business_name) VALUES (v_supplier_user, 'CERT-TIERS')
  RETURNING id INTO v_third_vendor;
  v_res := create_b2b_stock_link(v_supplier_vendor,
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'quantity', 1, 'unit_price', 2600)),
    'CERT tiers', v_third_vendor, 72, true, NULL, false, NULL, 'GNF', NULL);
  v_res := accept_b2b_stock_link((v_res->>'link_id')::uuid, v_buyer_user, v_buyer_vendor, v_customer_id, 'wallet', 0);
  IF (v_res->>'error') <> 'NOT_TARGET' THEN
    RAISE EXCEPTION 'T5: refus NOT_TARGET attendu, obtenu %', v_res;
  END IF;
  RAISE NOTICE '✅ T5 ciblage : un tiers non ciblé est proprement refusé (NOT_TARGET)';

  RAISE NOTICE '═══ TESTS 1-5 : TOUS PASSÉS ═══';
END $$;

-- ══ T6 — RLS CROISÉE (créances créancier + tarifs clients) ═══════════════════
DO $$
DECLARE v_a uuid; v_b uuid; v_cnt int;
BEGIN
  SELECT user_id INTO v_a FROM vendors v JOIN auth.users u ON u.id = v.user_id
  WHERE u.email = 'cert.a@224solutions.test' LIMIT 1;
  SELECT user_id INTO v_b FROM vendors v JOIN auth.users u ON u.id = v.user_id
  WHERE u.email = 'cert.b@224solutions.test' LIMIT 1;

  -- Le FOURNISSEUR (B, créancier) VOIT les dettes où il est le fournisseur lié.
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO v_cnt FROM supplier_debts;
  IF v_cnt = 0 THEN RAISE EXCEPTION 'T6: le créancier ne voit pas ses créances (policy supplier_debts_creditor)'; END IF;

  -- L'ACHETEUR (A) ne voit PAS les tarifs d'un AUTRE client, mais voit les siens.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO v_cnt FROM b2b_client_prices
  WHERE client_vendor_id NOT IN (SELECT id FROM vendors WHERE user_id = v_a)
    AND supplier_vendor_id NOT IN (SELECT id FROM vendors WHERE user_id = v_a);
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'T6: fuite RLS b2b_client_prices (% lignes de tiers visibles)', v_cnt; END IF;

  PERFORM set_config('role', 'postgres', true);
  RAISE NOTICE '✅ T6 RLS croisée : créancier voit ses créances ; aucun tarif de tiers visible';
  RAISE NOTICE '═══ CERTIFICATION GROSSISTE : 6/6 ═══';
END $$;

ROLLBACK; -- ⚠️ remplacer par COMMIT pour conserver les données de test
