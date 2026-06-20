-- Créer la table pour stocker les médias SOS
CREATE TABLE IF NOT EXISTS sos_media (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sos_alert_id UUID NOT NULL,
  driver_id UUID,
  driver_name TEXT,
  media_type TEXT NOT NULL CHECK (media_type IN ('audio', 'video')),
  file_path TEXT NOT NULL,
  file_url TEXT NOT NULL,
  duration_seconds INTEGER DEFAULT 0,
  is_viewed BOOLEAN DEFAULT false,
  viewed_at TIMESTAMPTZ,
  viewed_by TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Index pour les requêtes
CREATE INDEX IF NOT EXISTS idx_sos_media_alert_id ON sos_media(sos_alert_id);
CREATE INDEX IF NOT EXISTS idx_sos_media_driver_id ON sos_media(driver_id);
CREATE INDEX IF NOT EXISTS idx_sos_media_created_at ON sos_media(created_at DESC);

-- Activer Realtime
ALTER TABLE sos_media REPLICA IDENTITY FULL;

-- RLS policies
ALTER TABLE sos_media ENABLE ROW LEVEL SECURITY;

-- Politique de lecture : tout le monde peut voir les médias SOS
CREATE POLICY "Anyone can view SOS media" 
ON sos_media 
FOR SELECT 
USING (true);

-- Politique d'insertion : utilisateurs authentifiés peuvent créer
CREATE POLICY "Authenticated users can create SOS media" 
ON sos_media 
FOR INSERT 
WITH CHECK (auth.uid() IS NOT NULL);

-- Politique de mise à jour : utilisateurs authentifiés peuvent mettre à jour
CREATE POLICY "Authenticated users can update SOS media" 
ON sos_media 
FOR UPDATE 
USING (true);