-- ============================================================================
-- CASE B — justification des fonctions encore exposées + fermeture de money_integrity_check
-- ----------------------------------------------------------------------------
-- Après les lots 1-3, il restait 5 fonctions touchant l'argent exposées à `authenticated`. On
-- ferme celle qui peut l'être et on documente la justification des autres (COMMENT SQL).
-- ============================================================================

-- money_integrity_check : fonction de MONITORING (agrégats intégrité), AUCUN appelant frontend/backend.
-- Rien ne justifie qu'un utilisateur la lance → service_role only.
REVOKE ALL ON FUNCTION public.money_integrity_check() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.money_integrity_check() TO service_role;
COMMENT ON FUNCTION public.money_integrity_check() IS
  'Monitoring intégrité. service_role only (durci 29/07) — aucun appel utilisateur légitime.';

-- Les 4 restantes, exposées à dessein :
COMMENT ON FUNCTION public.subscribe_driver(uuid, text, text, text, text) IS
  'Exposée authenticated : souscription chauffeur appelée DIRECTEMENT par le frontend (1 appelant). '
  'À terme, faire transiter par le backend (service_role) puis REVOKE. Garde métier interne.';
COMMENT ON FUNCTION public.agent_cash_release_pending(uuid, text) IS
  'Exposée authenticated LÉGITIMEMENT : garde d''identité interne (auth.uid()) — l''agent agit sur '
  'SES propres opérations en attente.';
COMMENT ON FUNCTION public.complete_country_setup(text, text, text) IS
  'Exposée authenticated LÉGITIMEMENT : garde d''identité interne (auth.uid()).';
COMMENT ON FUNCTION public.get_shareholder_dashboard(uuid) IS
  'LECTURE (dashboard actionnaire). Exposée authenticated. ⚠️ prend p_user_id : vérifier qu''elle '
  'filtre bien sur auth.uid() (sinon IDOR lecture) avant tout durcissement — ne pas casser le dashboard.';
