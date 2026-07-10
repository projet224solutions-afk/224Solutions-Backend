-- 💰 RÉGULARISATION de 2 annulations endommagées par l'ancien code prod (audit 2026-07-04)
-- ─────────────────────────────────────────────────────────────────────────────
-- 1) ORD-MR2LSPR5-BET4  : annulée 02/07 07:38, escrow 367619ab LIBÉRÉ AU VENDEUR 02/07 22:00
--    (tx n°679 : +1 606,11 XOF sur wallet 71). → reprendre 1 606,11 XOF au vendeur,
--    recréditer 25 000 GNF à l'acheteur (wallet 725), escrow → 'refunded'.
-- 2) ORD-MQZJS883-QURG  : escrow 1a577ce9 'refunded' SANS recrédit (ancien bug).
--    → recréditer 25 000 GNF à l'acheteur (wallet 710).
-- Atomique (verrous ligne), tracé (wallet_transactions liées aux escrows), idempotent
-- (garde sur transaction_id). ROLLBACK par défaut → vérifier PART A puis passer COMMIT.

-- ─────────────────── PART A : INSPECTION (lecture seule) ───────────────────
SELECT id, balance, currency FROM public.wallets WHERE id IN (71, 725, 710) ORDER BY id;
-- attendu : 71 = XOF (≥ 1606.11) · 725 = GNF · 710 = GNF (15 000)
SELECT transaction_id FROM public.wallet_transactions
WHERE transaction_id IN ('TXN-REG-BET4-VENDOR','TXN-REG-BET4-BUYER','TXN-REG-QURG-BUYER');
-- attendu : 0 ligne (sinon déjà appliqué → ne pas relancer)

-- ─────────────────── PART B : RÉGULARISATION (transaction) ───────────────────
BEGIN;

DO $$
DECLARE
  v_w71  public.wallets%ROWTYPE;
  v_w725 public.wallets%ROWTYPE;
  v_w710 public.wallets%ROWTYPE;
BEGIN
  -- Idempotence stricte
  IF EXISTS (SELECT 1 FROM public.wallet_transactions
             WHERE transaction_id IN ('TXN-REG-BET4-VENDOR','TXN-REG-BET4-BUYER','TXN-REG-QURG-BUYER')) THEN
    RAISE EXCEPTION 'Régularisation déjà appliquée — abandon.';
  END IF;

  SELECT * INTO v_w71  FROM public.wallets WHERE id = 71  FOR UPDATE;
  SELECT * INTO v_w725 FROM public.wallets WHERE id = 725 FOR UPDATE;
  SELECT * INTO v_w710 FROM public.wallets WHERE id = 710 FOR UPDATE;
  IF v_w71.balance < 1606.11 THEN RAISE EXCEPTION 'Solde vendeur insuffisant — abandon.'; END IF;

  -- ── BET4 : reprise vendeur (libération illégitime post-annulation)
  UPDATE public.wallets SET balance = balance - 1606.11, updated_at = now() WHERE id = 71;
  INSERT INTO public.wallet_transactions
    (transaction_id, transaction_type, amount, fee, net_amount, currency, status,
     sender_user_id, sender_wallet_id, reference_id, description, metadata)
  VALUES
    ('TXN-REG-BET4-VENDOR', 'withdrawal', 1606.11, 0, 1606.11, 'XOF', 'completed',
     'fca38d2e-c909-41ac-9efb-c2ed4979c622', 71, '367619ab-ac2c-48a5-aab4-5ccc70193300',
     'Reprise libération illégitime — commande ORD-MR2LSPR5-BET4 annulée AVANT libération (auto-release ancien code)',
     jsonb_build_object('reason','release_after_cancel_recovery','order_id','4ef673b7-6f43-41bb-95b4-153d26c42345',
                        'escrow_id','367619ab-ac2c-48a5-aab4-5ccc70193300','original_tx_id',679,'regularized_at',now()));

  -- ── BET4 : recrédit acheteur
  UPDATE public.wallets SET balance = balance + 25000, updated_at = now() WHERE id = 725;
  INSERT INTO public.wallet_transactions
    (transaction_id, transaction_type, amount, fee, net_amount, currency, status,
     receiver_user_id, receiver_wallet_id, reference_id, description, metadata)
  VALUES
    ('TXN-REG-BET4-BUYER', 'refund', 25000, 0, 25000, 'GNF', 'completed',
     'dbfdaf11-f24b-40ab-aef9-a3a5c56e1ad0', 725, '367619ab-ac2c-48a5-aab4-5ccc70193300',
     'Remboursement commande annulée ORD-MR2LSPR5-BET4 (escrow libéré à tort par l''ancien code)',
     jsonb_build_object('reason','release_after_cancel_recovery','order_id','4ef673b7-6f43-41bb-95b4-153d26c42345',
                        'escrow_id','367619ab-ac2c-48a5-aab4-5ccc70193300','regularized_at',now()));

  -- ── BET4 : l'escrow reflète la réalité (remboursé, plus « libéré »)
  UPDATE public.escrow_transactions
  SET status = 'refunded', refunded_at = now(), updated_at = now(),
      notes = COALESCE(notes,'') || ' | Régularisé 2026-07-04 : libération post-annulation reprise, acheteur remboursé.'
  WHERE id = '367619ab-ac2c-48a5-aab4-5ccc70193300' AND status = 'released';

  -- ── QURG : recrédit acheteur (escrow était "refunded" sans recrédit)
  UPDATE public.wallets SET balance = balance + 25000, updated_at = now() WHERE id = 710;
  INSERT INTO public.wallet_transactions
    (transaction_id, transaction_type, amount, fee, net_amount, currency, status,
     receiver_user_id, receiver_wallet_id, reference_id, description, metadata)
  VALUES
    ('TXN-REG-QURG-BUYER', 'refund', 25000, 0, 25000, 'GNF', 'completed',
     '0d551780-1bfc-4abc-a4cf-0e726de6ada4', 710, '1a577ce9-c33d-4593-b846-ff0792058c7e',
     'Remboursement commande annulée ORD-MQZJS883-QURG (escrow marqué refunded sans recrédit — ancien bug)',
     jsonb_build_object('reason','refunded_without_credit_recovery','order_id','647f401b-2f7f-4840-b2b2-a558a48c0d4d',
                        'escrow_id','1a577ce9-c33d-4593-b846-ff0792058c7e','regularized_at',now()));

  RAISE NOTICE 'OK — vendeur -1606.11 XOF · acheteur BET4 +25000 GNF · acheteur QURG +25000 GNF';
END;
$$;

-- Contrôle post-régularisation
SELECT id, balance, currency FROM public.wallets WHERE id IN (71, 725, 710) ORDER BY id;
-- attendu : 71 ≈ solde-1606.11 · 725 = +25000 · 710 = 40000

ROLLBACK; -- ⚠️ Vérifie PART A + le contrôle ci-dessus, puis remplace ROLLBACK par COMMIT.
