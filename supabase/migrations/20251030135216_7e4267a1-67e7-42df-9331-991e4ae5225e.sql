-- Configuration des commissions pour l'e-commerce
INSERT INTO commission_config (
  service_name,
  transaction_type,
  commission_type,
  commission_value,
  is_active
) VALUES 
  ('ecommerce', 'product_purchase', 'percentage', 2.5, true)
ON CONFLICT DO NOTHING;