-- Corriger les anciennes commandes POS qui sont payées mais pas "completed"
UPDATE public.orders 
SET status = 'completed' 
WHERE source = 'pos' 
  AND payment_status = 'paid' 
  AND status IN ('pending', 'processing', 'confirmed');

-- Pour les commandes POS non payées (abandonnées), les marquer comme annulées
UPDATE public.orders 
SET status = 'cancelled', payment_status = 'failed' 
WHERE source = 'pos' 
  AND payment_status = 'pending' 
  AND status = 'pending'
  AND created_at < NOW() - INTERVAL '24 hours';