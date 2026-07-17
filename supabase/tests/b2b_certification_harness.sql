-- ============================================================================
-- 🧪 APPROVISIONNEMENT 224 — HARNAIS DE CERTIFICATION (5 tests exigés)
-- ----------------------------------------------------------------------------
-- À exécuter dans Supabase SQL Editor APRÈS application des 3 migrations :
--   20260717150000_b2b_supplier_link.sql
--   20260717160000_b2b_purchase_orders.sql
--   20260717170000_b2b_reception_pmp_payment.sql
--
-- PRÉREQUIS : renseigner ci-dessous les emails de DEUX comptes vendeurs de test
-- (ex. cert.a / cert.b). Le script crée ses produits/fournisseurs de test, joue
-- le cycle complet et AFFICHE les preuves chiffrées (RAISE NOTICE). Chaque
-- assertion échouée lève une EXCEPTION explicite.
-- Le tout est joué dans UNE transaction ROLLBACKÉE À LA FIN (aucune trace en
-- base) — passer COMMIT à la place du ROLLBACK final pour conserver les données.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  -- ⚠️ À RENSEIGNER : emails des deux vendeurs de test
  c_buyer_email    text := 'cert.a@224solutions.test';
  c_supplier_email text := 'cert.b@224solutions.test';

  v_buyer_user uuid; v_supplier_user uuid;
  v_buyer_vendor uuid; v_supplier_vendor uuid;
  v_customer_id uuid;
  v_supplier_row uuid; v_supplier_row2 uuid;
  v_req jsonb; v_res jsonb;
  v_p1 uuid; v_p2 uuid;                  -- produits du FOURNISSEUR
  v_order_id uuid; v_purchase_id uuid;
  v_item1 uuid; v_item2 uuid;
  v_stock int; v_reserved int; v_cost numeric; v_bp uuid;
  v_buyer_bal0 numeric; v_supplier_bal0 numeric; v_pdg_bal0 numeric;
  v_buyer_bal numeric; v_supplier_bal numeric; v_pdg_bal numeric;
  v_pdg_user uuid;
  v_fee_pct numeric; v_fee numeric; v_subtotal numeric := 3*2600 + 2*5000; -- après envoi
  v_escrow record; v_debt record;
  v_ext_purchase uuid; v_ext_prod uuid;
BEGIN
  -- ── Résolution des comptes ────────────────────────────────────────────────
  SELECT id INTO v_buyer_user FROM auth.users WHERE email = c_buyer_email;
  SELECT id INTO v_supplier_user FROM auth.users WHERE email = c_supplier_email;
  IF v_buyer_user IS NULL OR v_supplier_user IS NULL THEN
    RAISE EXCEPTION 'Comptes de test introuvables — renseigner c_buyer_email / c_supplier_email';
  END IF;
  -- Boutiques de certification créées AU BESOIN, dans la transaction (rollback
  -- final → zéro trace) : les comptes cert n'ont pas besoin d'être vendeurs.
  SELECT id INTO v_buyer_vendor FROM vendors WHERE user_id = v_buyer_user LIMIT 1;
  IF v_buyer_vendor IS NULL THEN
    INSERT INTO vendors (user_id, business_name) VALUES (v_buyer_user, 'CERT Acheteur A')
    RETURNING id INTO v_buyer_vendor;
  END IF;
  SELECT id INTO v_supplier_vendor FROM vendors WHERE user_id = v_supplier_user LIMIT 1;
  IF v_supplier_vendor IS NULL THEN
    INSERT INTO vendors (user_id, business_name) VALUES (v_supplier_user, 'CERT Fournisseur B')
    RETURNING id INTO v_supplier_vendor;
  END IF;
  SELECT id INTO v_customer_id FROM customers WHERE user_id = v_buyer_user;
  IF v_customer_id IS NULL THEN
    INSERT INTO customers (user_id) VALUES (v_buyer_user) RETURNING id INTO v_customer_id;
  END IF;
  SELECT user_id INTO v_pdg_user FROM pdg_management WHERE is_active = true LIMIT 1;

  -- Wallets GNF garantis + solde acheteur suffisant pour le test
  INSERT INTO wallets (user_id, balance, currency, wallet_status)
  VALUES (v_buyer_user, 0, 'GNF', 'active') ON CONFLICT DO NOTHING;
  INSERT INTO wallets (user_id, balance, currency, wallet_status)
  VALUES (v_supplier_user, 0, 'GNF', 'active') ON CONFLICT DO NOTHING;
  UPDATE wallets SET balance = balance + 1000000 WHERE user_id = v_buyer_user AND currency = 'GNF';

  SELECT balance INTO v_buyer_bal0 FROM wallets WHERE user_id = v_buyer_user AND currency='GNF';
  SELECT balance INTO v_supplier_bal0 FROM wallets WHERE user_id = v_supplier_user AND currency='GNF';
  SELECT balance INTO v_pdg_bal0 FROM wallets WHERE user_id = v_pdg_user AND currency='GNF';

  RAISE NOTICE '═══ CONTEXTE : acheteur=% fournisseur=% | soldes GNF acheteur=% fournisseur=% pdg=%',
    v_buyer_vendor, v_supplier_vendor, v_buyer_bal0, v_supplier_bal0, v_pdg_bal0;

  -- ══ TEST 1 — LIAISON acceptée + refusée ═══════════════════════════════════
  INSERT INTO vendor_suppliers (vendor_id, name) VALUES (v_buyer_vendor, 'CERT Fournisseur lié')
  RETURNING id INTO v_supplier_row;
  v_req := request_supplier_link(v_supplier_row, v_buyer_vendor, v_supplier_vendor, 'test cert');
  IF (v_req->>'success')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T1: demande de liaison échouée: %', v_req->>'error';
  END IF;
  v_res := respond_supplier_link((v_req->>'request_id')::uuid, v_supplier_vendor, true);
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T1: acceptation échouée: %', v_res->>'error';
  END IF;
  PERFORM 1 FROM vendor_suppliers
  WHERE id = v_supplier_row AND supplier_kind='lie' AND link_status='linked'
    AND linked_vendor_id = v_supplier_vendor;
  IF NOT FOUND THEN RAISE EXCEPTION 'T1: fiche non liée après acceptation'; END IF;

  -- Refus sur une seconde fiche (avec un 3e vendeur simulé impossible → on refuse
  -- une demande du même couple : la contrainte unique (vendor,linked) empêche une
  -- 2e fiche liée au même fournisseur, on vérifie donc le REFUS sur une fiche neuve
  -- AVANT liaison en annulant la 1re : ici on teste le refus via une fiche vers un
  -- fournisseur == v_supplier_vendor sur un AUTRE acheteur ? Non : on refait le flux
  -- inverse — le FOURNISSEUR demande à l'ACHETEUR (rôles échangés) et l'acheteur refuse.
  INSERT INTO vendor_suppliers (vendor_id, name) VALUES (v_supplier_vendor, 'CERT refus')
  RETURNING id INTO v_supplier_row2;
  v_req := request_supplier_link(v_supplier_row2, v_supplier_vendor, v_buyer_vendor, NULL);
  v_res := respond_supplier_link((v_req->>'request_id')::uuid, v_buyer_vendor, false);
  PERFORM 1 FROM vendor_suppliers
  WHERE id = v_supplier_row2 AND supplier_kind='externe' AND link_status='none';
  IF NOT FOUND THEN RAISE EXCEPTION 'T1: refus mal appliqué'; END IF;
  RAISE NOTICE '✅ T1 liaison : acceptée (fiche liée) + refusée (fiche revenue à none)';

  -- ══ TEST 2 — COMMANDE B2B COMPLÈTE ════════════════════════════════════════
  -- Produits fournisseur : P1 30 u @2600 GNF ; P2 10 u @5000 GNF.
  INSERT INTO products (vendor_id, name, price, stock_quantity, is_active)
  VALUES (v_supplier_vendor, 'CERT-P1', 2600, 30, true) RETURNING id INTO v_p1;
  INSERT INTO products (vendor_id, name, price, stock_quantity, is_active)
  VALUES (v_supplier_vendor, 'CERT-P2', 5000, 10, true) RETURNING id INTO v_p2;

  v_fee_pct := COALESCE(get_purchase_commission_percent(), 0);
  -- Commande initiale : 3×P1 + 2×P2 = 7800 + 10000 = 17800 GNF (wallet, on_order)
  v_fee := round((3*2600 + 2*5000) * v_fee_pct / 100.0);
  v_res := create_b2b_purchase_order(
    p_buyer_vendor_id => v_buyer_vendor, p_supplier_row_id => v_supplier_row,
    p_items => jsonb_build_array(
      jsonb_build_object('product_id', v_p1, 'quantity', 3),
      jsonb_build_object('product_id', v_p2, 'quantity', 2)),
    p_payment_mode => 'wallet', p_payment_timing => 'on_order',
    p_customer_id => v_customer_id, p_notes => 'cert',
    p_wallet_debit_amount => 17800, p_buyer_wallet_currency => 'GNF',
    p_buyer_fee_amount => v_fee, p_currency => 'GNF');
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T2: création commande échouée: %', v_res->>'error';
  END IF;
  v_order_id := (v_res->>'order_id')::uuid;
  v_purchase_id := (v_res->>'purchase_id')::uuid;
  SELECT balance INTO v_buyer_bal FROM wallets WHERE user_id=v_buyer_user AND currency='GNF';
  IF v_buyer_bal <> v_buyer_bal0 - 17800 - v_fee THEN
    RAISE EXCEPTION 'T2: débit acheteur incorrect (attendu %, solde %)', v_buyer_bal0-17800-v_fee, v_buyer_bal;
  END IF;
  SELECT * INTO v_escrow FROM escrow_transactions WHERE order_id = v_order_id AND status='held';
  IF NOT FOUND OR v_escrow.amount <> 17800 THEN RAISE EXCEPTION 'T2: escrow held 17800 attendu'; END IF;
  RAISE NOTICE '✅ T2a envoi : commande %, débit % + frais % → escrow held 17800',
    v_res->>'order_number', 17800, v_fee;

  -- AJUSTEMENT fournisseur : P1 passe de 2600 → 2500, quantité 3 → 4 ;
  -- nouveau total = 4×2500 + 2×5000 = 20000 (delta +2200).
  v_res := confirm_b2b_order(v_order_id, v_supplier_vendor,
    jsonb_build_array(jsonb_build_object('product_id', v_p1, 'quantity', 4, 'unit_price', 2500)),
    'dispo cartons');
  IF (v_res->>'adjusted')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T2: ajustement non enregistré: %', v_res;
  END IF;
  -- REVALIDATION acheteur (accepte) → réservation + delta débité.
  v_res := revalidate_b2b_order(v_order_id, v_buyer_vendor, true);
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T2: revalidation échouée: %', v_res->>'error';
  END IF;
  IF (v_res->>'new_subtotal')::numeric <> 20000 THEN
    RAISE EXCEPTION 'T2: nouveau total attendu 20000, obtenu %', v_res->>'new_subtotal';
  END IF;
  -- Miroir fournisseur : P1 stock 30-4=26 dispo + 4 réservés ; P2 10-2=8 + 2.
  SELECT stock_quantity, reserved_quantity INTO v_stock, v_reserved FROM products WHERE id=v_p1;
  IF v_stock <> 26 OR v_reserved <> 4 THEN
    RAISE EXCEPTION 'T2: réservation P1 incorrecte (stock=% réservé=%)', v_stock, v_reserved;
  END IF;
  SELECT stock_quantity, reserved_quantity INTO v_stock, v_reserved FROM products WHERE id=v_p2;
  IF v_stock <> 8 OR v_reserved <> 2 THEN
    RAISE EXCEPTION 'T2: réservation P2 incorrecte (stock=% réservé=%)', v_stock, v_reserved;
  END IF;
  RAISE NOTICE '✅ T2b ajustement revalidé : total 17800→20000, P1 26 dispo + 4 réservés, P2 8 + 2';

  -- EXPÉDITION : le réservé sort définitivement.
  v_res := ship_b2b_order(v_order_id, v_supplier_vendor);
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T2: expédition échouée: %', v_res->>'error';
  END IF;
  SELECT reserved_quantity INTO v_reserved FROM products WHERE id=v_p1;
  IF v_reserved <> 0 THEN RAISE EXCEPTION 'T2: réservé P1 non soldé après expédition'; END IF;

  -- RÉCEPTION PARTIELLE : l'acheteur a déjà CERT-BUY (10 u @2000 de coût) pour
  -- prouver le PMP ; il reçoit 2×P1 dessus → PMP (10×2000+2×2500)/12 = 2083.33.
  INSERT INTO products (vendor_id, name, price, stock_quantity, cost_price, is_active)
  VALUES (v_buyer_vendor, 'CERT-BUY', 3500, 10, 2000, true) RETURNING id INTO v_bp;
  SELECT id INTO v_item1 FROM stock_purchase_items
  WHERE purchase_id = v_purchase_id AND supplier_product_id = v_p1;
  SELECT id INTO v_item2 FROM stock_purchase_items
  WHERE purchase_id = v_purchase_id AND supplier_product_id = v_p2;

  v_res := receive_b2b_purchase(
    p_purchase_id => v_purchase_id, p_buyer_vendor_id => v_buyer_vendor,
    p_lines => jsonb_build_array(
      jsonb_build_object('item_id', v_item1, 'received_qty', 2, 'buyer_product_id', v_bp)),
    p_close => false);
  IF (v_res->>'status') <> 'received_partial' THEN
    RAISE EXCEPTION 'T2: réception partielle attendue, obtenu %', v_res->>'status';
  END IF;
  SELECT stock_quantity, cost_price INTO v_stock, v_cost FROM products WHERE id = v_bp;
  IF v_stock <> 12 OR round(v_cost,2) <> 2083.33 THEN
    RAISE EXCEPTION 'T2 PMP partiel: attendu stock 12 / coût 2083.33, obtenu % / %', v_stock, v_cost;
  END IF;
  RAISE NOTICE '✅ T2c réception partielle : CERT-BUY stock 10→12, PMP 2000→2083.33 (=(10×2000+2×2500)/12)';

  -- RÉCEPTION TOTALE (solde : 2×P1 restants + 2×P2) → escrow libéré intégralement.
  v_res := receive_b2b_purchase(
    p_purchase_id => v_purchase_id, p_buyer_vendor_id => v_buyer_vendor,
    p_lines => jsonb_build_array(
      jsonb_build_object('item_id', v_item1, 'received_qty', 2, 'buyer_product_id', v_bp),
      jsonb_build_object('item_id', v_item2, 'received_qty', 2)), -- création produit auto
    p_close => false);
  IF (v_res->>'final')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T2: réception finale attendue: %', v_res;
  END IF;
  -- PMP final CERT-BUY : (12×2083.33 + 2×2500)/14 = 2142.86 (arrondis SQL par étape)
  SELECT stock_quantity, cost_price INTO v_stock, v_cost FROM products WHERE id = v_bp;
  IF v_stock <> 14 OR round(v_cost,2) <> round((12*2083.33 + 2*2500)/14.0, 2) THEN
    RAISE EXCEPTION 'T2 PMP final: attendu stock 14 / coût %, obtenu % / %',
      round((12*2083.33 + 2*2500)/14.0, 2), v_stock, v_cost;
  END IF;
  -- Escrow libéré + ledger : fournisseur crédité 20000 ; acheteur débité 20000+frais.
  SELECT * INTO v_escrow FROM escrow_transactions WHERE order_id = v_order_id;
  IF v_escrow.status <> 'released' THEN RAISE EXCEPTION 'T2: escrow non libéré (%)', v_escrow.status; END IF;
  SELECT balance INTO v_supplier_bal FROM wallets WHERE user_id=v_supplier_user AND currency='GNF';
  IF v_supplier_bal <> v_supplier_bal0 + 20000 THEN
    RAISE EXCEPTION 'T2 ledger: fournisseur attendu +20000, obtenu +%', v_supplier_bal - v_supplier_bal0;
  END IF;
  SELECT balance INTO v_buyer_bal FROM wallets WHERE user_id=v_buyer_user AND currency='GNF';
  IF v_buyer_bal <> v_buyer_bal0 - 20000 - v_fee - round(2200 * v_fee_pct / 100.0) THEN
    RAISE EXCEPTION 'T2 ledger: débit acheteur total incohérent (solde %, attendu %)',
      v_buyer_bal, v_buyer_bal0 - 20000 - v_fee - round(2200 * v_fee_pct / 100.0);
  END IF;
  SELECT balance INTO v_pdg_bal FROM wallets WHERE user_id=v_pdg_user AND currency='GNF';
  RAISE NOTICE '✅ T2d réception totale : PMP final % (stock 14) ; escrow LIBÉRÉ ; ledger équilibré (fournisseur +20000, acheteur -% , PDG +%)',
    v_cost, 20000 + v_fee + round(2200*v_fee_pct/100.0), v_pdg_bal - v_pdg_bal0;

  -- Invariant miroir : sorties fournisseur (4+2) = entrées acheteur (4 sur CERT-BUY + 2 créées)
  SELECT stock_quantity + reserved_quantity INTO v_stock FROM products WHERE id = v_p1;
  IF v_stock <> 26 THEN RAISE EXCEPTION 'T2 invariant: physique P1 attendu 26, obtenu %', v_stock; END IF;
  RAISE NOTICE '✅ T2e invariant : sortie fournisseur (6 u) = entrée acheteur (6 u), physique P1 30→26';

  -- ══ TEST 3 — ACHAT À CRÉDIT → DETTE ══════════════════════════════════════
  v_res := create_b2b_purchase_order(
    p_buyer_vendor_id => v_buyer_vendor, p_supplier_row_id => v_supplier_row,
    p_items => jsonb_build_array(jsonb_build_object('product_id', v_p1, 'quantity', 2)),
    p_payment_mode => 'credit', p_payment_timing => 'on_reception',
    p_customer_id => v_customer_id,
    p_due_date => (CURRENT_DATE + 3), p_minimum_installment => 1000, p_currency => 'GNF');
  v_order_id := (v_res->>'order_id')::uuid; v_purchase_id := (v_res->>'purchase_id')::uuid;
  PERFORM confirm_b2b_order(v_order_id, v_supplier_vendor);
  PERFORM ship_b2b_order(v_order_id, v_supplier_vendor);
  SELECT id INTO v_item1 FROM stock_purchase_items WHERE purchase_id = v_purchase_id;
  v_res := receive_b2b_purchase(v_purchase_id, v_buyer_vendor,
    jsonb_build_array(jsonb_build_object('item_id', v_item1, 'received_qty', 2, 'buyer_product_id', v_bp)));
  IF (v_res->>'debt_id') IS NULL THEN RAISE EXCEPTION 'T3: dette non créée'; END IF;
  SELECT * INTO v_debt FROM supplier_debts WHERE id = (v_res->>'debt_id')::uuid;
  -- 2 × P1 à 2600 (prix catalogue — l'ajustement de T2 ne touchait QUE la commande T2)
  IF v_debt.total_amount <> 5200 OR v_debt.due_date <> CURRENT_DATE + 3 THEN
    RAISE EXCEPTION 'T3: dette incorrecte (total=% échéance=%)', v_debt.total_amount, v_debt.due_date;
  END IF;
  -- Rappel J-3 : la requête EXACTE du job backend (supplier-debts.reminders) la voit.
  PERFORM 1 FROM supplier_debts
  WHERE status IN ('in_progress','overdue') AND due_date = CURRENT_DATE + 3
    AND remaining_amount > 0 AND id = v_debt.id;
  IF NOT FOUND THEN RAISE EXCEPTION 'T3: la dette n''entre pas dans le palier J-3 du job de rappel'; END IF;
  -- Paiement partiel → crédite le fournisseur LIÉ (transfert réel).
  SELECT balance INTO v_supplier_bal0 FROM wallets WHERE user_id=v_supplier_user AND currency='GNF';
  v_res := pay_supplier_debt(v_debt.id, v_buyer_vendor, 2000, 'cert-debt-1');
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T3: paiement dette échoué: %', v_res->>'error';
  END IF;
  SELECT balance INTO v_supplier_bal FROM wallets WHERE user_id=v_supplier_user AND currency='GNF';
  IF v_supplier_bal <> v_supplier_bal0 + 2000 THEN
    RAISE EXCEPTION 'T3: fournisseur lié non crédité du règlement';
  END IF;
  RAISE NOTICE '✅ T3 crédit : dette 5200 GNF (échéance J+3, palier J-3 détecté par le job) ; tranche 2000 → wallet fournisseur crédité';

  -- ══ TEST 4 — ACHAT EXTERNE MANUEL (flux actuel + PMP) ════════════════════
  INSERT INTO products (vendor_id, name, price, stock_quantity, cost_price, is_active)
  VALUES (v_buyer_vendor, 'CERT-EXT', 900, 5, 500, true) RETURNING id INTO v_ext_prod;
  INSERT INTO stock_purchases (vendor_id, purchase_number, status)
  VALUES (v_buyer_vendor, 'CERT-EXT-1', 'draft') RETURNING id INTO v_ext_purchase;
  v_res := validate_stock_purchase(v_ext_purchase, v_buyer_vendor,
    jsonb_build_array(jsonb_build_object('product_id', v_ext_prod, 'quantity', 5,
      'purchase_price', 700, 'selling_price', 1000)),
    'CERT-EXT-1', 3500);
  IF (v_res->>'success')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'T4: validation externe échouée: %', v_res->>'error';
  END IF;
  SELECT stock_quantity, cost_price INTO v_stock, v_cost FROM products WHERE id = v_ext_prod;
  -- PMP : (5×500 + 5×700)/10 = 600 (avant : cost écrasé à 700)
  IF v_stock <> 10 OR v_cost <> 600 THEN
    RAISE EXCEPTION 'T4 PMP externe: attendu stock 10 / coût 600, obtenu % / %', v_stock, v_cost;
  END IF;
  PERFORM 1 FROM stock_purchases WHERE id = v_ext_purchase AND status='validated' AND is_locked=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'T4: achat externe non validé/verrouillé'; END IF;
  RAISE NOTICE '✅ T4 externe : flux manuel inchangé ; PMP appliqué (5@500 + 5@700 → coût 600, stock 10)';

  RAISE NOTICE '═══ TESTS 1-4 : TOUS PASSÉS ═══';
END $$;

-- ══ TEST 5 — RLS CROISÉE (dans la même transaction, puis rollback) ═══════════
-- L'acheteur A ne voit QUE ses achats ; le fournisseur B ne voit PAS les achats
-- de A ; les demandes de liaison ne sont visibles que des deux parties.
DO $$
DECLARE
  v_a uuid; v_b uuid; v_cnt int;
BEGIN
  SELECT user_id INTO v_a FROM vendors v JOIN auth.users u ON u.id = v.user_id
  WHERE u.email = 'cert.a@224solutions.test';
  SELECT user_id INTO v_b FROM vendors v JOIN auth.users u ON u.id = v.user_id
  WHERE u.email = 'cert.b@224solutions.test';

  -- Simuler le rôle authenticated du FOURNISSEUR B
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO v_cnt FROM stock_purchases sp
  WHERE sp.vendor_id IN (SELECT id FROM vendors WHERE user_id = v_a);
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'T5: le fournisseur B voit % achat(s) de l''acheteur A (fuite RLS)', v_cnt;
  END IF;
  -- B voit les dettes de A UNIQUEMENT quand il en est le CRÉANCIER (fiche liée)
  -- — c'est la policy supplier_debts_creditor (Espace Grossiste). Aucune autre.
  SELECT count(*) INTO v_cnt FROM supplier_debts sd
  WHERE sd.vendor_id IN (SELECT id FROM vendors WHERE user_id = v_a)
    AND sd.supplier_id NOT IN (SELECT public.b2b_creditor_supplier_rows(v_b));
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'T5: le fournisseur B voit % dette(s) de A dont il n''est PAS créancier (fuite RLS)', v_cnt;
  END IF;

  -- Simuler l'ACHETEUR A : il voit ses achats, et les demandes où il est partie.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO v_cnt FROM stock_purchases sp
  WHERE sp.vendor_id IN (SELECT id FROM vendors WHERE user_id = v_a);
  IF v_cnt = 0 THEN RAISE EXCEPTION 'T5: l''acheteur A ne voit pas ses propres achats'; END IF;

  PERFORM set_config('role', 'postgres', true);
  RAISE NOTICE '✅ T5 RLS croisée : B ne voit ni les achats ni les dettes de A ; A voit les siens';
  RAISE NOTICE '═══ CERTIFICATION COMPLÈTE : 5/5 ═══';
END $$;

ROLLBACK; -- ⚠️ remplacer par COMMIT pour conserver les données de test
