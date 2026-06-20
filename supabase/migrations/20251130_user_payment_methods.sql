-- Migration: Création table user_payment_methods
-- Date: 2025-11-30
-- Description: Gestion des 5 moyens de paiement des utilisateurs

-- Table des moyens de paiement utilisateurs
CREATE TABLE IF NOT EXISTS public.user_payment_methods (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  method_type VARCHAR(50) NOT NULL CHECK (method_type IN ('wallet', 'orange_money', 'mtn_money', 'cash', 'bank_card')),
  
  -- Détails selon le type
  phone_number VARCHAR(20), -- Pour Orange Money et MTN Money
  card_last_four VARCHAR(4), -- Derniers 4 chiffres pour carte bancaire (sécurité)
  card_brand VARCHAR(50), -- Visa, Mastercard, etc.
  
  -- Métadonnées
  label VARCHAR(100), -- Nom personnalisé par l'utilisateur
  is_default BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  
  -- Timestamps
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  last_used_at TIMESTAMP WITH TIME ZONE,
  
  -- Contraintes
  UNIQUE(user_id, method_type, phone_number), -- Éviter doublons
  UNIQUE(user_id, method_type, card_last_four) -- Éviter doublons cartes
);

-- Index pour performances
CREATE INDEX IF NOT EXISTS idx_user_payment_methods_user ON public.user_payment_methods(user_id);
CREATE INDEX IF NOT EXISTS idx_user_payment_methods_default ON public.user_payment_methods(user_id, is_default) WHERE is_default = true;
CREATE INDEX IF NOT EXISTS idx_user_payment_methods_active ON public.user_payment_methods(user_id, is_active) WHERE is_active = true;

-- Trigger pour updated_at
CREATE TRIGGER trigger_user_payment_methods_updated_at
  BEFORE UPDATE ON public.user_payment_methods
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- RLS (Row Level Security)
ALTER TABLE public.user_payment_methods ENABLE ROW LEVEL SECURITY;

-- Policies : Les utilisateurs gèrent uniquement leurs propres moyens de paiement
CREATE POLICY "Les utilisateurs voient leurs moyens de paiement"
  ON public.user_payment_methods FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Les utilisateurs créent leurs moyens de paiement"
  ON public.user_payment_methods FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Les utilisateurs modifient leurs moyens de paiement"
  ON public.user_payment_methods FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Les utilisateurs suppriment leurs moyens de paiement"
  ON public.user_payment_methods FOR DELETE
  USING (auth.uid() = user_id);

-- Fonction pour s'assurer qu'un seul moyen est par défaut par utilisateur
CREATE OR REPLACE FUNCTION ensure_single_default_payment_method()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.is_default = true THEN
    -- Retirer le défaut de tous les autres moyens de cet utilisateur
    UPDATE public.user_payment_methods
    SET is_default = false
    WHERE user_id = NEW.user_id
      AND id != NEW.id
      AND is_default = true;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_ensure_single_default
  BEFORE INSERT OR UPDATE ON public.user_payment_methods
  FOR EACH ROW
  EXECUTE FUNCTION ensure_single_default_payment_method();

-- Ajouter le portefeuille 224Solutions par défaut pour les utilisateurs existants
INSERT INTO public.user_payment_methods (user_id, method_type, is_default, is_active, label)
SELECT 
  id,
  'wallet',
  true,
  true,
  'Portefeuille 224Solutions'
FROM auth.users
WHERE id NOT IN (
  SELECT DISTINCT user_id 
  FROM public.user_payment_methods 
  WHERE method_type = 'wallet'
)
ON CONFLICT (user_id, method_type, phone_number) DO NOTHING;

-- Vue pour statistiques des moyens de paiement
CREATE OR REPLACE VIEW public.payment_methods_stats AS
SELECT 
  method_type,
  COUNT(*) as total_users,
  COUNT(CASE WHEN is_default THEN 1 END) as default_count,
  COUNT(CASE WHEN is_active THEN 1 END) as active_count
FROM public.user_payment_methods
GROUP BY method_type
ORDER BY total_users DESC;

COMMENT ON TABLE public.user_payment_methods IS 'Moyens de paiement configurés par les utilisateurs';
COMMENT ON COLUMN public.user_payment_methods.method_type IS 'Type: wallet, orange_money, mtn_money, cash, bank_card';
COMMENT ON COLUMN public.user_payment_methods.phone_number IS 'Numéro de téléphone pour mobile money';
COMMENT ON COLUMN public.user_payment_methods.card_last_four IS 'Derniers 4 chiffres de la carte (sécurité)';
COMMENT ON COLUMN public.user_payment_methods.is_default IS 'Moyen de paiement par défaut de l''utilisateur';
COMMENT ON VIEW public.payment_methods_stats IS 'Statistiques d''utilisation des moyens de paiement';
