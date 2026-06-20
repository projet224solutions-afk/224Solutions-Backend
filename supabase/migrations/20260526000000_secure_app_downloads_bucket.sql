-- SÉCURITÉ : Restreindre le bucket app-downloads
-- Problème : la policy SELECT était ouverte à tous les fichiers (y compris .ps1, .sql sensibles)
-- Correction : limiter le téléchargement public aux seuls APK/EXE/DMG

-- 1. Supprimer les fichiers sensibles accidentellement uploadés
DELETE FROM storage.objects
WHERE bucket_id = 'app-downloads'
  AND (
    name ILIKE '%.ps1'
    OR name ILIKE '%.sql'
    OR name ILIKE '%stripe%'
    OR name ILIKE '%configure%'
    OR name ILIKE '%secret%'
    OR name ILIKE '%key%'
    OR name ILIKE '%credential%'
    OR name ILIKE '%ssh%'
    OR name ILIKE '%password%'
    OR name ILIKE '%gcp%'
    OR name ILIKE '%env%'
  );

-- 2. Remplacer la policy publique trop permissive
DROP POLICY IF EXISTS "Public can download app files" ON storage.objects;

-- 3. Nouvelle policy : uniquement APK / EXE / DMG téléchargeables publiquement
CREATE POLICY "Public can download app files"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'app-downloads'
  AND (
    name ILIKE '%.apk'
    OR name ILIKE '%.exe'
    OR name ILIKE '%.dmg'
    OR name ILIKE '%.ipa'
  )
);
