-- ═══════════════════════════════════════════════════════════════════════════
-- BALAYAGE VAGUE 1.3 — Fermer les RPC SECURITY DEFINER d'ARGENT exposées à anon.
-- Une RPC qui déplace de l'argent, journalise un revenu, ou expose des stats de
-- revenu NE DOIT JAMAIS être appelable par anon. On REVOKE anon (+ PUBLIC), et on
-- GRANT au rôle strictement nécessaire (service_role pour l'interne système ;
-- authenticated pour les flux utilisateur). Non-régressif : les appelants légitimes
-- (backend service_role, utilisateurs authentifiés) conservent leur accès.
-- NON touchés (par design) : agent_record_cash_sale/expense (token-scopés, anon requis
-- car les agents n'ont pas de JWT — protégés par le token DANS la fonction) ; les
-- previews/lookups en lecture seule (QR public) ; les calculateurs purs ; les triggers.
-- ═══════════════════════════════════════════════════════════════════════════

-- Revenu coffre PDG (crédite la trésorerie) → service_role SEULEMENT (les 2 surcharges).
REVOKE ALL ON FUNCTION public.record_pdg_revenue(text, numeric, numeric, uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_pdg_revenue(text, numeric, numeric, uuid, uuid, uuid, jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.record_pdg_revenue(text, numeric, numeric, uuid, uuid, uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_pdg_revenue(text, numeric, numeric, uuid, uuid, uuid, jsonb, text) TO service_role;

-- Enregistrement d'un paiement d'abonnement (argent) → authenticated + service_role.
REVOKE ALL ON FUNCTION public.record_subscription_payment(uuid, uuid, numeric, text, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_subscription_payment(uuid, uuid, numeric, text, text, text) TO authenticated, service_role;

-- Machine à états transfert/escrow (déplace des fonds) → authenticated + service_role.
REVOKE ALL ON FUNCTION public.receive_transfer(uuid, jsonb, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.receive_transfer(uuid, jsonb, uuid, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.ship_transfer(uuid, uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.ship_transfer(uuid, uuid, text) TO authenticated, service_role;

-- FX interne (collecteur) → service_role SEULEMENT.
REVOKE ALL ON FUNCTION public.record_fx_scrape_failure(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_fx_scrape_failure(text) TO service_role;
REVOKE ALL ON FUNCTION public.record_fx_scrape_success(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.record_fx_scrape_success(text) TO service_role;

-- Stats de revenu (fuite d'info si anon) → authenticated (le dashboard PDG a un JWT).
REVOKE ALL ON FUNCTION public.get_pdg_revenue_stats(timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_pdg_revenue_stats(timestamptz, timestamptz) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_platform_revenue_stats(timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_platform_revenue_stats(timestamptz, timestamptz) TO authenticated, service_role;
