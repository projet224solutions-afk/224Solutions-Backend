
-- Mise à jour des 3 IDs legacy vers le format standardisé
-- Les custom_id dans user_ids sont déjà corrects, on synchronise public_id

UPDATE profiles SET public_id = 'DRV0007' WHERE id = 'f8822961-6719-4bfc-9b7c-affd2a073882';
UPDATE profiles SET public_id = 'VND0004' WHERE id = '75a0d227-fca1-4a82-b206-9c299de0a86f';
UPDATE profiles SET public_id = 'AGT0001' WHERE id = 'bf42b8e6-d48d-40f1-b3c5-60d3df6996cb';
