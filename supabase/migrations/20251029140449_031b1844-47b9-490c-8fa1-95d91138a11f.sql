-- Fonction pour générer un custom_id basé sur le rôle
CREATE OR REPLACE FUNCTION generate_custom_id_with_role(p_role TEXT DEFAULT 'client') 
RETURNS TEXT AS $$
DECLARE
    v_letters TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    v_numbers TEXT := '0123456789';
    v_result TEXT := '';
    v_i INTEGER;
    v_prefix TEXT;
BEGIN
    -- Définir le préfixe selon le rôle
    CASE p_role
        WHEN 'client' THEN
            v_prefix := '0002';
        WHEN 'vendeur' THEN
            v_prefix := '0001';
        WHEN 'admin' THEN
            v_prefix := '0000';
        WHEN 'livreur' THEN
            v_prefix := '0003';
        ELSE
            v_prefix := '9999';
    END CASE;
    
    -- Commencer avec le préfixe
    v_result := v_prefix;
    
    -- Ajouter 3 lettres aléatoires
    FOR v_i IN 1..3 LOOP
        v_result := v_result || substr(v_letters, floor(random() * length(v_letters) + 1)::integer, 1);
    END LOOP;
    
    -- Vérifier l'unicité et régénérer si nécessaire
    WHILE EXISTS (SELECT 1 FROM user_ids WHERE custom_id = v_result) LOOP
        v_result := v_prefix;
        FOR v_i IN 1..3 LOOP
            v_result := v_result || substr(v_letters, floor(random() * length(v_letters) + 1)::integer, 1);
        END LOOP;
    END LOOP;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Mettre à jour la fonction create_user_complete pour utiliser le nouveau générateur
CREATE OR REPLACE FUNCTION create_user_complete(
    p_user_id UUID,
    p_role TEXT DEFAULT 'client'
) RETURNS JSON AS $$
DECLARE
    v_wallet_id UUID;
    v_custom_id TEXT;
    v_result JSON;
BEGIN
    -- Générer un ID personnalisé basé sur le rôle
    v_custom_id := generate_custom_id_with_role(p_role);
    
    -- Créer le wallet automatiquement si pas déjà existant
    INSERT INTO wallets (user_id, balance, currency)
    VALUES (p_user_id, 10000, 'GNF')
    ON CONFLICT (user_id, currency) DO NOTHING
    RETURNING id INTO v_wallet_id;
    
    -- Si le wallet existait déjà, récupérer son ID
    IF v_wallet_id IS NULL THEN
        SELECT id INTO v_wallet_id FROM wallets WHERE user_id = p_user_id AND currency = 'GNF';
    END IF;
    
    -- Créer l'ID personnalisé
    INSERT INTO user_ids (user_id, custom_id)
    VALUES (p_user_id, v_custom_id)
    ON CONFLICT (user_id) DO UPDATE SET custom_id = EXCLUDED.custom_id;
    
    -- Retourner le résultat
    v_result := json_build_object(
        'user_id', p_user_id,
        'wallet_id', v_wallet_id,
        'custom_id', v_custom_id,
        'status', 'created'
    );
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;