-- Créer les politiques RLS pour l'accès des agents vendeurs via token

-- Activer RLS sur vendor_agents si ce n'est pas déjà fait
ALTER TABLE public.vendor_agents ENABLE ROW LEVEL SECURITY;

-- Politique pour permettre aux agents de lire leurs propres données via token (accès public)
CREATE POLICY "agents_read_own_via_token" ON public.vendor_agents
FOR SELECT
TO anon, authenticated
USING (true);

-- Politique pour que les vendeurs puissent gérer leurs agents
CREATE POLICY "vendors_manage_own_agents" ON public.vendor_agents
FOR ALL
TO authenticated
USING (vendor_id = auth.uid())
WITH CHECK (vendor_id = auth.uid());

-- Créer un index sur access_token pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_vendor_agents_access_token ON public.vendor_agents(access_token)
WHERE is_active = true;

-- Créer un index sur vendor_id pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_vendor_agents_vendor_id ON public.vendor_agents(vendor_id)
WHERE is_active = true;