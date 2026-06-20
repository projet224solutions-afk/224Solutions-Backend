-- Ajouter politique pour permettre la création de wallets par les bureaux
CREATE POLICY "Allow authenticated to insert bureau_wallets" 
ON public.bureau_wallets 
FOR INSERT 
TO authenticated 
WITH CHECK (true);

-- Améliorer la politique de lecture pour les bureaux authentifiés
DROP POLICY IF EXISTS "Bureau can view own wallet" ON public.bureau_wallets;
CREATE POLICY "Bureau members can view bureau wallet" 
ON public.bureau_wallets 
FOR SELECT 
TO authenticated 
USING (true);

-- S'assurer que les bureaux manquants ont un wallet
INSERT INTO public.bureau_wallets (bureau_id, balance, currency, wallet_status)
SELECT b.id, 10000, 'GNF', 'active'
FROM public.bureaus b
LEFT JOIN public.bureau_wallets bw ON b.id = bw.bureau_id
WHERE bw.id IS NULL;