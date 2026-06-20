-- Créer la table vendor_agents pour la gestion des agents par les vendeurs
CREATE TABLE IF NOT EXISTS public.vendor_agents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL,
  agent_code VARCHAR(50) UNIQUE NOT NULL,
  name VARCHAR(255) NOT NULL,
  email VARCHAR(255) NOT NULL,
  phone VARCHAR(50) NOT NULL,
  access_token TEXT UNIQUE NOT NULL,
  commission_rate DECIMAL(5,2) DEFAULT 10.00,
  permissions TEXT[] DEFAULT ARRAY['create_users']::TEXT[],
  can_create_sub_agent BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  total_users_created INTEGER DEFAULT 0,
  total_commissions_earned DECIMAL(15,2) DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Créer un index sur vendor_id pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_vendor_agents_vendor_id ON public.vendor_agents(vendor_id);

-- Créer un index sur access_token
CREATE INDEX IF NOT EXISTS idx_vendor_agents_access_token ON public.vendor_agents(access_token);

-- Créer un index sur email
CREATE INDEX IF NOT EXISTS idx_vendor_agents_email ON public.vendor_agents(email);

-- Activer RLS
ALTER TABLE public.vendor_agents ENABLE ROW LEVEL SECURITY;

-- Politique : Les vendeurs peuvent voir leurs propres agents
CREATE POLICY "Vendors can view their own agents"
ON public.vendor_agents
FOR SELECT
USING (
  vendor_id = auth.uid()
);

-- Politique : Les vendeurs peuvent créer leurs propres agents
CREATE POLICY "Vendors can create their own agents"
ON public.vendor_agents
FOR INSERT
WITH CHECK (
  vendor_id = auth.uid()
);

-- Politique : Les vendeurs peuvent modifier leurs propres agents
CREATE POLICY "Vendors can update their own agents"
ON public.vendor_agents
FOR UPDATE
USING (
  vendor_id = auth.uid()
);

-- Politique : Les vendeurs peuvent supprimer leurs propres agents
CREATE POLICY "Vendors can delete their own agents"
ON public.vendor_agents
FOR DELETE
USING (
  vendor_id = auth.uid()
);

-- Fonction pour générer un code agent unique
CREATE OR REPLACE FUNCTION generate_vendor_agent_code()
RETURNS TEXT AS $$
DECLARE
  new_code TEXT;
  year_part TEXT;
  sequence_num INTEGER;
BEGIN
  year_part := TO_CHAR(NOW(), 'YYYY');
  
  -- Trouver le prochain numéro de séquence
  SELECT COALESCE(MAX(CAST(SUBSTRING(agent_code FROM 10) AS INTEGER)), 0) + 1
  INTO sequence_num
  FROM public.vendor_agents
  WHERE agent_code LIKE 'VAGT-' || year_part || '-%';
  
  new_code := 'VAGT-' || year_part || '-' || LPAD(sequence_num::TEXT, 5, '0');
  
  RETURN new_code;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Fonction pour générer un access_token unique
CREATE OR REPLACE FUNCTION generate_vendor_agent_access_token()
RETURNS TEXT AS $$
DECLARE
  token TEXT;
  token_exists BOOLEAN;
BEGIN
  LOOP
    -- Générer un token aléatoire de 32 caractères
    token := encode(gen_random_bytes(24), 'base64');
    token := replace(token, '/', '_');
    token := replace(token, '+', '-');
    token := replace(token, '=', '');
    
    -- Vérifier si le token existe déjà
    SELECT EXISTS(SELECT 1 FROM public.vendor_agents WHERE access_token = token)
    INTO token_exists;
    
    EXIT WHEN NOT token_exists;
  END LOOP;
  
  RETURN token;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Trigger pour générer automatiquement le code agent et le token
CREATE OR REPLACE FUNCTION set_vendor_agent_defaults()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.agent_code IS NULL OR NEW.agent_code = '' THEN
    NEW.agent_code := generate_vendor_agent_code();
  END IF;
  
  IF NEW.access_token IS NULL OR NEW.access_token = '' THEN
    NEW.access_token := generate_vendor_agent_access_token();
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trigger_set_vendor_agent_defaults
BEFORE INSERT ON public.vendor_agents
FOR EACH ROW
EXECUTE FUNCTION set_vendor_agent_defaults();

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_vendor_agents_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trigger_update_vendor_agents_updated_at
BEFORE UPDATE ON public.vendor_agents
FOR EACH ROW
EXECUTE FUNCTION update_vendor_agents_updated_at();