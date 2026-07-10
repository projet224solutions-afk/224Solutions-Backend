-- ============================================================================
-- NETTOYAGE DES FONCTIONS D'ARGENT DUPLIQUÉES — LOT 1
-- ----------------------------------------------------------------------------
-- Chaque DROP est par SIGNATURE EXACTE (jamais DROP FUNCTION nom;).
-- Preuve d'absence d'appelant, établie AVANT ce DROP, pour chaque fonction :
--   • Recensement code : backend/src, backend/supabase/functions (Edge),
--     frontend vista-flows/src  → nombre d'appelants indiqué en commentaire.
--   • pg_proc.prosrc (corps des fonctions VIVANTES) → 0 appel interne
--     (PERFORM/SELECT) pour toutes celles droppées ici.
--   • pg_trigger : les fonctions ci-dessous ont TOUTES des arguments et un
--     retour non-trigger → aucune ne peut être liée à un CREATE TRIGGER.
--   • pg_policies : aucune de ces fonctions n'est référencée par une policy RLS.
-- Idempotent : IF EXISTS. Réexécutable sans erreur.
-- ============================================================================

-- credit_wallet ─ GARDÉE : (receiver_user_id uuid, credit_amount numeric)
--   [1 appelant vivant : Edge taxi-payment-process/index.ts].
-- DROP la surcharge 4-args : MORTE (l'ancien appel Node l'a quittée, il ne
-- matchait d'ailleurs aucune signature → déjà corrigé vers creditWallet()).
DROP FUNCTION IF EXISTS public.credit_wallet(uuid, numeric, text, text);

-- calculate_agent_commission ─ LES DEUX MORTES (0 appelant code/SQL/trigger/policy).
-- Moteur de commission actuel = credit_agent_commission. Suppression TOTALE :
-- élimine tout résidu de l'ancienne logique (risque de crédit sans débit PDG).
DROP FUNCTION IF EXISTS public.calculate_agent_commission(uuid, numeric, text, uuid, uuid);
DROP FUNCTION IF EXISTS public.calculate_agent_commission(uuid, character varying, numeric, uuid);

-- calculate_transfer_fee ─ LES DEUX MORTES (0 appelant, y compris interne :
-- vérifié via pg_proc.prosrc). Suppression TOTALE.
DROP FUNCTION IF EXISTS public.calculate_transfer_fee(numeric, character varying, character varying, character varying, character varying);
DROP FUNCTION IF EXISTS public.calculate_transfer_fee(numeric, text);

-- update_wallet_balance_atomic ─ GARDÉE : version UUID (p_wallet_id uuid, …, p_tx_id text)
--   [2 appelants : UniversalWalletDashboard.tsx dépôt + retrait ; wallets.id est UUID].
-- DROP la version BIGINT : MORTE (schéma d'IDs numériques abandonné).
DROP FUNCTION IF EXISTS public.update_wallet_balance_atomic(bigint, numeric, character varying, text);

-- process_wallet_transfer ─ LES DEUX MORTES (0 appelant). Suppression TOTALE.
DROP FUNCTION IF EXISTS public.process_wallet_transfer(uuid, uuid, numeric, character varying, text);
DROP FUNCTION IF EXISTS public.process_wallet_transfer(uuid, uuid, numeric, text, text);

-- process_secure_wallet_transfer ─ GARDÉE : (…, p_sender_type text, p_receiver_type text)
--   [1 appelant : TransferMoney.tsx].
-- DROP la variante (…, p_recipient_id, p_recipient_type, …) : MORTE.
DROP FUNCTION IF EXISTS public.process_secure_wallet_transfer(uuid, text, uuid, text, numeric, text);

-- process_wallet_transfer_with_fees ─ GARDÉE : version « par code »
--   (p_sender_code text, p_receiver_code text, …) [2 appelants : WalletDashboard.tsx,
--   transactionQueueService.ts].
-- DROP la variante (p_sender_id uuid, p_receiver_id uuid, …) : MORTE.
DROP FUNCTION IF EXISTS public.process_wallet_transfer_with_fees(uuid, uuid, numeric, text);

-- initiate_escrow ─ GARDÉE : version 5 args [2 appelants : useEscrowTransactions.ts,
--   EscrowService.ts].
-- DROP la version 7 args (p_auto_release_days, p_metadata) : MORTE.
DROP FUNCTION IF EXISTS public.initiate_escrow(text, uuid, uuid, numeric, text, integer, jsonb);

-- create_marketplace_order_secure ─ LES DEUX MORTES. Le flux de commande réel passe
-- par create_order_core (orders.routes.ts). Suppression TOTALE.
DROP FUNCTION IF EXISTS public.create_marketplace_order_secure(uuid, text, jsonb, jsonb, text, numeric, integer);
DROP FUNCTION IF EXISTS public.create_marketplace_order_secure(uuid, text, jsonb, jsonb, text, numeric, integer, numeric);

-- ── VÉRIFICATION (doit renvoyer 0 ligne) ────────────────────────────────────
SELECT p.proname, count(*) AS surcharges_restantes
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('credit_wallet','calculate_agent_commission','calculate_transfer_fee',
    'update_wallet_balance_atomic','process_wallet_transfer','process_secure_wallet_transfer',
    'process_wallet_transfer_with_fees','initiate_escrow','create_marketplace_order_secure')
GROUP BY p.proname HAVING count(*) > 1;
