-- ============================================
-- CORRECTION SYSTÈME DE COMMANDES - PARTIE 2
-- Créer les triggers et les index
-- ============================================

-- 1. Créer le trigger pour auto-créer customer
DROP TRIGGER IF EXISTS create_customer_on_profile_insert ON public.profiles;
CREATE TRIGGER create_customer_on_profile_insert
  AFTER INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.create_customer_on_signup();

-- 2. Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_orders_customer_source ON public.orders(customer_id, source) WHERE source = 'online';
CREATE INDEX IF NOT EXISTS idx_orders_vendor_source ON public.orders(vendor_id, source) WHERE source = 'online';
CREATE INDEX IF NOT EXISTS idx_customers_user_id ON public.customers(user_id);