-- ============================================================================
-- 🔒 registered_motos : fermer la sur-exposition PII cross-bureau du rôle 'syndicat'
-- ----------------------------------------------------------------------------
-- Résidu trouvé par la re-vérif adverse : après le scope de 20260705170002, une policy
-- SELECT survivante « Users can view motos they created » (migration 20251029222212)
-- restait OR-ée et exposait owner_name/owner_phone/plate_number (PII) de TOUTES les
-- motos, cross-bureau, à TOUT compte de rôle 'syndicat' (branche
-- `EXISTS profiles WHERE role IN ('admin','syndicat')`).
--
-- Modèle réel vérifié : un syndicat président est le propriétaire de SON bureau
-- (bureaus.user_id = auth.uid()). Le scope par bureau (migration 170002) le couvre donc
-- déjà pour SES motos. On retire la branche 'syndicat' globale et on recrée la policy
-- « créateur » proprement scopée : le worker créateur, l'admin, et le bureau propriétaire
-- (via bureaus.user_id). Plus AUCUN accès cross-bureau à la PII pour un rôle non-admin.
--
-- (La page publique bureau — accès anon — passera par un endpoint backend service_role
--  renvoyant des colonnes SANS PII : TODO backend documenté, non bloquant ici.)
-- Idempotent (DROP+CREATE).
-- ============================================================================

DROP POLICY IF EXISTS "Users can view motos they created" ON public.registered_motos;
CREATE POLICY "Users can view motos they created"
ON public.registered_motos
FOR SELECT
TO authenticated
USING (
  worker_id = auth.uid()
  OR public.is_admin()
  OR bureau_id IN (SELECT id FROM public.bureaus WHERE user_id = auth.uid())
);

SELECT 'registered_motos : branche rôle ''syndicat'' cross-bureau retiree — PII scopee au createur / admin / bureau proprietaire.' AS status;
