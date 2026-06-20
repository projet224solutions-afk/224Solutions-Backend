-- Corriger les politiques RLS de vendor_agents pour utiliser la relation vendors

-- Supprimer les anciennes politiques
DROP POLICY IF EXISTS "vendor_agents_select" ON public.vendor_agents;
DROP POLICY IF EXISTS "vendor_agents_insert" ON public.vendor_agents;
DROP POLICY IF EXISTS "vendor_agents_update" ON public.vendor_agents;
DROP POLICY IF EXISTS "vendor_agents_delete" ON public.vendor_agents;

-- Créer les nouvelles politiques qui vérifient via la table vendors
CREATE POLICY "vendor_agents_select" ON public.vendor_agents
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = vendor_agents.vendor_id
    AND v.user_id = auth.uid()
  )
);

CREATE POLICY "vendor_agents_insert" ON public.vendor_agents
FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = vendor_agents.vendor_id
    AND v.user_id = auth.uid()
  )
);

CREATE POLICY "vendor_agents_update" ON public.vendor_agents
FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = vendor_agents.vendor_id
    AND v.user_id = auth.uid()
  )
);

CREATE POLICY "vendor_agents_delete" ON public.vendor_agents
FOR DELETE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.vendors v
    WHERE v.id = vendor_agents.vendor_id
    AND v.user_id = auth.uid()
  )
);