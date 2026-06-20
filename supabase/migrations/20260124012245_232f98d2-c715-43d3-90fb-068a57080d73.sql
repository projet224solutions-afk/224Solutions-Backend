-- STRATÉGIE: profiles.public_id doit être synchronisé avec user_ids.custom_id
-- Les IDs séquentiels dans user_ids (VND0001-VND0006) sont corrects
-- On corrige profiles.public_id pour qu'il corresponde

-- VND0005 → VND0001 (user dad61558)
UPDATE profiles 
SET public_id = 'VND0001'
WHERE id = 'dad61558-36de-4dc3-9190-e1a317852ac8';

-- VND0006 → VND0002 (user 569276b0)
UPDATE profiles 
SET public_id = 'VND0002'
WHERE id = '569276b0-b446-49c1-bb52-a3f08d100e3b';

-- VND0068 → VND0003 (user fca38d2e)
UPDATE profiles 
SET public_id = 'VND0003'
WHERE id = 'fca38d2e-c909-41ac-9efb-c2ed4979c622';

-- VND0069 → VND0005 (user bb5f7f19)
UPDATE profiles 
SET public_id = 'VND0005'
WHERE id = 'bb5f7f19-9c3d-4a3d-8c8b-2f9c8143fa22';

-- VND0070 → VND0006 (user e44a2103)
UPDATE profiles 
SET public_id = 'VND0006'
WHERE id = 'e44a2103-fb04-4904-aae3-38ff3ede2db2';

-- Mettre à jour le compteur id_counters pour refléter le max réel (6)
UPDATE id_counters 
SET current_value = 6
WHERE prefix = 'VND';