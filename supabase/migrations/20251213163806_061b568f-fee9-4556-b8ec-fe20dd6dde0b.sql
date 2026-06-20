
-- 1. Corriger le véhicule volé avec status incorrect
UPDATE vehicles 
SET status = 'suspended' 
WHERE is_stolen = true AND status != 'suspended';

-- 2. Créer un trigger pour garantir la cohérence automatique
CREATE OR REPLACE FUNCTION enforce_stolen_vehicle_status()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Si le véhicule est déclaré volé, forcer le statut à 'suspended'
    IF NEW.is_stolen = true OR NEW.stolen_status = 'stolen' THEN
        NEW.status := 'suspended';
        NEW.security_lock_level := GREATEST(COALESCE(NEW.security_lock_level, 0), 3);
    END IF;
    
    -- Si le véhicule est récupéré, permettre le statut 'active'
    IF NEW.stolen_status = 'recovered' AND NEW.is_stolen = false THEN
        NEW.security_lock_level := 0;
    END IF;
    
    RETURN NEW;
END;
$$;

-- 3. Appliquer le trigger avant INSERT et UPDATE
DROP TRIGGER IF EXISTS enforce_stolen_status_trigger ON vehicles;
CREATE TRIGGER enforce_stolen_status_trigger
    BEFORE INSERT OR UPDATE ON vehicles
    FOR EACH ROW
    EXECUTE FUNCTION enforce_stolen_vehicle_status();

-- 4. Ajouter les colonnes manquantes pour la récupération (si absentes)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'vehicles' AND column_name = 'recovered_at') THEN
        ALTER TABLE vehicles ADD COLUMN recovered_at TIMESTAMP WITH TIME ZONE;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'vehicles' AND column_name = 'recovered_by') THEN
        ALTER TABLE vehicles ADD COLUMN recovered_by UUID;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'vehicles' AND column_name = 'recovery_notes') THEN
        ALTER TABLE vehicles ADD COLUMN recovery_notes TEXT;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'vehicles' AND column_name = 'recovery_location') THEN
        ALTER TABLE vehicles ADD COLUMN recovery_location TEXT;
    END IF;
END $$;

-- 5. Mettre à jour la vue PDG avec les bonnes stats
CREATE OR REPLACE VIEW pdg_vehicle_security_overview AS
SELECT 
    COUNT(*) FILTER (WHERE stolen_status = 'stolen' OR is_stolen = true) as total_stolen,
    COUNT(*) FILTER (WHERE stolen_status = 'recovered') as total_recovered,
    COUNT(*) FILTER (WHERE stolen_status = 'blocked') as total_blocked,
    COUNT(*) FILTER (WHERE stolen_status = 'clean' AND is_stolen = false) as total_clean,
    (SELECT COUNT(*) FROM vehicle_fraud_alerts WHERE is_resolved = false) as pending_alerts,
    (SELECT COUNT(*) FROM vehicle_security_log WHERE created_at > NOW() - INTERVAL '7 days') as events_7d,
    (SELECT COUNT(*) FROM vehicle_security_log WHERE created_at > NOW() - INTERVAL '30 days') as events_30d
FROM vehicles;
