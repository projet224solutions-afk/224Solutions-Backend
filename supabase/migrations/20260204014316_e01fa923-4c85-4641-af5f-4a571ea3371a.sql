-- Synchroniser vendors.vendor_code avec profiles.public_id (source unique de vérité)
-- Cela corrige la désynchronisation VND0011 -> VND0002, etc.

UPDATE vendors v
SET vendor_code = p.public_id
FROM profiles p
WHERE v.user_id = p.id
AND p.public_id IS NOT NULL
AND (v.vendor_code IS NULL OR v.vendor_code != p.public_id);

-- Ajouter un commentaire sur la colonne pour documenter la source de vérité
COMMENT ON COLUMN vendors.vendor_code IS 'Doit être synchronisé avec profiles.public_id - ne pas modifier directement';