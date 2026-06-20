-- Supprimer la contrainte qui bloque les dépôts/retraits
-- (car sender_id = receiver_id pour ces opérations)
ALTER TABLE public.enhanced_transactions
DROP CONSTRAINT IF EXISTS different_users;

-- Permettre les mises à jour des wallets via service_role uniquement
-- (sécurisé car géré par l'edge function authentifiée)
CREATE POLICY "Service role can update wallets"
ON public.wallets
FOR UPDATE
TO service_role
USING (true)
WITH CHECK (true);

-- Permettre les insertions de transactions via service_role uniquement
CREATE POLICY "Service role can insert transactions"
ON public.enhanced_transactions
FOR INSERT
TO service_role
WITH CHECK (true);