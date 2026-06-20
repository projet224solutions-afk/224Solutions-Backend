-- Corriger les custom_ids pour utiliser des lettres au lieu de hex
-- Fonction helper pour générer 3 lettres aléatoires
CREATE OR REPLACE FUNCTION generate_random_letters(length INT)
RETURNS TEXT AS $$
DECLARE
    chars TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    result TEXT := '';
    i INT;
BEGIN
    FOR i IN 1..length LOOP
        result := result || substr(chars, floor(random() * length(chars) + 1)::int, 1);
    END LOOP;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Mettre à jour tous les custom_ids avec le bon format
UPDATE user_ids ui
SET custom_id = 
    CASE 
        WHEN p.role = 'client' THEN '0002' || generate_random_letters(3)
        WHEN p.role = 'vendeur' THEN '0001' || generate_random_letters(3)
        WHEN p.role = 'admin' THEN '0000' || generate_random_letters(3)
        WHEN p.role IN ('livreur', 'taxi') THEN '0003' || generate_random_letters(3)
        ELSE '9999' || generate_random_letters(3)
    END
FROM profiles p
WHERE ui.user_id = p.id;