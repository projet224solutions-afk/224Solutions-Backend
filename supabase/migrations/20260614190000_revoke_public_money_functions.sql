-- ============================================================================
-- 🔴 CRITIQUE — FERMETURE FAILLE « mint money » : REVOKE PUBLIC sur la couche argent
-- ----------------------------------------------------------------------------
-- DÉCOUVERTE (2026-06-14) : des dizaines de fonctions SECURITY DEFINER qui DÉPLACENT
-- de l'argent étaient exécutables par `anon` (clé publique du frontend) via le grant
-- EXECUTE hérité de PUBLIC. Vérifié EMPIRIQUEMENT en clé anon : `credit_user_wallet_safe`,
-- `set_wallet_frozen`, `execute_atomic_wallet_transfer`, `request_bank_withdrawal`,
-- `change_user_currency_atomic`… s'exécutent → un anonyme pouvait CRÉER de l'argent,
-- transférer, geler des wallets, libérer des escrows, et (grant_pdg_permission_to_agent)
-- s'auto-octroyer des droits admin.
--
-- CORRECTIF : ces fonctions ne doivent être appelées QUE par le backend (service_role).
-- On révoque EXECUTE depuis PUBLIC/anon/authenticated et on (re)accorde à service_role.
-- Les TRIGGERS ne sont pas affectés (ils s'exécutent avec les droits du propriétaire).
--
-- ⚠️ NON inclus ici (utilisés en direct par le frontend → à migrer en backend AVANT
-- de révoquer, sinon casse les transferts) : process_secure_wallet_transfer,
-- process_wallet_transfer_with_fees. Traités en phase 2.
--
-- Boucle sur pg_proc → couvre automatiquement toutes les surcharges. Rejouable.
-- ============================================================================

DO $$
DECLARE
  fn_names text[] := ARRAY[
    -- Création / crédit de solde (mint money)
    'credit_user_wallet_safe','credit_wallet','credit_agent_wallet_gnf','credit_agent_commission',
    'force_credit_seller_wallet','pay_with_commission','apply_wallet_cap_split',
    -- Transferts (hors 2 fonctions utilisées par le front)
    'execute_atomic_wallet_transfer','execute_atomic_wallet_transfer_fx',
    'process_wallet_transfer','process_wallet_transaction','process_secure_bureau_transfer',
    'transfer_between_wallets',
    -- Escrow (libération / remboursement / litige)
    'cancel_order_and_refund_wallet','refund_escrow','refund_escrow_funds','refund_order_escrow',
    'release_escrow_funds','release_escrow_to_seller','release_vendor_funds',
    'resolve_escrow_dispute','confirm_delivery_and_release_escrow','dispute_escrow',
    'initiate_escrow','create_escrow_transaction',
    -- AML / gel / quarantaine
    'quarantine_wallet_amount','set_wallet_frozen','release_quarantined_funds','reject_quarantined_funds',
    -- Retraits
    'request_bank_withdrawal','admin_process_withdrawal',
    -- Devise / actionnaire
    'change_user_currency_atomic','admin_change_vendor_currency',
    'send_shareholder_payment_to_wallet','create_shareholder',
    -- Paiements (déclenchent crédits/escrows)
    'process_card_payment','process_card_to_wallet','process_wallet_to_card','process_taxi_card_payment',
    'process_professional_service_payment','process_wallet_order_payment',
    'process_deposit_payment','process_successful_payment','process_payment_by_type',
    'process_pending_affiliate_commissions','create_order_from_payment','fix_orphan_payment',
    -- Privilèges / comptes (escalade)
    'grant_pdg_permission_to_agent','create_user_with_wallet',
    'delete_agent','delete_user_storage_objects','delete_syndicate_worker_secure'
  ];
  r record;
  n_done int := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
    WHERE nsp.nspname = 'public' AND p.proname = ANY(fn_names)
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', r.sig);
    EXECUTE format('GRANT  EXECUTE ON FUNCTION %s TO service_role', r.sig);
    n_done := n_done + 1;
  END LOOP;
  RAISE NOTICE 'Fonctions argent/privilège verrouillées (PUBLIC révoqué, service_role gardé): %', n_done;
END $$;

SELECT 'Couche argent verrouillée : REVOKE EXECUTE FROM PUBLIC sur les fonctions de mouvement d''argent/privilège (service_role uniquement).' AS status;
