
-- ============================================================
-- CORRECTION DES profiles.public_id RESTANTS
-- Les user_ids.custom_id sont déjà à jour
-- ============================================================

-- 1. VENDEURS - Mise à jour profiles.public_id
UPDATE profiles SET public_id = 'VND0009' WHERE id = '569276b0-b446-49c1-bb52-a3f08d100e3b';
UPDATE profiles SET public_id = 'VND0010' WHERE id = 'dad61558-36de-4dc3-9190-e1a317852ac8';
UPDATE profiles SET public_id = 'VND0011' WHERE id = '276069b6-8083-4fee-844f-58c92ebe3a84';

-- 2. CLIENTS - Mise à jour profiles.public_id
UPDATE profiles SET public_id = 'USR0009' WHERE id = '906e1b70-4584-4925-9fd7-f5cf6a9d7785';
UPDATE profiles SET public_id = 'USR0010' WHERE id = '4dedf643-0f38-4481-825d-64fb39f6887b';
UPDATE profiles SET public_id = 'USR0011' WHERE id = 'de4e3fe1-0c16-4c7d-a373-bff204914e0e';

-- 3. AGENTS - Mise à jour profiles.public_id (les custom_id sont déjà AGT0002, AGT0003, AGT0004)
UPDATE profiles SET public_id = 'AGT0002' WHERE id = 'e2ce9080-26e9-4681-9ee0-c6896bcd2093';
UPDATE profiles SET public_id = 'AGT0003' WHERE id = '09df4cbd-7b10-472a-8641-e91f563f3873';
UPDATE profiles SET public_id = 'AGT0004' WHERE id = '82cfefb7-4144-4832-b345-4b7eb33b0b33';
