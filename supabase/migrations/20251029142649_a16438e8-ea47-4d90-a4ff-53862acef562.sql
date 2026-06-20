-- Restaurer le format d'ID original LLLDDDD (3 lettres + 4 chiffres)

-- Fonction pour générer 3 lettres aléatoires (sans I, L, O)
CREATE OR REPLACE FUNCTION generate_random_letters_original(length INT)
RETURNS TEXT AS $$
DECLARE
    letters TEXT := 'ABCDEFGHJKMNPQRSTUVWXYZ'; -- Sans I, L, O
    result TEXT := '';
    i INT;
BEGIN
    FOR i IN 1..length LOOP
        result := result || substr(letters, floor(random() * length(letters) + 1)::int, 1);
    END LOOP;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour générer 4 chiffres aléatoires
CREATE OR REPLACE FUNCTION generate_random_digits(length INT)
RETURNS TEXT AS $$
DECLARE
    result TEXT := '';
    i INT;
BEGIN
    FOR i IN 1..length LOOP
        result := result || floor(random() * 10)::int::text;
    END LOOP;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Fonction principale pour générer un custom_id au format LLLDDDD
CREATE OR REPLACE FUNCTION generate_custom_id_original()
RETURNS TEXT AS $$
BEGIN
    RETURN generate_random_letters_original(3) || generate_random_digits(4);
END;
$$ LANGUAGE plpgsql;

-- Mettre à jour tous les custom_id existants pour qu'ils suivent le format LLLDDDD
UPDATE user_ids
SET custom_id = generate_custom_id_original()
WHERE custom_id IS NOT NULL;

-- Mettre à jour également dans la table profiles si elle existe
UPDATE profiles
SET custom_id = (SELECT custom_id FROM user_ids WHERE user_ids.user_id = profiles.id)
WHERE id IN (SELECT user_id FROM user_ids WHERE custom_id IS NOT NULL);