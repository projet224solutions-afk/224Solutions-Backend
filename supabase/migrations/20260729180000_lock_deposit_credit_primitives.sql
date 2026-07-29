-- ============================================================================
-- VERROU DÉPÔTS — aucune primitive de crédit appelable via PostgREST (anon/authenticated)
-- ----------------------------------------------------------------------------
-- Contexte : audit « aucun crédit wallet sans paiement réel encaissé ».
-- Deux primitives SECURITY DEFINER de crédit étaient exposées au rôle `authenticated`
-- alors qu'elles NE vérifient PAS le caller :
--   * credit_user_wallet_safe(...)  → un simple JWT connecté pouvait se créditer
--     via supabase.rpc('credit_user_wallet_safe', {p_user_id:<soi>, p_amount:1e9}).
--     (p_source_txn_id NULL ⇒ pas d'idempotence ⇒ rejeu illimité = argent gratuit.)
--   * agent_cash_deposit(...)       → p_agent_id est un PARAMÈTRE non lié à auth.uid()
--     ⇒ IDOR : vider le float d'un AUTRE agent vers son propre wallet.
--
-- Tous les appelants légitimes passent par service_role (backend supabaseAdmin) ou sont
-- des SECURITY DEFINER internes (execute_atomic_deposit, settle_qr_card_payment,
-- agent_cash_deposit lui-même) dont l'appel imbriqué ne dépend PAS du GRANT EXECUTE.
-- Vérifié : aucun appel direct depuis le frontend (client anon). ⇒ REVOKE = pur
-- durcissement, zéro régression. Filet idempotent sur les fonctions déjà verrouillées.
-- ============================================================================

REVOKE ALL ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.credit_user_wallet_safe(uuid, numeric, text, text, text) TO service_role;

REVOKE ALL ON FUNCTION public.agent_cash_deposit(uuid, uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.agent_cash_deposit(uuid, uuid, numeric, text) TO service_role;

-- Filet défensif : déjà service_role-only, on réaffirme (no-op si inchangé).
REVOKE ALL ON FUNCTION public.execute_atomic_deposit(uuid, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.execute_atomic_deposit(uuid, numeric, text, text, text) TO service_role;
