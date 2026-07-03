-- 💰 RÉGULARISATION du sur-crédit — escrow 74b744a5 / commande ORD-MQZN4VEY-0KHW
-- ─────────────────────────────────────────────────────────────────────────────
-- AUDIT (2026-07-03/04) : l'ancienne Edge confirm-delivery a crédité le NET de
-- 25 593,75 (chiffre en GNF) TEL QUEL dans le wallet XOF n°71 du vendeur VND0003
-- (fca38d2e…), SANS conversion (code : balance + vendorAmount). Les libérations
-- correctes du MÊME vendeur pour le même net créditaient ≈ 1 694,04 XOF
-- (tx 631/647 : 24 375 GNF → 1 613,37 XOF, taux 0,0661895).
--   Crédit erroné  : 25 593,75 XOF (tx n°654, taguée reversed le 02/07 — tag SEUL,
--                    aucun solde touché par le script de dismiss)
--   Crédit correct : ≈ 1 694,04 XOF
--   SUR-CRÉDIT     : 23 899,71 XOF à récupérer
--
-- Ce script est ATOMIQUE (verrou ligne wallet), TRACÉ (ligne wallet_transactions
-- liée à l'escrow) et IDEMPOTENT (garde anti-double-exécution sur reference_id).
-- ROLLBACK par défaut : vérifie la PART A, puis remplace ROLLBACK par COMMIT.

-- ─────────────────── PART A : INSPECTION (lecture seule) ───────────────────
SELECT id, balance, currency, wallet_status
FROM public.wallets WHERE id = 71;                       -- attendu : ≥ 23899.71, XOF, active

SELECT id, transaction_type, amount, net_amount, currency, metadata->>'reversed' AS reversed
FROM public.wallet_transactions
WHERE reference_id = '74b744a5-e8ef-4d1b-b4dd-a29a8a95666b';  -- la tx 654 fautive (+ garde : PAS de ligne TXN-REG déjà présente)

-- ─────────────────── PART B : RÉGULARISATION (transaction) ───────────────────
BEGIN;

DO $$
DECLARE
  v_wallet   public.wallets%ROWTYPE;
  v_amount   numeric := 23899.71;   -- sur-crédit XOF (25 593,75 − 1 694,04)
  v_escrow   text := '74b744a5-e8ef-4d1b-b4dd-a29a8a95666b';
  v_seller   uuid := 'fca38d2e-c909-41ac-9efb-c2ed4979c622';
BEGIN
  -- Idempotence : ne jamais débiter deux fois la même régularisation.
  IF EXISTS (
    SELECT 1 FROM public.wallet_transactions
    WHERE reference_id = v_escrow
      AND metadata->>'reason' = 'non_converted_release_overcredit_recovery'
  ) THEN
    RAISE EXCEPTION 'Régularisation déjà appliquée pour cet escrow — abandon.';
  END IF;

  -- Verrou + contrôles.
  SELECT * INTO v_wallet FROM public.wallets WHERE id = 71 FOR UPDATE;
  IF v_wallet.currency <> 'XOF' THEN
    RAISE EXCEPTION 'Devise wallet inattendue (%) — abandon.', v_wallet.currency;
  END IF;
  IF v_wallet.balance < v_amount THEN
    RAISE EXCEPTION 'Solde insuffisant (%.2f < %.2f) — abandon.', v_wallet.balance, v_amount;
  END IF;

  -- Débit + trace (jamais l''un sans l''autre).
  UPDATE public.wallets
  SET balance = balance - v_amount, updated_at = now()
  WHERE id = 71;

  INSERT INTO public.wallet_transactions
    (transaction_id, transaction_type, amount, fee, net_amount, currency, status,
     sender_user_id, sender_wallet_id, reference_id, description, metadata)
  VALUES
    ('TXN-REG-74B744A5', 'withdrawal', v_amount, 0, v_amount, 'XOF', 'completed',
     v_seller, 71, v_escrow,
     'Régularisation sur-crédit libération escrow ORD-MQZN4VEY-0KHW (crédit GNF non converti en XOF par l''ancienne Edge)',
     jsonb_build_object(
       'reason', 'non_converted_release_overcredit_recovery',
       'escrow_id', v_escrow,
       'order_id', 'de6df145-bcbf-4c9f-ac3f-592350587202',
       'wrong_credit_xof', 25593.75,
       'correct_credit_xof', 1694.04,
       'rate_gnf_to_xof', 0.0661895,
       'original_tx_id', 654,
       'regularized_at', now()
     ));

  -- Marque la tx fautive comme régularisée (audit complet en un coup d'œil).
  UPDATE public.wallet_transactions
  SET metadata = COALESCE(metadata, '{}'::jsonb)
               || jsonb_build_object('regularized', true, 'regularized_at', now())
  WHERE id = 654;

  RAISE NOTICE 'OK : % XOF récupérés (nouveau solde ≈ %.2f XOF)', v_amount, v_wallet.balance - v_amount;
END;
$$;

-- Contrôle post-régularisation
SELECT balance FROM public.wallets WHERE id = 71;   -- attendu ≈ 23066.81 si solde de départ 46966.52

ROLLBACK; -- ⚠️ Vérifie les contrôles ci-dessus, puis remplace ROLLBACK par COMMIT pour appliquer.
