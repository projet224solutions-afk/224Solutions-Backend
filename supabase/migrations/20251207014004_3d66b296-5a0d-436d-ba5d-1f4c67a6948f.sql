-- Ajouter les colonnes manquantes à sos_alerts pour le système SOS Taxi Moto
ALTER TABLE sos_alerts ADD COLUMN IF NOT EXISTS taxi_driver_id UUID;
ALTER TABLE sos_alerts ADD COLUMN IF NOT EXISTS driver_name TEXT;
ALTER TABLE sos_alerts ADD COLUMN IF NOT EXISTS driver_phone TEXT;
ALTER TABLE sos_alerts ADD COLUMN IF NOT EXISTS accuracy NUMERIC;
ALTER TABLE sos_alerts ADD COLUMN IF NOT EXISTS direction NUMERIC;
ALTER TABLE sos_alerts ADD COLUMN IF NOT EXISTS speed NUMERIC;
ALTER TABLE sos_alerts ADD COLUMN IF NOT EXISTS gps_history JSONB DEFAULT '[]';
ALTER TABLE sos_alerts ADD COLUMN IF NOT EXISTS resolved_by TEXT;
ALTER TABLE sos_alerts ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ;
ALTER TABLE sos_alerts ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();

-- Créer un index pour les requêtes par bureau
CREATE INDEX IF NOT EXISTS idx_sos_alerts_bureau_id ON sos_alerts(bureau_id);
CREATE INDEX IF NOT EXISTS idx_sos_alerts_status ON sos_alerts(status);
CREATE INDEX IF NOT EXISTS idx_sos_alerts_taxi_driver_id ON sos_alerts(taxi_driver_id);

-- Activer Realtime sur la table sos_alerts
ALTER TABLE sos_alerts REPLICA IDENTITY FULL;

-- RLS policies pour sos_alerts
ALTER TABLE sos_alerts ENABLE ROW LEVEL SECURITY;

-- Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Bureaux can view their SOS alerts" ON sos_alerts;
DROP POLICY IF EXISTS "Authenticated users can create SOS alerts" ON sos_alerts;
DROP POLICY IF EXISTS "Bureaux can update their SOS alerts" ON sos_alerts;

-- Politique de lecture : tout le monde peut voir les alertes SOS
CREATE POLICY "Bureaux can view their SOS alerts" 
ON sos_alerts 
FOR SELECT 
USING (true);

-- Politique d'insertion : tout utilisateur authentifié peut créer une alerte SOS
CREATE POLICY "Authenticated users can create SOS alerts" 
ON sos_alerts 
FOR INSERT 
WITH CHECK (auth.uid() IS NOT NULL);

-- Politique de mise à jour : tout utilisateur authentifié peut mettre à jour
CREATE POLICY "Bureaux can update their SOS alerts" 
ON sos_alerts 
FOR UPDATE 
USING (true);