-- Corriger le trigger pour n'envoyer des notifications que pour les commandes en ligne (pas POS)
DROP TRIGGER IF EXISTS trigger_notify_vendor_new_order ON public.orders;

-- Recréer le trigger UNIQUEMENT pour les commandes en ligne
CREATE TRIGGER trigger_notify_vendor_new_order
  AFTER INSERT ON public.orders
  FOR EACH ROW
  WHEN (NEW.source = 'online')
  EXECUTE FUNCTION public.notify_vendor_new_order();

COMMENT ON FUNCTION public.notify_vendor_new_order() IS
'Crée une notification dans vendor_notifications uniquement quand une nouvelle commande EN LIGNE est créée (exclut les ventes POS)';