-- Ajouter les colonnes pour les réponses IA dans vendor_ratings
ALTER TABLE vendor_ratings 
ADD COLUMN IF NOT EXISTS ai_suggested_response TEXT,
ADD COLUMN IF NOT EXISTS ai_response_status VARCHAR(20) DEFAULT 'none',
ADD COLUMN IF NOT EXISTS ai_analyzed_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS ai_sentiment VARCHAR(20);

-- Créer un index pour filtrer les avis avec réponses IA en attente
CREATE INDEX IF NOT EXISTS idx_vendor_ratings_ai_status ON vendor_ratings(vendor_id, ai_response_status);

-- Ajouter une contrainte de validation pour le statut
ALTER TABLE vendor_ratings 
DROP CONSTRAINT IF EXISTS vendor_ratings_ai_response_status_check;

ALTER TABLE vendor_ratings 
ADD CONSTRAINT vendor_ratings_ai_response_status_check 
CHECK (ai_response_status IN ('none', 'pending', 'approved', 'rejected', 'published'));

COMMENT ON COLUMN vendor_ratings.ai_suggested_response IS 'Réponse suggérée par l''IA - en attente de validation';
COMMENT ON COLUMN vendor_ratings.ai_response_status IS 'Statut: none, pending, approved, rejected, published';
COMMENT ON COLUMN vendor_ratings.ai_analyzed_at IS 'Date d''analyse par l''IA';
COMMENT ON COLUMN vendor_ratings.ai_sentiment IS 'Sentiment détecté: positive, neutral, negative, critical';