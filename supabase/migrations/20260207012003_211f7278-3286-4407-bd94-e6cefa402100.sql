
-- Synchroniser user_ids.custom_id avec profiles.public_id (source de vérité)
-- 9 corrections à appliquer

UPDATE user_ids SET custom_id = 'CLI0010' WHERE user_id = '276069b6-8083-4fee-844f-58c92ebe3a84';
UPDATE user_ids SET custom_id = 'AGT0011' WHERE user_id = '0dcdf30a-f2ee-4be4-b63e-589d7e793102';
UPDATE user_ids SET custom_id = 'VND0013' WHERE user_id = 'fff28e29-9980-4840-94e9-d8e38d117f33';
UPDATE user_ids SET custom_id = 'VND0010' WHERE user_id = '6d2c8f2f-650f-4643-ae20-35c0e5c8feef';
UPDATE user_ids SET custom_id = 'AGT0009' WHERE user_id = '0d551780-1bfc-4abc-a4cf-0e726de6ada4';
UPDATE user_ids SET custom_id = 'CLI0007' WHERE user_id = '906e1b70-4584-4925-9fd7-f5cf6a9d7785';
UPDATE user_ids SET custom_id = 'AGT0004' WHERE user_id = '82cfefb7-4144-4832-b345-4b7eb33b0b33';
UPDATE user_ids SET custom_id = 'AGT0003' WHERE user_id = '09df4cbd-7b10-472a-8641-e91f563f3873';
UPDATE user_ids SET custom_id = 'AGT0002' WHERE user_id = 'e2ce9080-26e9-4681-9ee0-c6896bcd2093';
