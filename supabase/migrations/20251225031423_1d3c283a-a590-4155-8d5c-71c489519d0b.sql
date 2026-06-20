-- Ajouter une politique RLS pour permettre aux agents de créer des transactions de retrait
CREATE POLICY "Agents can insert withdrawal transactions" ON public.wallet_transactions
FOR INSERT TO authenticated
WITH CHECK (
  sender_wallet_id IN (
    SELECT aw.id FROM agent_wallets aw
    JOIN agents_management am ON am.id = aw.agent_id
    WHERE am.user_id = auth.uid()
  )
);