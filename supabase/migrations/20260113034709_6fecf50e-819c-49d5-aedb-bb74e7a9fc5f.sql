-- Insérer des produits dropshipping de démonstration
INSERT INTO dropship_products (
  vendor_id, supplier_id, product_name, category, supplier_price, supplier_currency,
  selling_price, selling_currency, availability_status, is_active, is_published,
  estimated_delivery_min, estimated_delivery_max, images, source_sku
) VALUES 
(
  '9e622843-f7c1-4a05-95f2-69429ceac420',
  '097a1497-585a-43eb-9e94-49323b7e3581',
  'Écouteurs Bluetooth Pro TWS',
  'Électronique',
  12.50, 'USD',
  180000, 'GNF',
  'available', true, true,
  15, 25,
  ARRAY['https://images.unsplash.com/photo-1606220588913-b3aacb4d2f46?w=300'],
  'TWS-PRO-001'
),
(
  '9e622843-f7c1-4a05-95f2-69429ceac420',
  'cd2b1da2-d812-4e3b-a563-c62f68df7e0d',
  'Montre Connectée Sport 2024',
  'Accessoires',
  25.00, 'USD',
  350000, 'GNF',
  'available', true, true,
  18, 30,
  ARRAY['https://images.unsplash.com/photo-1523275335684-37898b6baf30?w=300'],
  'WATCH-SPORT-24'
),
(
  '9e622843-f7c1-4a05-95f2-69429ceac420',
  '90c1276f-b90b-48a6-ab52-caf216cef9f6',
  'Coque iPhone Magnétique MagSafe',
  'Accessoires Téléphone',
  3.50, 'USD',
  55000, 'GNF',
  'available', true, true,
  12, 20,
  ARRAY['https://images.unsplash.com/photo-1601784551446-20c9e07cdbdb?w=300'],
  'CASE-MAGSAFE-01'
),
(
  '9e622843-f7c1-4a05-95f2-69429ceac420',
  '097a1497-585a-43eb-9e94-49323b7e3581',
  'Lampe LED Bureau USB Flexible',
  'Maison',
  8.00, 'USD',
  120000, 'GNF',
  'low_stock', true, true,
  14, 22,
  ARRAY['https://images.unsplash.com/photo-1507473885765-e6ed057f782c?w=300'],
  'LAMP-LED-USB'
),
(
  '9e622843-f7c1-4a05-95f2-69429ceac420',
  'cd2b1da2-d812-4e3b-a563-c62f68df7e0d',
  'Mini Ventilateur Portable Rechargeable',
  'Électronique',
  6.00, 'USD',
  95000, 'GNF',
  'available', true, true,
  10, 18,
  ARRAY['https://images.unsplash.com/photo-1556909114-f6e7ad7d3136?w=300'],
  'FAN-MINI-RECH'
);

-- Créer des commandes dropshipping de démonstration
INSERT INTO dropship_orders (
  vendor_id, supplier_id, customer_order_id, order_reference,
  dropship_product_id, quantity, 
  supplier_total, supplier_currency,
  customer_total, customer_currency,
  profit_amount, status, shipping_address
)
SELECT 
  '9e622843-f7c1-4a05-95f2-69429ceac420',
  p.supplier_id,
  gen_random_uuid(),
  'DS-' || LPAD((ROW_NUMBER() OVER())::text, 5, '0'),
  p.id,
  CASE WHEN random() > 0.5 THEN 2 ELSE 1 END,
  p.supplier_price * (CASE WHEN random() > 0.5 THEN 2 ELSE 1 END),
  p.supplier_currency,
  p.selling_price * (CASE WHEN random() > 0.5 THEN 2 ELSE 1 END),
  p.selling_currency,
  (p.selling_price - (p.supplier_price * 8500)) * (CASE WHEN random() > 0.5 THEN 2 ELSE 1 END),
  CASE 
    WHEN random() > 0.7 THEN 'completed'
    WHEN random() > 0.4 THEN 'shipped_by_supplier'
    ELSE 'pending'
  END,
  jsonb_build_object(
    'name', 'Client Test',
    'phone', '+224620000000',
    'city', 'Conakry',
    'country', 'Guinée'
  )
FROM dropship_products p
WHERE p.vendor_id = '9e622843-f7c1-4a05-95f2-69429ceac420'
LIMIT 3;