
-- ============================================================
-- CORRECTION DÉFINITIVE - SYNCHRONISATION SÉQUENTIELLE
-- ============================================================

-- STRATÉGIE: Utiliser les valeurs de user_ids.custom_id comme source de vérité
-- et corriger les formats invalides

-- 1. D'abord libérer les public_id conflictuels en les mettant temporairement NULL
-- Vendeur qui a USR0002 alors qu'il devrait avoir VND0002
UPDATE profiles SET public_id = NULL WHERE id = 'e44a2103-fb04-4904-aae3-38ff3ede2db2';

-- 2. Client qui devrait avoir USR0002 (actuellement USR0004)
UPDATE profiles SET public_id = 'USR0002' WHERE id = 'dc82bc5b-30c7-493e-bb36-97c75aca0d4a';

-- 3. Maintenant assigner VND0002 au vendeur
UPDATE profiles SET public_id = 'VND0002' WHERE id = 'e44a2103-fb04-4904-aae3-38ff3ede2db2';

-- 4. Corriger les autres clients (cascade)
UPDATE profiles SET public_id = 'USR0003' WHERE id = '4e9cf40d-c838-442c-bb51-602500eb7974';
UPDATE profiles SET public_id = 'USR0004' WHERE id = '2ccd90f5-a71f-493f-adee-3422bd516cd4';
UPDATE profiles SET public_id = 'USR0005' WHERE id = 'fa67ad09-8cfa-42dc-932a-e47ef8e96017';
UPDATE profiles SET public_id = 'USR0006' WHERE id = 'de4e3fe1-0c16-4c7d-a373-bff204914e0e';
UPDATE profiles SET public_id = 'USR0007' WHERE id = '4dedf643-0f38-4481-825d-64fb39f6887b';
UPDATE profiles SET public_id = 'USR0008' WHERE id = '906e1b70-4584-4925-9fd7-f5cf6a9d7785';

-- 5. Corriger les livreurs
UPDATE profiles SET public_id = 'DRV0006' WHERE id = '6f34c07a-6d9a-4dbc-b92f-e95769eb1ff2';
UPDATE profiles SET public_id = 'DRV0008' WHERE id = '41359728-b09c-403d-b62f-2b8c938f4ee5';

-- 6. Corriger l'admin
UPDATE profiles SET public_id = 'PDG0002' WHERE id = '90a84ae7-567b-4a22-b000-507451bea915';

-- 7. Corriger le vendeur avec DKR5439 -> VND0001
UPDATE user_ids SET custom_id = 'VND0001' WHERE user_id = 'bdaa4f25-65fd-4151-8233-0436ee344c07';
UPDATE profiles SET public_id = 'VND0001' WHERE id = 'bdaa4f25-65fd-4151-8233-0436ee344c07';

-- 8. Corriger les autres vendeurs
UPDATE profiles SET public_id = 'VND0005' WHERE id = 'dad61558-36de-4dc3-9190-e1a317852ac8';
UPDATE profiles SET public_id = 'VND0006' WHERE id = '569276b0-b446-49c1-bb52-a3f08d100e3b';
UPDATE profiles SET public_id = 'VND0007' WHERE id = '276069b6-8083-4fee-844f-58c92ebe3a84';
