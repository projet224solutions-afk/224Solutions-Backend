-- Améliorer les politiques RLS pour les wallets et transactions
-- Pour permettre les transactions entre tous les utilisateurs

-- Wallets: Les utilisateurs peuvent voir leur propre wallet
DROP POLICY IF EXISTS "Users can manage their wallet" ON public.wallets;
CREATE POLICY "Users can view their own wallet"
ON public.wallets
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Les transactions peuvent être créées par l'edge function (service_role)
-- et vues par les utilisateurs impliqués
DROP POLICY IF EXISTS "Users can view their transactions" ON public.enhanced_transactions;
CREATE POLICY "Users can view their transactions"
ON public.enhanced_transactions
FOR SELECT
TO authenticated
USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

-- Permettre aux utilisateurs de voir les wallets des autres pour valider les transferts
CREATE POLICY "Users can view other wallets for transfers"
ON public.wallets
FOR SELECT
TO authenticated
USING (true);

-- Permettre la création de transactions via service role
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.enhanced_transactions ENABLE ROW LEVEL SECURITY;