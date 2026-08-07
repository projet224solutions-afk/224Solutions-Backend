-- ═══════════════════════════════════════════════════════════════════════════
-- 🌍 CORRIDOR DIASPORA — test de bout en bout EUR→GNF et SLE→GNF.
--
-- LANCEMENT (une commande) :
--   psql "$STAGING_DB_URL" -f scripts/diaspora-corridor-test.sql
--   (ou : coller dans le SQL Editor Supabase)
--
-- ⚠️ MODE PAR DÉFAUT = ROLLBACK : le script exécute des transferts RÉELS via la primitive
-- atomique de production, mesure tout, puis ANNULE tout (RAISE EXCEPTION final). Rien n'est
-- laissé en base — il est donc sûr de le lancer même sur la prod.
-- Pour un tir DÉFINITIF en staging : remplacer la ligne « RAISE EXCEPTION 'PROOF...' » par
-- « RAISE NOTICE 'PROOF...' » (les mouvements sont alors conservés).
--
-- CE QUI EST PROUVÉ, en une exécution :
--   1. taux MID appliqué, avec sa source tracée (table directe/inverse ou pivot USD) ;
--   2. commission 5 % prélevée EN PLUS côté expéditeur (le destinataire reçoit le montant plein) ;
--   3. crédit GNF arrondi à 0 décimale (devise sans centime) ;
--   4. ligne d'historique exacte au centime pour le moniteur PDG ;
--   5. AUCUNE anomalie Fatome levée par l'opération (étage A silencieux = conservation OK).
-- ═══════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_pdg uuid; v_pdg_wallet bigint; v_pdg_bal0 numeric; v_pdg_bal1 numeric; v_pdg_bal2 numeric;
  v_eur_user uuid; v_eur_wallet bigint; v_eur_bal_after numeric;
  v_sle_user uuid; v_sle_wallet bigint; v_sle_bal_after numeric;
  v_rate_eur numeric; v_src_eur text; v_at_eur timestamptz;
  v_rate_sle numeric; v_src_sle text;
  v_credit_eur numeric; v_credit_sle numeric;
  v_send numeric := 100;              -- montant envoyé (devise expéditeur)
  v_fee_pct numeric := 5;             -- commission plateforme, EN PLUS du montant envoyé
  v_fee_eur numeric; v_fee_sle numeric;
  v_ano_before int; v_ano_after int;
  v_tx record; v_et record;
BEGIN
  -- ── Contexte : PDG (destinataire GNF) ──────────────────────────────────
  SELECT m.user_id INTO v_pdg FROM public.pdg_management m WHERE m.is_active = true LIMIT 1;
  SELECT id, balance INTO v_pdg_wallet, v_pdg_bal0
    FROM public.wallets WHERE user_id = v_pdg AND currency = 'GNF' ORDER BY id LIMIT 1;
  SELECT count(*) INTO v_ano_before FROM public.fatome_anomalies WHERE resolved = false;

  -- ══════════════ CORRIDOR 1 : EUR → GNF (diaspora France) ══════════════
  -- Expéditeur : un wallet EUR existant (verrou pays : un utilisateur FR a un wallet EUR).
  SELECT user_id, id INTO v_eur_user, v_eur_wallet
    FROM public.wallets WHERE currency = 'EUR' AND user_id <> v_pdg ORDER BY id LIMIT 1;
  IF v_eur_user IS NULL THEN
    RAISE EXCEPTION 'SEED MANQUANT : aucun wallet EUR. Créer un utilisateur pays FR (le verrou pays lui donne un wallet EUR).';
  END IF;
  UPDATE public.wallets SET balance = 1000 WHERE id = v_eur_wallet;   -- provision de test

  SELECT rate, source, retrieved_at INTO v_rate_eur, v_src_eur, v_at_eur
    FROM public.currency_exchange_rates
    WHERE from_currency = 'EUR' AND to_currency = 'GNF' ORDER BY retrieved_at DESC LIMIT 1;
  IF v_rate_eur IS NULL OR v_at_eur < now() - interval '24 hours' THEN
    RAISE EXCEPTION 'SEED MANQUANT : pas de taux EUR→GNF frais (< 24 h).';
  END IF;

  v_fee_eur    := round(v_send * v_fee_pct / 100, public._ccy_decimals('EUR'));
  v_credit_eur := round(v_send * v_rate_eur,       public._ccy_decimals('GNF'));

  PERFORM public.execute_atomic_wallet_transfer_fx(
    v_eur_user, v_pdg, v_send + v_fee_eur, v_credit_eur, 'Corridor diaspora EUR→GNF',
    v_eur_wallet, v_pdg_wallet, 1000, v_pdg_bal0, 'EUR', 'GNF', v_rate_eur, v_fee_eur);

  SELECT balance INTO v_eur_bal_after FROM public.wallets WHERE id = v_eur_wallet;
  SELECT balance INTO v_pdg_bal1      FROM public.wallets WHERE id = v_pdg_wallet;

  -- Ligne du moniteur PDG + trace FX
  SELECT amount, fee, net_amount, currency, transaction_type INTO v_tx
    FROM public.wallet_transactions WHERE receiver_user_id = v_pdg ORDER BY created_at DESC LIMIT 1;
  SELECT amount, metadata->>'fx' AS fx, metadata->>'rate_used' AS rate_used,
         metadata->>'credit_amount' AS credit_amt, metadata->>'receiver_currency' AS rcv
    INTO v_et FROM public.enhanced_transactions ORDER BY created_at DESC LIMIT 1;

  -- ══════════════ CORRIDOR 2 : SLE → GNF (Sierra Leone) ══════════════
  SELECT user_id, id INTO v_sle_user, v_sle_wallet
    FROM public.wallets WHERE currency = 'SLE' AND user_id <> v_pdg ORDER BY id LIMIT 1;
  IF v_sle_user IS NULL THEN
    RAISE EXCEPTION 'SEED MANQUANT : aucun wallet SLE.';
  END IF;
  UPDATE public.wallets SET balance = 1000 WHERE id = v_sle_wallet;

  SELECT rate, source INTO v_rate_sle, v_src_sle FROM public.currency_exchange_rates
    WHERE from_currency = 'SLE' AND to_currency = 'GNF' ORDER BY retrieved_at DESC LIMIT 1;
  IF v_rate_sle IS NULL THEN RAISE EXCEPTION 'SEED MANQUANT : pas de taux SLE→GNF.'; END IF;

  v_fee_sle    := round(v_send * v_fee_pct / 100, public._ccy_decimals('SLE'));
  v_credit_sle := round(v_send * v_rate_sle,       public._ccy_decimals('GNF'));

  PERFORM public.execute_atomic_wallet_transfer_fx(
    v_sle_user, v_pdg, v_send + v_fee_sle, v_credit_sle, 'Corridor diaspora SLE→GNF',
    v_sle_wallet, v_pdg_wallet, 1000, v_pdg_bal1, 'SLE', 'GNF', v_rate_sle, v_fee_sle);

  SELECT balance INTO v_sle_bal_after FROM public.wallets WHERE id = v_sle_wallet;
  SELECT balance INTO v_pdg_bal2      FROM public.wallets WHERE id = v_pdg_wallet;

  -- Étage A du Fatome : aucune anomalie ne doit être levée par ces opérations.
  SELECT count(*) INTO v_ano_after FROM public.fatome_anomalies WHERE resolved = false;

  RAISE EXCEPTION 'PROOF_DIASPORA|%', jsonb_build_object(
    'EUR_vers_GNF', jsonb_build_object(
      'taux_mid', v_rate_eur, 'source_taux', v_src_eur,
      'age_taux_min', round(extract(epoch from (now() - v_at_eur))/60),
      'envoye', v_send, 'commission_5pct_EN_PLUS', v_fee_eur,
      'debit_total_expediteur', 1000 - v_eur_bal_after,
      'debit_attendu', v_send + v_fee_eur,
      'debit_exact', (1000 - v_eur_bal_after) = (v_send + v_fee_eur),
      'credit_gnf', v_pdg_bal1 - v_pdg_bal0, 'credit_attendu', v_credit_eur,
      'credit_exact', (v_pdg_bal1 - v_pdg_bal0) = v_credit_eur,
      'arrondi_0_decimale', v_credit_eur = trunc(v_credit_eur),
      'ligne_moniteur_pdg', jsonb_build_object('type', v_tx.transaction_type,
        'montant', v_tx.amount, 'frais', v_tx.fee, 'net', v_tx.net_amount, 'devise', v_tx.currency),
      'trace_fx', jsonb_build_object('fx', v_et.fx, 'taux', v_et.rate_used,
        'credit', v_et.credit_amt, 'vers', v_et.rcv)),
    'SLE_vers_GNF', jsonb_build_object(
      'taux_mid', v_rate_sle, 'source_taux', v_src_sle,
      'commission_5pct_EN_PLUS', v_fee_sle,
      'debit_total_expediteur', 1000 - v_sle_bal_after, 'debit_attendu', v_send + v_fee_sle,
      'debit_exact', (1000 - v_sle_bal_after) = (v_send + v_fee_sle),
      'credit_gnf', v_pdg_bal2 - v_pdg_bal1, 'credit_attendu', v_credit_sle,
      'credit_exact', (v_pdg_bal2 - v_pdg_bal1) = v_credit_sle,
      'arrondi_0_decimale', v_credit_sle = trunc(v_credit_sle)),
    'anomalies_fatome_levees', v_ano_after - v_ano_before,
    'mode', 'ROLLBACK (aucune donnée conservée)')::text;
END $$;
