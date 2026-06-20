-- =====================================================================
-- DURCISSEMENT SÉCURITÉ : verrouiller l'exécution des RPC atomiques sensibles
-- =====================================================================
-- Nos fonctions atomiques sont SECURITY DEFINER (elles s'exécutent avec les
-- privilèges du propriétaire et contournent la RLS). Par défaut, PostgreSQL
-- accorde EXECUTE à PUBLIC → un utilisateur authentifié (clé anon/JWT via
-- PostgREST) pourrait les appeler DIRECTEMENT et :
--   - create_pos_order_complete / create_pos_sale_complete → fabriquer des
--     commandes/ventes et décrémenter le stock de N'IMPORTE QUEL vendeur ;
--   - wallet_debit_internal → débiter N'IMPORTE QUEL wallet ;
--   - purchase_*_subscription_atomic → créer des abonnements arbitraires.
--
-- Ces RPC ne doivent être appelées QUE par le backend Node.js (service_role).
-- On retire donc EXECUTE à PUBLIC/anon/authenticated et on l'accorde au seul
-- service_role. Les appels internes (les RPC d'abonnement appellent
-- wallet_debit_internal) restent OK car ils s'exécutent en SECURITY DEFINER
-- avec les privilèges du propriétaire.
--
-- ⚠️ À exécuter APRÈS les migrations qui créent ces fonctions
-- (20260604010000 / 020000 / 030000). Robuste aux signatures (boucle sur
-- pg_proc par nom) et idempotent.
-- =====================================================================

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'wallet_debit_internal',
        'purchase_vendor_subscription_atomic',
        'purchase_service_subscription_atomic',
        'purchase_driver_subscription_atomic',
        'create_pos_order_complete',
        'create_pos_sale_complete'
      )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', r.sig);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', r.sig);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.sig);
  END LOOP;
END $$;
