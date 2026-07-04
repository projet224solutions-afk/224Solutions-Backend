-- ============================================================================
-- 🏦 BACKFILL COFFRE PDG — créditer les revenus historiques + lister le mint actionnaire
-- ----------------------------------------------------------------------------
-- PART A (idempotent) : créditer au coffre les revenus_pdg déjà journalisés mais
--   credited_to_wallet=false (le trigger ne s'applique qu'aux NOUVEAUX inserts). Clé
--   d'idempotence 'pdg_revenue:'||id → l'index UNIQUE bloque tout double crédit.
-- PART B (lecture seule) : LISTER les versements actionnaires historiques ex nihilo
--   (sent_to_wallet SANS débit coffre) — ⚠️ NE PAS débiter rétroactivement (l'argent est
--   déjà chez les actionnaires ; un débit rétroactif fausserait le solde présent). Décision
--   PDG au cas par cas. Le check 6A.3 (payout_without_treasury_debit) les remonte aussi.
--
-- ⚠️ Abonnements passés NON journalisés = non backfillables (aucune trace) — documenté.
-- ⚠️ Script en ROLLBACK par défaut : vérifier les totaux AVANT de passer à COMMIT.
-- ============================================================================
BEGIN;

DO $$
DECLARE
  v_pdg_user_id uuid;
  v_wallet_id   bigint;
  v_row         RECORD;
  v_txn_id      text;
  v_credited    int := 0;
  v_total       numeric := 0;
BEGIN
  SELECT user_id INTO v_pdg_user_id FROM public.pdg_management
  WHERE is_active = true ORDER BY created_at NULLS LAST LIMIT 1;
  SELECT id INTO v_wallet_id FROM public.wallets WHERE user_id = v_pdg_user_id AND currency = 'GNF';
  IF v_wallet_id IS NULL THEN
    RAISE NOTICE 'Aucun wallet GNF PDG — backfill impossible';
    RETURN;
  END IF;

  FOR v_row IN
    SELECT id, amount, currency, source_type FROM public.revenus_pdg
    WHERE credited_to_wallet = false AND COALESCE(amount,0) > 0
    ORDER BY created_at
  LOOP
    v_txn_id := 'pdg_revenue:' || v_row.id::text;
    -- idempotence dure
    IF EXISTS (SELECT 1 FROM public.wallet_transactions WHERE transaction_id = v_txn_id) THEN
      UPDATE public.revenus_pdg SET credited_to_wallet = true, wallet_transaction_id = v_txn_id WHERE id = v_row.id;
      CONTINUE;
    END IF;
    UPDATE public.wallets SET balance = COALESCE(balance,0) + v_row.amount, updated_at = now() WHERE id = v_wallet_id;
    INSERT INTO public.wallet_transactions (
      transaction_id, receiver_wallet_id, receiver_user_id, amount, fee, net_amount, currency,
      transaction_type, status, description, metadata)
    VALUES (v_txn_id, v_wallet_id, v_pdg_user_id, v_row.amount, 0, v_row.amount, COALESCE(v_row.currency,'GNF'),
      'deposit', 'completed', 'Backfill revenu plateforme — ' || v_row.source_type,
      jsonb_build_object('treasury_credit', true, 'revenue_id', v_row.id, 'source_type', v_row.source_type, 'backfill', true));
    UPDATE public.revenus_pdg SET credited_to_wallet = true, wallet_transaction_id = v_txn_id WHERE id = v_row.id;
    v_credited := v_credited + 1; v_total := v_total + v_row.amount;
  END LOOP;

  RAISE NOTICE 'PART A — % revenus crédités au coffre, total % GNF', v_credited, v_total;
END $$;

-- PART B — versements actionnaires ex nihilo historiques (À LISTER, ne pas débiter).
SELECT sp.id AS payment_id, sp.shareholder_id, sp.amount, sp.currency, sp.sent_to_wallet_at
FROM public.shareholder_payments sp
WHERE sp.status = 'sent_to_wallet'
  AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions wt
                  WHERE wt.transaction_id = 'shareholder_payout:' || sp.id::text)
ORDER BY sp.sent_to_wallet_at;

-- ⚠️ Vérifier les totaux ci-dessus PUIS remplacer ROLLBACK par COMMIT pour appliquer PART A.
ROLLBACK;
