-- Supprimer les notifications POS existantes
DELETE FROM vendor_notifications 
WHERE type = 'order' 
AND data->>'source' = 'pos';

-- Vérifier/recréer le trigger pour s'assurer qu'il filtre bien les POS
DROP TRIGGER IF EXISTS trigger_notify_vendor_new_order ON orders;

CREATE TRIGGER trigger_notify_vendor_new_order
AFTER INSERT ON public.orders
FOR EACH ROW
WHEN (NEW.source = 'online')
EXECUTE FUNCTION notify_vendor_new_order();