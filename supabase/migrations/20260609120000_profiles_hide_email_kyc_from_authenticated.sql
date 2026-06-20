-- ============================================================================
-- SÉCURITÉ — Cacher email + kyc des profils aux utilisateurs CONNECTÉS (cross-user)
-- ----------------------------------------------------------------------------
-- Audit (2026-06-09) : la policy profiles « USING (true) » (profils visibles pour
-- recherche) laisse TOUT utilisateur connecté lire l'email + kyc_level de N'IMPORTE
-- QUEL autre utilisateur (récolte d'emails par un compte inscrit). Les noms/avatars
-- cross-user sont LÉGITIMES (chat, listes, suivi) → on garde la lecture des lignes,
-- mais on RETIRE les colonnes sensibles via des privilèges au niveau COLONNE.
--
-- ⚠️ ORDRE DE DÉPLOIEMENT : appliquer CETTE migration APRÈS avoir déployé le frontend
-- + backend repointés (sinon l'ancien front qui lit profiles.email casse). Les lectures
-- d'email légitimes (PDG litiges/vendeurs) passent désormais par /api/admin/user-emails
-- (service_role). L'email propre de l'utilisateur vient de la session auth.
--
-- Méthode (comme vendors) : retirer le SELECT pleine-table à authenticated puis ne
-- re-granter QUE les colonnes non sensibles (allow-list). email, kyc_level,
-- kyc_verified_at deviennent illisibles côté client. La RLS (lignes) est inchangée.
-- service_role (backend) n'est pas affecté. Non destructif, rejouable.
-- ============================================================================

REVOKE SELECT ON public.profiles FROM authenticated;

GRANT SELECT (
  id,
  phone,                    -- utilisé par taxi/livraison/agent (contact) ; non visé ici
  first_name,
  last_name,
  full_name,
  avatar_url,
  role,
  is_active,
  status,
  public_id,
  custom_id,
  country,
  country_code,
  city,
  created_at,
  updated_at,
  detected_country,
  detected_currency,
  detected_language,
  geo_detection_method,
  last_geo_update,
  has_password,
  preferred_language,
  auto_translate_audio,
  profile_completed
) ON public.profiles TO authenticated;

SELECT 'profiles : email + kyc_level + kyc_verified_at cachés aux utilisateurs connectés (lecture via backend pour le PDG).' AS status;
