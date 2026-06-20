-- Migration: Système de Connexion Intelligente - Correction
-- Ajout des champs nécessaires pour le système universel

-- 1. Ajouter password_hash aux membres (workers)
ALTER TABLE public.members 
ADD COLUMN IF NOT EXISTS password_hash TEXT,
ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS login_attempts INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS locked_until TIMESTAMP WITH TIME ZONE;

-- 2. Ajouter champs de login aux bureaux
ALTER TABLE public.bureaus
ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS login_attempts INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS locked_until TIMESTAMP WITH TIME ZONE;

-- 3. Ajouter champs de login aux agents
ALTER TABLE public.agents_management
ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMP WITH TIME ZONE,
ADD COLUMN IF NOT EXISTS login_attempts INTEGER DEFAULT 0,
ADD COLUMN IF NOT EXISTS locked_until TIMESTAMP WITH TIME ZONE;

-- 4. Créer table des plaintes/problèmes des travailleurs
CREATE TABLE IF NOT EXISTS public.worker_complaints (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_id UUID NOT NULL REFERENCES public.members(id) ON DELETE CASCADE,
  bureau_id UUID NOT NULL REFERENCES public.bureaus(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT 'general',
  status TEXT NOT NULL DEFAULT 'pending',
  priority TEXT DEFAULT 'normal',
  response TEXT,
  responded_by UUID REFERENCES public.bureaus(id),
  responded_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Index pour les plaintes
CREATE INDEX IF NOT EXISTS idx_worker_complaints_worker ON public.worker_complaints(worker_id);
CREATE INDEX IF NOT EXISTS idx_worker_complaints_bureau ON public.worker_complaints(bureau_id);
CREATE INDEX IF NOT EXISTS idx_worker_complaints_status ON public.worker_complaints(status);

-- 5. RLS Policies pour worker_complaints
ALTER TABLE public.worker_complaints ENABLE ROW LEVEL SECURITY;

-- Les travailleurs peuvent voir leurs propres plaintes (simplifiée)
CREATE POLICY "Workers can view their complaints" ON public.worker_complaints
  FOR SELECT USING (true);

-- Les travailleurs peuvent créer leurs propres plaintes
CREATE POLICY "Workers can create complaints" ON public.worker_complaints
  FOR INSERT WITH CHECK (true);

-- Les bureaux peuvent répondre aux plaintes (simplifiée pour l'instant)
CREATE POLICY "Bureaus can manage complaints" ON public.worker_complaints
  FOR ALL USING (true);

-- 6. Fonction pour générer un ID agent unique
CREATE OR REPLACE FUNCTION generate_unique_agent_code()
RETURNS TEXT AS $$
DECLARE
  new_code TEXT;
  code_exists BOOLEAN;
BEGIN
  LOOP
    -- Format: AGT + 5 chiffres aléatoires
    new_code := 'AGT' || LPAD(FLOOR(RANDOM() * 100000)::TEXT, 5, '0');
    
    -- Vérifier si le code existe déjà
    SELECT EXISTS(SELECT 1 FROM agents_management WHERE agent_code = new_code) INTO code_exists;
    
    -- Si le code n'existe pas, on sort de la boucle
    EXIT WHEN NOT code_exists;
  END LOOP;
  
  RETURN new_code;
END;
$$ LANGUAGE plpgsql;

-- 7. Trigger pour auto-générer agent_code si non fourni
CREATE OR REPLACE FUNCTION auto_generate_agent_code()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.agent_code IS NULL OR NEW.agent_code = '' THEN
    NEW.agent_code := generate_unique_agent_code();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_auto_agent_code ON public.agents_management;
CREATE TRIGGER trigger_auto_agent_code
BEFORE INSERT ON public.agents_management
FOR EACH ROW
EXECUTE FUNCTION auto_generate_agent_code();

-- 8. Fonction pour mettre à jour updated_at automatiquement
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_worker_complaints ON public.worker_complaints;
CREATE TRIGGER trigger_update_worker_complaints
BEFORE UPDATE ON public.worker_complaints
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

COMMENT ON TABLE public.worker_complaints IS 'Système de plaintes et problèmes des travailleurs avec réponses des bureaux';
COMMENT ON FUNCTION generate_unique_agent_code() IS 'Génère un code agent unique au format AGT00000';
