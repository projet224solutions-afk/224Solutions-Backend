-- ============================================================================
-- DURCISSEMENT GRANTs — lot 2 (case B) : flux métier/agent appelés en service_role
-- ----------------------------------------------------------------------------
-- Suite de l'inventaire. Ces fonctions mutent un solde et étaient exposées à `authenticated`.
-- VÉRIFIÉ : appelées UNIQUEMENT via `supabaseAdmin` (service_role) dans les routes backend Node
-- (ou 0 appelant = mortes) ; AUCUN appel direct frontend. Le frontend passe par le backend, jamais
-- par PostgREST direct → REVOKE de `authenticated` = 0 régression.
-- (Non touchés ici, à auditer séparément : apply_platform_commission [client edge ambigu],
--  subscribe_driver [1 appel frontend], get_shareholder_dashboard/money_integrity_check [LECTURES],
--  agent_cash_release_pending/complete_country_setup [garde auth.uid() interne = légitimes user].)
-- ============================================================================

REVOKE ALL ON FUNCTION public.create_order_core(text, uuid, uuid, uuid, text, text, jsonb, text, jsonb, integer, uuid, numeric, text, numeric, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.create_order_core(text, uuid, uuid, uuid, text, text, jsonb, text, jsonb, integer, uuid, numeric, text, numeric, numeric, numeric) TO service_role;

REVOKE ALL ON FUNCTION public.process_restaurant_order(uuid, uuid, numeric, jsonb, text, integer, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.process_restaurant_order(uuid, uuid, numeric, jsonb, text, integer, text, text, text) TO service_role;

REVOKE ALL ON FUNCTION public.process_restaurant_order(uuid, uuid, numeric, jsonb, text, integer, text, text, text, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.process_restaurant_order(uuid, uuid, numeric, jsonb, text, integer, text, text, text, numeric, text) TO service_role;

REVOKE ALL ON FUNCTION public.pay_supplier_debt(uuid, uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_supplier_debt(uuid, uuid, numeric, text) TO service_role;

REVOKE ALL ON FUNCTION public.agent_commission_withdrawal_request(uuid, numeric, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.agent_commission_withdrawal_request(uuid, numeric, text, jsonb, text) TO service_role;

REVOKE ALL ON FUNCTION public._acash_fx(numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._acash_fx(numeric, text, text) TO service_role;

REVOKE ALL ON FUNCTION public.agent_cash_wallet_ok(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.agent_cash_wallet_ok(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.agent_activate_cash(uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.agent_activate_cash(uuid, numeric, text) TO service_role;

REVOKE ALL ON FUNCTION public.execute_banking_transaction(text, uuid, text, uuid, uuid, numeric, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.execute_banking_transaction(text, uuid, text, uuid, uuid, numeric, text, text, text, jsonb) TO service_role;

REVOKE ALL ON FUNCTION public.validate_secure_payment(uuid, text, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.validate_secure_payment(uuid, text, numeric, text, text, text) TO service_role;
