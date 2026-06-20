-- Créer une catégorie Électronique si elle n'existe pas
INSERT INTO public.categories (name, description, is_active)
SELECT 'Électronique', 'Produits électroniques et high-tech', true
WHERE NOT EXISTS (SELECT 1 FROM public.categories WHERE name = 'Électronique');

-- Ajouter des produits de test pour chaque vendeur
DO $$
DECLARE
  v_vendor RECORD;
  v_category_id UUID;
BEGIN
  -- Récupérer l'ID de la catégorie Électronique
  SELECT id INTO v_category_id 
  FROM public.categories 
  WHERE name = 'Électronique' 
  LIMIT 1;
  
  -- Pour chaque vendeur
  FOR v_vendor IN (SELECT id, user_id FROM public.vendors LIMIT 10)
  LOOP
    -- Vérifier si le vendeur a déjà des produits
    IF NOT EXISTS (SELECT 1 FROM public.products WHERE vendor_id = v_vendor.id LIMIT 1) THEN
      -- Ajouter les produits de test
      INSERT INTO public.products (vendor_id, category_id, name, description, price, compare_price, cost_price, stock_quantity, low_stock_threshold, sku, is_active)
      VALUES 
        (v_vendor.id, v_category_id, 'Smartphone Samsung Galaxy A54', 'Écran 6.4" Super AMOLED, 128GB, 6GB RAM, Triple caméra 50MP', 450000, 500000, 380000, 15, 5, 'SAM-A54-' || substring(v_vendor.id::text from 1 for 8), true),
        (v_vendor.id, v_category_id, 'Casque Bluetooth Sony WH-1000XM5', 'Réduction de bruit active, 30h d''autonomie', 285000, 320000, 240000, 8, 3, 'SONY-WH-' || substring(v_vendor.id::text from 1 for 8), true),
        (v_vendor.id, v_category_id, 'Apple Watch Series 9', 'GPS + Cellular, Écran Always-On', 380000, 420000, 320000, 6, 2, 'WATCH-S9-' || substring(v_vendor.id::text from 1 for 8), true),
        (v_vendor.id, v_category_id, 'Apple iPad Air 10.9"', 'Puce M1, 64GB, WiFi', 520000, 580000, 450000, 4, 2, 'IPAD-AIR-' || substring(v_vendor.id::text from 1 for 8), true),
        (v_vendor.id, v_category_id, 'PowerBank Anker 20000mAh', 'Charge rapide, 2 ports USB-C', 45000, 55000, 35000, 25, 8, 'ANKER-PB-' || substring(v_vendor.id::text from 1 for 8), true),
        (v_vendor.id, v_category_id, 'AirPods Pro 2ème génération', 'Réduction de bruit active', 195000, 220000, 160000, 12, 4, 'AIRPODS-' || substring(v_vendor.id::text from 1 for 8), true);
    END IF;
  END LOOP;
END $$;

-- S'assurer que tous les utilisateurs ont un wallet
INSERT INTO public.wallets (user_id, balance, currency)
SELECT p.id, 10000, 'GNF'
FROM public.profiles p
WHERE NOT EXISTS (
  SELECT 1 FROM public.wallets w 
  WHERE w.user_id = p.id AND w.currency = 'GNF'
);

-- S'assurer que tous les vendeurs ont des paramètres POS
INSERT INTO public.pos_settings (vendor_id, company_name, currency, tax_rate, tax_enabled)
SELECT v.user_id, COALESCE(p.first_name || ' ' || p.last_name, 'Mon Commerce'), 'FCFA', 0.18, true
FROM public.vendors v
JOIN public.profiles p ON v.user_id = p.id
WHERE NOT EXISTS (
  SELECT 1 FROM public.pos_settings ps 
  WHERE ps.vendor_id = v.user_id
);