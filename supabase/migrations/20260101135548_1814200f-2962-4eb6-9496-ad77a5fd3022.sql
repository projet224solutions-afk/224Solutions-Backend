-- Corriger les vues pour ne pas être SECURITY DEFINER
DROP VIEW IF EXISTS public.active_transactions;
DROP VIEW IF EXISTS public.active_orders;

CREATE VIEW public.active_transactions 
WITH (security_invoker = true)
AS SELECT * FROM public.enhanced_transactions WHERE is_archived = false;

CREATE VIEW public.active_orders 
WITH (security_invoker = true)
AS SELECT * FROM public.orders WHERE is_archived = false;