-- Créer le bucket pour les enregistrements SOS
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'sos-recordings', 
  'sos-recordings', 
  false,
  52428800, -- 50MB max
  ARRAY['video/webm', 'video/mp4', 'audio/webm', 'audio/mp3', 'audio/wav']
)
ON CONFLICT (id) DO NOTHING;

-- Policies pour le bucket sos-recordings

-- Les conducteurs peuvent uploader leurs propres enregistrements SOS
CREATE POLICY "Conducteurs peuvent uploader SOS recordings"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'sos-recordings' 
  AND auth.uid() IS NOT NULL
);

-- Les conducteurs peuvent voir leurs propres enregistrements
CREATE POLICY "Conducteurs peuvent voir leurs SOS recordings"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'sos-recordings'
  AND auth.uid() IS NOT NULL
);

-- Les bureaux syndicats peuvent voir tous les enregistrements SOS
CREATE POLICY "Bureaux peuvent voir tous les SOS recordings"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'sos-recordings'
  AND EXISTS (
    SELECT 1 FROM public.bureaus 
    WHERE user_id = auth.uid()
  )
);

-- Vérifier et ajouter les colonnes manquantes à sos_media si nécessaire
ALTER TABLE public.sos_media 
ADD COLUMN IF NOT EXISTS file_size_bytes INTEGER,
ADD COLUMN IF NOT EXISTS thumbnail_url TEXT,
ADD COLUMN IF NOT EXISTS uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT now();

-- Ajouter colonne recording_url à sos_alerts pour lien vers l'enregistrement auto
ALTER TABLE public.sos_alerts
ADD COLUMN IF NOT EXISTS recording_url TEXT,
ADD COLUMN IF NOT EXISTS recording_started_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS recording_stopped_at TIMESTAMP WITH TIME ZONE;

-- Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_sos_alerts_status ON public.sos_alerts(status);
CREATE INDEX IF NOT EXISTS idx_sos_alerts_taxi_driver ON public.sos_alerts(taxi_driver_id);
CREATE INDEX IF NOT EXISTS idx_sos_media_alert ON public.sos_media(sos_alert_id);