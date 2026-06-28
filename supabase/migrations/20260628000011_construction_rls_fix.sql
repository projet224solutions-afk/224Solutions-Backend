-- ============================================================================
-- BTP — CORRECTION 1 : confidentialité RLS.
-- Les policies *_public_read (USING true) exposaient projets/jalons/journaux de
-- TOUS les chantiers (montants inclus) à tout authentifié. On les supprime.
--
-- ⚠️ NE PAS retirer la lecture sans filet : le flux « lien partagé » (le client
-- ouvre /chantier/:id AVANT de réclamer le chantier) lit le projet + jalons +
-- journaux DIRECTEMENT via supabase (RLS) tant que client_user_id IS NULL
-- (cf ConstructionClientView.loadProject + useProjectDetail). Une suppression
-- brutale casserait l'onboarding client (projet introuvable → claim impossible).
--
-- SOLUTION : lecture publique limitée aux projets NON RÉCLAMÉS (client_user_id
-- IS NULL). Les projets RÉCLAMÉS ne sont visibles QUE par le prestataire
-- (cproj_owner FOR ALL) et le client (cproj_client_read) → fuite fermée.
-- ============================================================================

BEGIN;

-- 1. Supprimer les lectures publiques globales (USING true)
DROP POLICY IF EXISTS cproj_public_read ON public.construction_projects;
DROP POLICY IF EXISTS cmile_public_read ON public.construction_milestones;
DROP POLICY IF EXISTS clog_public_read  ON public.construction_daily_logs;

-- 2. Lecture des chantiers NON RÉCLAMÉS uniquement (flux de réclamation par lien).
--    Owner + client gardent leur accès via les policies existantes
--    (cproj_owner / cproj_client_read / cmile_owner / cmile_client_read /
--     clog_owner_sel) — inchangées.
DROP POLICY IF EXISTS cproj_unclaimed_read ON public.construction_projects;
CREATE POLICY cproj_unclaimed_read ON public.construction_projects
  FOR SELECT TO authenticated
  USING (client_user_id IS NULL);

DROP POLICY IF EXISTS cmile_unclaimed_read ON public.construction_milestones;
CREATE POLICY cmile_unclaimed_read ON public.construction_milestones
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.construction_projects p
    WHERE p.id = project_id AND p.client_user_id IS NULL
  ));

DROP POLICY IF EXISTS clog_unclaimed_read ON public.construction_daily_logs;
CREATE POLICY clog_unclaimed_read ON public.construction_daily_logs
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.construction_projects p
    WHERE p.id = project_id AND p.client_user_id IS NULL
  ));

-- 3. Garde-fou : plus aucune policy en lecture totalement publique (USING true)
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM pg_policies
  WHERE tablename IN ('construction_projects','construction_milestones','construction_daily_logs')
    AND qual = 'true';
  IF v_count > 0 THEN
    RAISE EXCEPTION 'Il reste % policy(ies) en lecture publique (USING true)', v_count;
  END IF;
  RAISE NOTICE '✅ Lectures publiques BTP supprimées (reste : non-réclamés pour le lien)';
END; $$;

COMMIT;
