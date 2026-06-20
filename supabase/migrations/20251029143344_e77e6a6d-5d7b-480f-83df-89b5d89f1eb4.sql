-- Activer RLS sur la table global_ids
ALTER TABLE global_ids ENABLE ROW LEVEL SECURITY;

-- Politique: Admins/PDG peuvent tout gérer
CREATE POLICY "PDG can manage global_ids"
ON global_ids
FOR ALL
USING (has_role(auth.uid(), 'admin'::user_role))
WITH CHECK (has_role(auth.uid(), 'admin'::user_role));

-- Politique: Service role peut tout faire (nécessaire pour les triggers)
CREATE POLICY "service_role_all_global_ids"
ON global_ids
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');