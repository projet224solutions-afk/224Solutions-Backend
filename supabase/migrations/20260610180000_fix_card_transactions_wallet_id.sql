-- ============================================================================
-- 💳 FIX SCHÉMA card_transactions.wallet_id - 224SOLUTIONS
-- ============================================================================
-- BUG : card_transactions.wallet_id est de type UUID NOT NULL, alors que
-- wallets.id est BIGINT. process_card_payment insère wallets.id (bigint) dans
-- cette colonne UUID → erreur 22P02 → le paiement carte échoue toujours.
--
-- La table card_transactions est VIDE → on peut convertir le type sans risque.
-- CORRECTION : wallet_id devient BIGINT (cohérent avec wallets.id) + FK.
-- ============================================================================

-- 1) Supprimer une éventuelle clé étrangère sur wallet_id (nom dynamique)
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT tc.constraint_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
     AND tc.table_schema = kcu.table_schema
    WHERE tc.table_schema = 'public'
      AND tc.table_name = 'card_transactions'
      AND kcu.column_name = 'wallet_id'
      AND tc.constraint_type = 'FOREIGN KEY'
  LOOP
    EXECUTE format('ALTER TABLE public.card_transactions DROP CONSTRAINT %I', r.constraint_name);
  END LOOP;
END $$;

-- 2) Convertir le type UUID → BIGINT (table vide : USING NULL sans perte)
ALTER TABLE public.card_transactions ALTER COLUMN wallet_id DROP NOT NULL;
ALTER TABLE public.card_transactions ALTER COLUMN wallet_id TYPE BIGINT USING (NULL::bigint);
ALTER TABLE public.card_transactions ALTER COLUMN wallet_id SET NOT NULL;

-- 3) Recréer la clé étrangère vers wallets(id)
ALTER TABLE public.card_transactions
  ADD CONSTRAINT card_transactions_wallet_id_fkey
  FOREIGN KEY (wallet_id) REFERENCES public.wallets(id) ON DELETE CASCADE;
