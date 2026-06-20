-- Migration pour les paramètres POS
-- Créée le 01/12/2024

-- Table pour les paramètres du système POS
CREATE TABLE IF NOT EXISTS pos_settings (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
    company_name TEXT NOT NULL DEFAULT 'Mon Commerce',
    tax_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    tax_rate DECIMAL(5,4) NOT NULL DEFAULT 0.18, -- 18% par défaut
    currency TEXT NOT NULL DEFAULT 'FCFA',
    receipt_footer TEXT DEFAULT 'Merci de votre visite !',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id)
);

-- Index pour optimiser les requêtes
CREATE INDEX IF NOT EXISTS idx_pos_settings_user_id ON pos_settings(user_id);

-- RLS (Row Level Security)
ALTER TABLE pos_settings ENABLE ROW LEVEL SECURITY;

-- Politique : Les utilisateurs peuvent voir et modifier leurs propres paramètres
CREATE POLICY "Users can manage their own POS settings" ON pos_settings
FOR ALL USING (auth.uid() = user_id);

-- Fonction pour mettre à jour automatiquement updated_at
CREATE OR REPLACE FUNCTION update_pos_settings_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger pour mettre à jour updated_at automatiquement
CREATE TRIGGER pos_settings_updated_at
    BEFORE UPDATE ON pos_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_pos_settings_updated_at();

-- Insérer des paramètres par défaut pour les vendeurs existants
INSERT INTO pos_settings (user_id, company_name, tax_enabled, tax_rate, currency, receipt_footer)
SELECT 
    p.id,
    COALESCE(p.full_name || ' Commerce', 'Mon Commerce'),
    TRUE,
    0.18,
    'FCFA',
    'Merci de votre visite !'
FROM profiles p
WHERE p.role = 'vendeur' 
AND NOT EXISTS (SELECT 1 FROM pos_settings ps WHERE ps.user_id = p.id)
ON CONFLICT (user_id) DO NOTHING;
