-- Ajouter le compteur CLT s'il n'existe pas
INSERT INTO id_counters (prefix, current_value, description)
VALUES ('CLT', 0, 'Compteur clients - format CLT0001')
ON CONFLICT (prefix) DO NOTHING;

-- Récupérer le dernier numéro CLT existant dans user_ids
DO $$
DECLARE
    max_clt_num INTEGER := 0;
    temp_num INTEGER;
    rec RECORD;
BEGIN
    -- Chercher tous les IDs commençant par CLT dans user_ids
    FOR rec IN 
        SELECT custom_id FROM user_ids WHERE custom_id LIKE 'CLT%'
    LOOP
        -- Extraire le numéro
        temp_num := COALESCE(
            NULLIF(regexp_replace(rec.custom_id, '^CLT', '', 'i'), '')::INTEGER,
            0
        );
        IF temp_num > max_clt_num THEN
            max_clt_num := temp_num;
        END IF;
    END LOOP;
    
    -- Mettre à jour le compteur avec la valeur max trouvée
    UPDATE id_counters 
    SET current_value = max_clt_num,
        updated_at = NOW()
    WHERE prefix = 'CLT';
END $$;

-- Mettre à jour aussi pour les anciens USR, CLI etc vers le format CLT
-- D'abord, regarder combien d'utilisateurs ont besoin de migration
-- Note: on ne migre pas automatiquement pour éviter les conflits, 
-- mais on s'assure que les nouveaux utilisateurs auront le bon format