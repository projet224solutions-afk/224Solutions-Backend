-- Ajouter 'customer_release' aux actions autorisées dans escrow_logs
ALTER TABLE public.escrow_logs 
DROP CONSTRAINT IF EXISTS escrow_logs_action_check;

ALTER TABLE public.escrow_logs 
ADD CONSTRAINT escrow_logs_action_check 
CHECK (action = ANY (ARRAY[
  'created'::text, 
  'requested_release'::text, 
  'released'::text, 
  'refunded'::text, 
  'held'::text, 
  'auto_released'::text,
  'customer_release'::text,
  'disputed'::text
]));