-- ================================================================
-- MIGRATION: Créer les profils manquants pour les vendeurs
-- Date: 2026-01-10
-- Objectif: Rendre les vendeurs du marketplace visibles dans l'interface PDG
-- ================================================================

-- Étape 1: Créer les profils manquants pour les utilisateurs de professional_services
INSERT INTO profiles (
  id,
  email,
  first_name,
  last_name,
  role,
  is_active,
  status,
  created_at,
  updated_at
)
SELECT DISTINCT
  ps.user_id,
  COALESCE(u.email, 'email@inconnu.com'),                           -- Email depuis auth.users
  COALESCE(SPLIT_PART(ps.business_name, ' ', 1), ps.business_name), -- Prénom = 1er mot du business_name
  COALESCE(NULLIF(SPLIT_PART(ps.business_name, ' ', 2), ''), ''),  -- Nom = 2ème mot (si existe)
  'vendeur',                                                         -- Rôle vendeur
  ps.status = 'active',                                              -- Actif si service actif
  CASE 
    WHEN ps.status = 'active' THEN 'active'
    WHEN ps.status = 'pending' THEN 'pending'
    ELSE 'inactive'
  END,
  ps.created_at,
  NOW()
FROM professional_services ps
JOIN auth.users u ON ps.user_id = u.id
WHERE NOT EXISTS (
  SELECT 1 FROM profiles p WHERE p.id = ps.user_id
)
ON CONFLICT (id) DO NOTHING;

-- Étape 2: Log de l'opération
DO $$
DECLARE
  nb_profiles_crees INTEGER;
BEGIN
  SELECT COUNT(*)
  INTO nb_profiles_crees
  FROM profiles
  WHERE role = 'vendeur'
    AND updated_at >= NOW() - INTERVAL '1 minute';
  
  RAISE NOTICE '✅ % profil(s) créé(s) pour les vendeurs du marketplace', nb_profiles_crees;
END $$;

-- Étape 3: Vérifier que tous les vendeurs ont maintenant un profil
DO $$
DECLARE
  nb_vendeurs_sans_profil INTEGER;
BEGIN
  SELECT COUNT(DISTINCT ps.user_id)
  INTO nb_vendeurs_sans_profil
  FROM professional_services ps
  WHERE NOT EXISTS (
    SELECT 1 FROM profiles p WHERE p.id = ps.user_id
  );
  
  IF nb_vendeurs_sans_profil > 0 THEN
    RAISE WARNING '⚠️  Il reste % vendeur(s) sans profil', nb_vendeurs_sans_profil;
  ELSE
    RAISE NOTICE '✅ Tous les vendeurs ont un profil';
  END IF;
END $$;

-- Étape 4: Créer les public_id manquants
UPDATE profiles
SET public_id = CONCAT('U', LPAD(id_sequence.nextval::TEXT, 8, '0'))
FROM (
  SELECT NEXTVAL('user_id_sequence') as nextval, id
  FROM profiles
  WHERE public_id IS NULL AND role = 'vendeur'
) AS id_sequence
WHERE profiles.id = id_sequence.id
  AND profiles.public_id IS NULL;

-- Note: Si la séquence n'existe pas, elle sera créée par le trigger normal
-- Cette étape est optionnelle et ne cassera rien si la séquence est absente

-- Commentaire final
COMMENT ON TABLE profiles IS 'Table des profils utilisateurs - Mise à jour 2026-01-10: Profils vendeurs créés automatiquement';
