
-- Étape 1: Supprimer la contrainte unique temporairement
ALTER TABLE user_ids DROP CONSTRAINT IF EXISTS user_ids_custom_id_key;

-- Étape 2: Assigner des IDs temporaires pour casser les conflits circulaires
UPDATE user_ids SET custom_id = 'TMP_' || LEFT(user_id::text, 6)
WHERE user_id IN (
  'e2ce9080-26e9-4681-9ee0-c6896bcd2093',
  '09df4cbd-7b10-472a-8641-e91f563f3873',
  '82cfefb7-4144-4832-b345-4b7eb33b0b33',
  '0d551780-1bfc-4abc-a4cf-0e726de6ada4',
  '0dcdf30a-f2ee-4be4-b63e-589d7e793102',
  '906e1b70-4584-4925-9fd7-f5cf6a9d7785',
  '276069b6-8083-4fee-844f-58c92ebe3a84',
  '6d2c8f2f-650f-4643-ae20-35c0e5c8feef',
  'fff28e29-9980-4840-94e9-d8e38d117f33'
);

-- Étape 3: Appliquer les valeurs correctes depuis profiles.public_id
UPDATE user_ids u
SET custom_id = p.public_id
FROM profiles p
WHERE u.user_id = p.id
  AND p.public_id IS NOT NULL;

-- Étape 4: Recréer la contrainte unique
ALTER TABLE user_ids ADD CONSTRAINT user_ids_custom_id_key UNIQUE (custom_id);
