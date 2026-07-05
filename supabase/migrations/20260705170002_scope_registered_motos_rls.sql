-- ============================================================================
-- 🔒 CORRECTIF : registered_motos — la lecture ne doit PAS exposer la PII à
--    TOUT utilisateur authentifié.
-- ----------------------------------------------------------------------------
-- BUG (audit 2026-07-05) : la policy « Authenticated can view registered_motos
-- with valid bureau » (20260705130000) était USING (bureau_id IN (SELECT id FROM
-- bureaus WHERE access_token IS NOT NULL)) → effectivement `true` pour tout
-- authenticated (tous les bureaux ont un access_token). Elle exposait owner_name /
-- owner_phone / plate_number (PII) de TOUTES les motos à n'importe quel compte,
-- sans aucun lien légitime.
--
-- FIX : scoper la lecture au PROPRIÉTAIRE DU BUREAU (bureaus.user_id = auth.uid())
-- — le président de bureau voit les motos de SON bureau — ou aux admins/PDG.
-- Aucun autre authenticated ne peut lire la PII. La page publique d'un bureau
-- (accès anon via access_token) DOIT passer par un endpoint backend (service_role)
-- renvoyant des colonnes sans PII (TODO backend documenté) — jamais d'accès direct.
-- Idempotent (DROP+CREATE policy).
-- ============================================================================

DROP POLICY IF EXISTS "Authenticated can view registered_motos with valid bureau" ON public.registered_motos;
DROP POLICY IF EXISTS "Public can view registered_motos with valid bureau" ON public.registered_motos;

CREATE POLICY "Bureau owner can view own registered_motos"
ON public.registered_motos
FOR SELECT
TO authenticated
USING (
  public.is_admin()
  OR bureau_id IN (
    SELECT id FROM public.bureaus WHERE user_id = auth.uid()
  )
);

SELECT 'FIX registered_motos : lecture scopée au propriétaire du bureau (bureaus.user_id) + admin ; PII fermée aux autres authenticated (affichage public bureau = endpoint backend sans PII).' AS status;
