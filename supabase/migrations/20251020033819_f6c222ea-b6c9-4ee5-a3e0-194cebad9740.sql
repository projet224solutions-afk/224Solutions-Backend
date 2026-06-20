-- Création de la table badges pour stocker les badges générés
CREATE TABLE IF NOT EXISTS public.badges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bureau_id UUID REFERENCES public.bureaus(id) ON DELETE CASCADE,
  member_id UUID REFERENCES public.members(id) ON DELETE SET NULL,
  file_path TEXT NOT NULL,
  public_url TEXT,
  name TEXT NOT NULL,
  first_name TEXT NOT NULL,
  gilet_number TEXT,
  phone TEXT,
  plate TEXT,
  serial_number TEXT,
  created_by TEXT DEFAULT 'bureau',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Activer RLS
ALTER TABLE public.badges ENABLE ROW LEVEL SECURITY;

-- Policy pour le bureau qui peut voir et créer ses propres badges
CREATE POLICY "Bureau peut gérer ses badges"
ON public.badges
FOR ALL
USING (
  bureau_id IN (
    SELECT id FROM public.bureaus 
    WHERE access_token IS NOT NULL
  )
);

-- Policy pour les admins
CREATE POLICY "Admins peuvent tout voir"
ON public.badges
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin'
  )
);

-- Service role all access
CREATE POLICY "service_role_all"
ON public.badges
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- Index pour performance
CREATE INDEX idx_badges_bureau_id ON public.badges(bureau_id);
CREATE INDEX idx_badges_member_id ON public.badges(member_id);

-- Trigger pour updated_at
CREATE OR REPLACE FUNCTION update_badges_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_badges_updated_at
BEFORE UPDATE ON public.badges
FOR EACH ROW
EXECUTE FUNCTION update_badges_updated_at();