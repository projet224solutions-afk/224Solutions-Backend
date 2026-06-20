-- Corriger les RLS policies pour vendor_agents
-- Le vendor_id dans vendor_agents fait référence au user_id (auth.uid()) du vendeur

-- Supprimer les anciennes policies problématiques
DROP POLICY IF EXISTS "Vendors can create their own agents" ON vendor_agents;
DROP POLICY IF EXISTS "Vendors can view their own agents" ON vendor_agents;
DROP POLICY IF EXISTS "Vendors can update their own agents" ON vendor_agents;
DROP POLICY IF EXISTS "Vendors can delete their own agents" ON vendor_agents;
DROP POLICY IF EXISTS "vendors_manage_own_agents" ON vendor_agents;
DROP POLICY IF EXISTS "vendor_agents_select_secure" ON vendor_agents;

-- Créer de nouvelles policies qui vérifient vendor_id = auth.uid() correctement
-- Puisque vendor_id stocke le user_id du vendeur

CREATE POLICY "vendor_agents_select" ON vendor_agents
  FOR SELECT TO authenticated
  USING (vendor_id = auth.uid());

CREATE POLICY "vendor_agents_insert" ON vendor_agents
  FOR INSERT TO authenticated
  WITH CHECK (vendor_id = auth.uid());

CREATE POLICY "vendor_agents_update" ON vendor_agents
  FOR UPDATE TO authenticated
  USING (vendor_id = auth.uid());

CREATE POLICY "vendor_agents_delete" ON vendor_agents
  FOR DELETE TO authenticated
  USING (vendor_id = auth.uid());

-- Policy pour admins
CREATE POLICY "vendor_agents_admin_select" ON vendor_agents
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
      AND profiles.role = 'admin'::user_role
    )
  );