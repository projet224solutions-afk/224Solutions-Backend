-- =============================================
-- FONCTION: Ajout véhicule pour Bureau Syndicat
-- Contourne les problèmes RLS avec SECURITY DEFINER
-- =============================================

-- 1. Fonction pour ajouter un membre syndical (si nécessaire)
CREATE OR REPLACE FUNCTION public.add_syndicate_member_for_vehicle(
    p_bureau_id UUID,
    p_nom TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_member_id UUID;
    v_unique_token TEXT;
    v_unique_email TEXT;
BEGIN
    -- Générer des valeurs uniques
    v_unique_token := 'mbr_' || encode(gen_random_bytes(16), 'hex');
    v_unique_email := 'member_' || encode(gen_random_bytes(8), 'hex') || '@bureau.local';
    
    -- Insérer le nouveau membre
    INSERT INTO public.syndicate_workers (
        bureau_id,
        nom,
        email,
        telephone,
        access_token,
        interface_url,
        access_level,
        is_active
    ) VALUES (
        p_bureau_id,
        p_nom,
        v_unique_email,
        '',
        v_unique_token,
        '',
        'member',
        true
    )
    RETURNING id INTO v_member_id;
    
    RETURN v_member_id;
END;
$$;

-- 2. Fonction principale pour ajouter un véhicule
CREATE OR REPLACE FUNCTION public.add_vehicle_for_bureau(
    p_bureau_id UUID,
    p_owner_name TEXT DEFAULT NULL,
    p_member_id UUID DEFAULT NULL,
    p_serial_number TEXT DEFAULT NULL,
    p_license_plate TEXT DEFAULT NULL,
    p_vehicle_type TEXT DEFAULT 'motorcycle',
    p_brand TEXT DEFAULT NULL,
    p_model TEXT DEFAULT NULL,
    p_year INTEGER DEFAULT NULL,
    p_color TEXT DEFAULT NULL,
    p_driver_photo_url TEXT DEFAULT NULL,
    p_driver_date_of_birth DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_member_id UUID;
    v_vehicle_id UUID;
    v_badge_id TEXT;
    v_qr_code_data TEXT;
    v_member_name TEXT;
    v_result JSON;
BEGIN
    -- Validation des entrées requises
    IF p_serial_number IS NULL OR p_serial_number = '' THEN
        RETURN json_build_object('success', false, 'error', 'Numéro de série requis');
    END IF;
    
    IF p_license_plate IS NULL OR p_license_plate = '' THEN
        RETURN json_build_object('success', false, 'error', 'Plaque d''immatriculation requise');
    END IF;
    
    -- Vérifier que le bureau existe
    IF NOT EXISTS (SELECT 1 FROM public.bureaus WHERE id = p_bureau_id) THEN
        RETURN json_build_object('success', false, 'error', 'Bureau introuvable');
    END IF;
    
    -- Vérifier si le numéro de série existe déjà
    IF EXISTS (SELECT 1 FROM public.vehicles WHERE serial_number = p_serial_number) THEN
        RETURN json_build_object('success', false, 'error', 'Ce numéro de série existe déjà');
    END IF;
    
    -- Déterminer le membre
    IF p_member_id IS NOT NULL THEN
        -- Utiliser le membre existant
        SELECT id, nom INTO v_member_id, v_member_name 
        FROM public.syndicate_workers 
        WHERE id = p_member_id;
        
        IF v_member_id IS NULL THEN
            RETURN json_build_object('success', false, 'error', 'Membre introuvable');
        END IF;
    ELSIF p_owner_name IS NOT NULL AND p_owner_name != '' THEN
        -- Créer un nouveau membre
        v_member_id := public.add_syndicate_member_for_vehicle(p_bureau_id, p_owner_name);
        v_member_name := p_owner_name;
    ELSE
        RETURN json_build_object('success', false, 'error', 'Nom du propriétaire ou membre requis');
    END IF;
    
    -- Générer le badge ID
    v_badge_id := 'BDG-' || UPPER(SUBSTRING(encode(gen_random_bytes(4), 'hex') FROM 1 FOR 8));
    
    -- Générer les données QR code
    v_qr_code_data := json_build_object(
        'serial_number', p_serial_number,
        'license_plate', p_license_plate,
        'owner', v_member_name,
        'bureau', p_bureau_id,
        'type', COALESCE(p_vehicle_type, 'motorcycle'),
        'issued_date', NOW()
    )::text;
    
    -- Insérer le véhicule
    INSERT INTO public.vehicles (
        bureau_id,
        owner_member_id,
        serial_number,
        license_plate,
        type,
        brand,
        model,
        year,
        color,
        digital_badge_id,
        qr_code_data,
        badge_generated_at,
        driver_photo_url,
        driver_date_of_birth,
        status,
        verified,
        stolen_status
    ) VALUES (
        p_bureau_id,
        v_member_id,
        UPPER(TRIM(p_serial_number)),
        UPPER(TRIM(p_license_plate)),
        COALESCE(p_vehicle_type, 'motorcycle'),
        NULLIF(TRIM(p_brand), ''),
        NULLIF(TRIM(p_model), ''),
        p_year,
        NULLIF(TRIM(p_color), ''),
        v_badge_id,
        v_qr_code_data,
        NOW(),
        NULLIF(TRIM(p_driver_photo_url), ''),
        p_driver_date_of_birth,
        'active',
        false,
        'clean'
    )
    RETURNING id INTO v_vehicle_id;
    
    -- Retourner le résultat
    SELECT json_build_object(
        'success', true,
        'vehicle_id', v_vehicle_id,
        'member_id', v_member_id,
        'badge_id', v_badge_id,
        'message', 'Véhicule ajouté avec succès'
    ) INTO v_result;
    
    RETURN v_result;
    
EXCEPTION
    WHEN unique_violation THEN
        RETURN json_build_object('success', false, 'error', 'Un véhicule avec ces informations existe déjà');
    WHEN OTHERS THEN
        RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- 3. Accorder les permissions
GRANT EXECUTE ON FUNCTION public.add_syndicate_member_for_vehicle(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.add_vehicle_for_bureau(UUID, TEXT, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT, DATE) TO anon, authenticated;