-- Ajouter la colonne updated_at à system_errors
ALTER TABLE system_errors 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();

-- Initialiser updated_at avec created_at pour les enregistrements existants
UPDATE system_errors 
SET updated_at = created_at 
WHERE updated_at IS NULL;

-- Créer un trigger pour auto-mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_system_errors_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_system_errors_updated_at ON system_errors;
CREATE TRIGGER trigger_update_system_errors_updated_at
  BEFORE UPDATE ON system_errors
  FOR EACH ROW
  EXECUTE FUNCTION update_system_errors_updated_at();