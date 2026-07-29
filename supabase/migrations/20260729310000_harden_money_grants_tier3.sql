-- ============================================================================
-- DURCISSEMENT GRANTs — lot 3 (final) : triggers + flux métier/paiement (case B)
-- ----------------------------------------------------------------------------
-- Dernier lot de l'inventaire. REVOKE de anon/authenticated → service_role, pour :
--   * 4 triggers (grant inoffensif : invoqués en contexte trigger, REVOKE ne les casse pas) +
--     audit_money_function_ddl (event trigger DDL) ;
--   * flux métier/paiement appelés en service_role (supabaseAdmin) au backend ou sans appelant
--     (0 appel frontend direct). VÉRIFIÉ : cancel_restaurant_order/process_pharmacy_order/
--     apply_platform_commission = supabaseAdmin ; fx_convert/pay_*_delivery/process_digital_*/
--     record_service_subscription_payment/subscribe_user = 0 appelant → dead/interne.
-- NON touchés (légitimes) : subscribe_driver (1 appel frontend), agent_cash_release_pending &
-- complete_country_setup (garde auth.uid interne), get_shareholder_dashboard & money_integrity_check
-- (LECTURES). REVOKE = pur durcissement, zéro régression.
-- ============================================================================

-- Triggers (défensif) + event trigger.
REVOKE ALL ON FUNCTION public.credit_pdg_wallet_on_revenue() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.credit_pdg_wallet_on_revenue() TO service_role;
REVOKE ALL ON FUNCTION public.on_commission_validated() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.on_commission_validated() TO service_role;
REVOKE ALL ON FUNCTION public.shareholder_payment_track_cap() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.shareholder_payment_track_cap() TO service_role;
REVOKE ALL ON FUNCTION public.tg_profile_country_sync_wallet() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.tg_profile_country_sync_wallet() TO service_role;
REVOKE ALL ON FUNCTION public.audit_money_function_ddl() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.audit_money_function_ddl() TO service_role;

-- Flux métier / paiement (service_role only).
REVOKE ALL ON FUNCTION public.apply_platform_commission(uuid, numeric, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.apply_platform_commission(uuid, numeric, text, uuid, jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.cancel_restaurant_order(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cancel_restaurant_order(uuid, text) TO service_role;
REVOKE ALL ON FUNCTION public.fx_convert(text, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fx_convert(text, numeric, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.pay_pharmacy_delivery(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_pharmacy_delivery(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.pay_restaurant_delivery(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_restaurant_delivery(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.process_digital_subscription_renewal(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.process_digital_subscription_renewal(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.process_pharmacy_order(uuid, uuid, uuid, numeric, jsonb, text, text, text, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.process_pharmacy_order(uuid, uuid, uuid, numeric, jsonb, text, text, text, numeric, text) TO service_role;
REVOKE ALL ON FUNCTION public.record_service_subscription_payment(uuid, uuid, uuid, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_service_subscription_payment(uuid, uuid, uuid, numeric, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.subscribe_user(uuid, uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.subscribe_user(uuid, uuid, text, text, text) TO service_role;
