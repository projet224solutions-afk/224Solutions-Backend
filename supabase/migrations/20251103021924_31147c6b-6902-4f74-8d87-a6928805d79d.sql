-- Mettre à jour le solde initial des wallets existants avec un solde de 0
UPDATE public.bureau_wallets 
SET balance = 10000 
WHERE balance = 0;

UPDATE public.agent_wallets 
SET balance = 10000 
WHERE balance = 0;