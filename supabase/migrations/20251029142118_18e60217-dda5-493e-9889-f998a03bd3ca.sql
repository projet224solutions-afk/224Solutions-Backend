-- Mise à jour manuelle des custom_ids vers le nouveau format
-- Clients: 0002XXX
UPDATE user_ids 
SET custom_id = '0002' || substring(md5(random()::text) from 1 for 3) 
WHERE user_id IN (
    SELECT id FROM profiles WHERE role = 'client'
) AND custom_id NOT LIKE '0002%';

-- Vendeurs: 0001XXX  
UPDATE user_ids 
SET custom_id = '0001' || substring(md5(random()::text) from 1 for 3)
WHERE user_id IN (
    SELECT id FROM profiles WHERE role = 'vendeur'
) AND custom_id NOT LIKE '0001%';

-- Admins: 0000XXX
UPDATE user_ids 
SET custom_id = '0000' || substring(md5(random()::text) from 1 for 3)
WHERE user_id IN (
    SELECT id FROM profiles WHERE role = 'admin'
) AND custom_id NOT LIKE '0000%';

-- Livreurs et Taxis: 0003XXX
UPDATE user_ids 
SET custom_id = '0003' || substring(md5(random()::text) from 1 for 3)
WHERE user_id IN (
    SELECT id FROM profiles WHERE role IN ('livreur', 'taxi')
) AND custom_id NOT LIKE '0003%';