
-- Ajouter les paramètres de frais de dépôt et de retrait
INSERT INTO pdg_settings (id, setting_key, setting_value, description, updated_by, updated_at, created_at)
VALUES 
  (gen_random_uuid(), 'deposit_fee_percentage', '{"value": 1.5}'::jsonb, 'Pourcentage de frais sur les dépôts (PayPal, carte, etc.)', NULL, now(), now()),
  (gen_random_uuid(), 'withdrawal_fee_percentage', '{"value": 2}'::jsonb, 'Pourcentage de frais sur les retraits (PayPal, Mobile Money, etc.)', NULL, now(), now())
ON CONFLICT DO NOTHING;
