-- Créer la table pour les transactions P2P entre utilisateurs
CREATE TABLE public.p2p_transactions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  sender_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  receiver_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  amount NUMERIC NOT NULL CHECK (amount > 0),
  description TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'cancelled', 'failed')),
  transaction_type TEXT NOT NULL DEFAULT 'transfer' CHECK (transaction_type IN ('transfer', 'payment', 'request')),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  completed_at TIMESTAMP WITH TIME ZONE,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Activer RLS
ALTER TABLE public.p2p_transactions ENABLE ROW LEVEL SECURITY;

-- Politique pour permettre aux utilisateurs de voir leurs transactions (comme expéditeur ou destinataire)
CREATE POLICY "Users can view their own transactions" 
ON public.p2p_transactions 
FOR SELECT 
USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

-- Politique pour permettre aux utilisateurs de créer des transactions
CREATE POLICY "Users can create transactions" 
ON public.p2p_transactions 
FOR INSERT 
WITH CHECK (auth.uid() = sender_id);

-- Politique pour permettre aux utilisateurs de mettre à jour les transactions qu'ils ont reçues
CREATE POLICY "Users can update received transactions" 
ON public.p2p_transactions 
FOR UPDATE 
USING (auth.uid() = receiver_id OR auth.uid() = sender_id);

-- Trigger pour mettre à jour updated_at
CREATE TRIGGER update_p2p_transactions_updated_at
BEFORE UPDATE ON public.p2p_transactions
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Fonction pour créditer un wallet (sécurisée)
CREATE OR REPLACE FUNCTION public.credit_wallet(
  receiver_user_id UUID,
  credit_amount NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  -- Vérifier que le montant est positif
  IF credit_amount <= 0 THEN
    RAISE EXCEPTION 'Le montant doit être positif';
  END IF;
  
  -- Créditer le wallet du destinataire
  UPDATE public.wallets 
  SET balance = balance + credit_amount,
      updated_at = now()
  WHERE user_id = receiver_user_id;
  
  -- Vérifier qu'un wallet a été mis à jour
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet du destinataire non trouvé';
  END IF;
END;
$function$;