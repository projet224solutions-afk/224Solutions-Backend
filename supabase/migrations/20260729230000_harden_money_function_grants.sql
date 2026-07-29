-- ============================================================================
-- DURCISSEMENT GRANTs (prompt « atomique/blindé/surveillé », case B) — circuit 8 + primitives
-- ----------------------------------------------------------------------------
-- Inventaire : 35 fonctions SECURITY DEFINER touchant un solde étaient exposées à anon/authenticated.
-- Beaucoup sont des triggers (grant inoffensif) ou des flux user légitimes (commandes, abonnements —
-- à auditer identité par identité, non touchés ici). Ce lot REVOKE le sous-ensemble NON AMBIGU :
-- primitives internes de mutation de solde + processeurs prestataire/règlement + escrow release +
-- enregistrement de revenu — JAMAIS destinés à un appel direct client. Vérifié : 0 appel frontend ;
-- le backend les appelle en service_role. REVOKE = pur durcissement, zéro régression.
--   🔴 auto_release_escrows() : sans argument, SECURITY DEFINER, GRANT anon → n'importe qui pouvait
--      FORCER la libération de tous les escrows éligibles (créditer des vendeurs). Fermé.
-- ============================================================================

REVOKE ALL ON FUNCTION public._acash_credit_wallet(bigint, numeric) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._acash_credit_wallet(bigint, numeric) TO service_role;

REVOKE ALL ON FUNCTION public._acash_debit_wallet(bigint, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._acash_debit_wallet(bigint, numeric, text) TO service_role;

REVOKE ALL ON FUNCTION public.update_wallet_balance_atomic(uuid, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.update_wallet_balance_atomic(uuid, numeric, text, text) TO service_role;

REVOKE ALL ON FUNCTION public.auto_release_escrows() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.auto_release_escrows() TO service_role;

REVOKE ALL ON FUNCTION public.agent_cash_settle_deposit_lots() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.agent_cash_settle_deposit_lots() TO service_role;

REVOKE ALL ON FUNCTION public.process_djomy_success(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.process_djomy_success(uuid, jsonb) TO service_role;

REVOKE ALL ON FUNCTION public.settle_payment_link_atomic(uuid, uuid, numeric, numeric, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.settle_payment_link_atomic(uuid, uuid, numeric, numeric, text, text, text, text) TO service_role;

REVOKE ALL ON FUNCTION public.record_platform_revenue(text, numeric, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_platform_revenue(text, numeric, uuid, jsonb) TO service_role;

REVOKE ALL ON FUNCTION public.process_card_to_om(uuid, text, text, numeric) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.process_card_to_om(uuid, text, text, numeric) TO service_role;
