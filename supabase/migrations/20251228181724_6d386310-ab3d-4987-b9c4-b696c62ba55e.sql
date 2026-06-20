-- ============================================
-- CORRECTION DES LIAISONS TAXI-MOTO ↔ BUREAU SYNDICAT
-- ET LIVREUR ↔ VENDEUR
-- ============================================

-- 1. Ajouter bureau_id à taxi_drivers pour la liaison avec les bureaux syndicaux
ALTER TABLE public.taxi_drivers 
ADD COLUMN IF NOT EXISTS bureau_id uuid REFERENCES public.bureaus(id);

-- 2. Ajouter syndicate_id à taxi_drivers (pour une relation plus directe)
ALTER TABLE public.taxi_drivers 
ADD COLUMN IF NOT EXISTS syndicate_id uuid;

-- 3. Créer un index pour améliorer les performances de recherche
CREATE INDEX IF NOT EXISTS idx_taxi_drivers_bureau_id ON public.taxi_drivers(bureau_id);

-- 4. Créer une table de liaison livreur-vendeur préféré
CREATE TABLE IF NOT EXISTS public.vendor_preferred_drivers (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  driver_id uuid NOT NULL REFERENCES public.drivers(id) ON DELETE CASCADE,
  priority integer DEFAULT 1,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  UNIQUE(vendor_id, driver_id)
);

-- 5. Activer RLS sur la nouvelle table
ALTER TABLE public.vendor_preferred_drivers ENABLE ROW LEVEL SECURITY;

-- 6. Politique pour les vendeurs (peuvent voir et gérer leurs livreurs préférés)
CREATE POLICY "Vendors can manage their preferred drivers"
ON public.vendor_preferred_drivers
FOR ALL
USING (
  vendor_id IN (
    SELECT id FROM public.vendors WHERE user_id = auth.uid()
  )
);

-- 7. Politique pour les livreurs (peuvent voir où ils sont préférés)
CREATE POLICY "Drivers can view their vendor assignments"
ON public.vendor_preferred_drivers
FOR SELECT
USING (
  driver_id IN (
    SELECT id FROM public.drivers WHERE user_id = auth.uid()
  )
);

-- 8. Ajouter une colonne pour lier un livreur à un vendeur principal
ALTER TABLE public.drivers 
ADD COLUMN IF NOT EXISTS primary_vendor_id uuid REFERENCES public.vendors(id);

-- 9. Index pour performances
CREATE INDEX IF NOT EXISTS idx_vendor_preferred_drivers_vendor ON public.vendor_preferred_drivers(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_preferred_drivers_driver ON public.vendor_preferred_drivers(driver_id);
CREATE INDEX IF NOT EXISTS idx_drivers_primary_vendor ON public.drivers(primary_vendor_id);

-- 10. Fonction pour notifier un vendeur quand un livreur accepte une livraison
CREATE OR REPLACE FUNCTION public.notify_vendor_on_driver_accept()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'assigned' AND OLD.status = 'pending' AND NEW.driver_id IS NOT NULL THEN
    INSERT INTO public.delivery_notifications (
      user_id,
      delivery_id,
      type,
      title,
      message,
      is_read
    )
    SELECT 
      v.user_id,
      NEW.id,
      'driver_assigned',
      'Livreur assigné',
      'Un livreur a accepté votre commande et est en route',
      false
    FROM public.vendors v
    WHERE v.id = NEW.vendor_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 11. Déclencher la notification lors de l'assignation d'un livreur
DROP TRIGGER IF EXISTS trigger_notify_vendor_driver_accept ON public.deliveries;
CREATE TRIGGER trigger_notify_vendor_driver_accept
  AFTER UPDATE ON public.deliveries
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_vendor_on_driver_accept();

-- 12. Fonction pour notifier le livreur quand le colis est prêt
CREATE OR REPLACE FUNCTION public.notify_driver_package_ready()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.ready_for_pickup = true AND (OLD.ready_for_pickup = false OR OLD.ready_for_pickup IS NULL) AND NEW.driver_id IS NOT NULL THEN
    INSERT INTO public.delivery_notifications (
      user_id,
      delivery_id,
      type,
      title,
      message,
      is_read
    )
    SELECT 
      d.user_id,
      NEW.id,
      'package_ready',
      'Colis prêt !',
      'Le colis est prêt pour le retrait chez le vendeur',
      false
    FROM public.drivers d
    WHERE d.id = NEW.driver_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 13. Déclencher la notification quand le colis est prêt
DROP TRIGGER IF EXISTS trigger_notify_driver_package_ready ON public.deliveries;
CREATE TRIGGER trigger_notify_driver_package_ready
  AFTER UPDATE ON public.deliveries
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_driver_package_ready();

-- 14. Vue pour le syndicat voir ses taxi-motos
CREATE OR REPLACE VIEW public.bureau_taxi_drivers AS
SELECT 
  td.*,
  b.commune as bureau_commune,
  b.prefecture as bureau_prefecture,
  b.president_name as bureau_president
FROM public.taxi_drivers td
LEFT JOIN public.bureaus b ON td.bureau_id = b.id;