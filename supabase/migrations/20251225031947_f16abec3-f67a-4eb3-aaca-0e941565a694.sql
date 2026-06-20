-- Ajouter une politique RLS pour permettre aux agents de mettre à jour leur propre wallet
CREATE POLICY "Agents can update own wallet balance" ON public.agent_wallets
FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM agents_management am
    WHERE am.id = agent_wallets.agent_id
    AND am.user_id = auth.uid()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM agents_management am
    WHERE am.id = agent_wallets.agent_id
    AND am.user_id = auth.uid()
  )
);