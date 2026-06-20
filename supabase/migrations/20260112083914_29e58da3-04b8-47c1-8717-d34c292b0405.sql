-- =============================================
-- CORRECTION RLS: Permettre aux clients de voir les menus restaurants
-- Les clients (connectés ou non) doivent pouvoir voir les plats disponibles
-- =============================================

-- 1. CATÉGORIES DE MENU RESTAURANT - Lecture publique
-- Permettre à tout le monde de voir les catégories actives
CREATE POLICY "Public can view active menu categories" 
ON public.restaurant_menu_categories 
FOR SELECT 
USING (is_active = true);

-- 2. PLATS DE MENU RESTAURANT - Lecture publique  
-- Permettre à tout le monde de voir les plats disponibles
CREATE POLICY "Public can view available menu items" 
ON public.restaurant_menu_items 
FOR SELECT 
USING (is_available = true);