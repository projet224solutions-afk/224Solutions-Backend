-- 1. Créer une commande pour l'expédition existante
INSERT INTO public.orders (
  vendor_id,
  customer_id,
  order_number,
  status,
  subtotal,
  total_amount,
  payment_status,
  shipping_address,
  notes
) VALUES (
  '42a36345-bfcb-4ecd-85e4-a624803b6a4f',
  'a94cf19f-a4b1-4e22-8a14-7c60afaa57b3',
  'EXP-MANUAL-001',
  'confirmed',
  0,
  0,
  'paid',
  '{"address": "Foulayah, Kindia, Guinée", "name": "Alhass", "phone": "61001"}'::jsonb,
  'Expédition: Téléphone - Electronique'
) RETURNING id;

-- 2. Créer la livraison correspondante
INSERT INTO public.deliveries (
  order_id,
  vendor_id,
  vendor_name,
  vendor_phone,
  vendor_location,
  pickup_address,
  delivery_address,
  customer_name,
  customer_phone,
  package_description,
  package_type,
  payment_method,
  price,
  delivery_fee,
  status
) 
SELECT 
  id,
  '42a36345-bfcb-4ecd-85e4-a624803b6a4f',
  'Thierno Bah',
  '224224',
  '{"address": "Kaloum, Conakry, Guinée", "name": "Deco"}'::jsonb,
  '{"address": "Kaloum, Conakry, Guinée", "name": "Deco", "phone": "224224"}'::jsonb,
  '{"address": "Foulayah, Kindia, Guinée", "name": "Alhass", "phone": "61001"}'::jsonb,
  'Alhass',
  '61001',
  'Téléphone - Electronique',
  'Electronique',
  'prepaid',
  0,
  15000,
  'pending'
FROM public.orders WHERE order_number = 'EXP-MANUAL-001';