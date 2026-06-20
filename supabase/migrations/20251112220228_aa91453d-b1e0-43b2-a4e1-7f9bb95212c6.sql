
-- Supprimer la contrainte CHECK existante
ALTER TABLE public.communication_notifications 
DROP CONSTRAINT IF EXISTS communication_notifications_type_check;

-- Recréer la contrainte avec plus de types autorisés
ALTER TABLE public.communication_notifications 
ADD CONSTRAINT communication_notifications_type_check 
CHECK (type IN (
  'new_message',
  'missed_call', 
  'call_incoming',
  'order',
  'order_update',
  'payment',
  'delivery',
  'system'
));

-- Ajouter un commentaire pour documenter les types
COMMENT ON COLUMN public.communication_notifications.type IS 
'Types de notifications autorisés: new_message, missed_call, call_incoming, order, order_update, payment, delivery, system';
