-- ═══════════════════════════════════════════════════════════════════════════
-- FERMER margin_config DE MANIÈRE DÉTERMINISTE (la faille « rouverte »).
-- Constat : prod a des policies PDG-only posées HORS-migration (dashboard) → le repo
-- était incohérent (la migration de mars recréait des policies permissives sur un
-- fresh build). Cette migration AUTORITAIRE remet l'état voulu quel que soit l'ordre :
-- SELECT public (taux publics), ÉCRITURE = PDG/service_role SEULEMENT (aligné fx_pair_config).
-- Idempotente : DROP de TOUS les noms de policies d'écriture connus, puis 1 policy PDG propre.
-- ═══════════════════════════════════════════════════════════════════════════

-- Retirer toutes les policies d'écriture existantes (permissives héritées OU PDG posées hors-migration).
DROP POLICY IF EXISTS "Auth can update margin_config" ON public.margin_config;
DROP POLICY IF EXISTS "Auth can insert margin_config" ON public.margin_config;
DROP POLICY IF EXISTS "Authenticated can update margin_config" ON public.margin_config;
DROP POLICY IF EXISTS "Authenticated can insert margin_config" ON public.margin_config;
DROP POLICY IF EXISTS margin_config_write_all ON public.margin_config;
DROP POLICY IF EXISTS "PDG can update margin_config" ON public.margin_config;
DROP POLICY IF EXISTS "PDG can insert margin_config" ON public.margin_config;
DROP POLICY IF EXISTS "PDG can delete margin_config" ON public.margin_config;
DROP POLICY IF EXISTS "margin_config write pdg" ON public.margin_config;

-- SELECT public conservé (les taux/la marge sont des données publiques d'affichage).
DROP POLICY IF EXISTS "Anyone can view margin_config" ON public.margin_config;
CREATE POLICY "Anyone can view margin_config" ON public.margin_config FOR SELECT USING (true);

-- ÉCRITURE = PDG uniquement (is_admin_or_pdg, comme fx_pair_config). service_role bypasse la RLS.
CREATE POLICY margin_config_pdg_write ON public.margin_config FOR ALL TO authenticated
  USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());

COMMENT ON TABLE public.margin_config IS
  'DÉPRÉCIÉ (Fatome V2) : la marge par paire vit dans fx_pair_config (fx_effective_margin_fraction). margin_config = seed du défaut global + compat LECTURE. Écriture PDG-only ; ne plus écrire ici (source unique = fx_pair_config).';
