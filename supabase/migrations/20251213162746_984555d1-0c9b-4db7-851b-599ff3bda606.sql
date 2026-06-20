-- =============================================
-- CORRECTION: Synchronisation is_stolen et stolen_status
-- =============================================

-- 1. D'abord, synchroniser les données existantes
UPDATE vehicles 
SET is_stolen = true 
WHERE stolen_status = 'stolen' AND is_stolen = false;

-- 2. Recréer la fonction declare_vehicle_stolen avec is_stolen = TRUE
CREATE OR REPLACE FUNCTION declare_vehicle_stolen(
    p_vehicle_id UUID,
    p_declared_by UUID,
    p_reason TEXT,
    p_location TEXT DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_vehicle RECORD;
BEGIN
    -- Vérifier que le véhicule existe
    SELECT * INTO v_vehicle FROM vehicles WHERE id = p_vehicle_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Véhicule non trouvé');
    END IF;
    
    -- Vérifier que le véhicule n'est pas déjà déclaré volé
    IF v_vehicle.stolen_status = 'stolen' OR v_vehicle.is_stolen = true THEN
        RETURN jsonb_build_object('success', false, 'error', 'Ce véhicule est déjà déclaré volé');
    END IF;
    
    -- Mettre à jour le véhicule (INCLURE is_stolen = TRUE)
    UPDATE vehicles SET
        is_stolen = TRUE,  -- CORRECTION: Ajouter cette ligne
        stolen_status = 'stolen',
        stolen_declared_at = NOW(),
        stolen_declared_by = p_declared_by,
        stolen_reason = p_reason,
        stolen_location = p_location,
        status = 'suspended',
        security_lock_level = 3,
        updated_at = NOW()
    WHERE id = p_vehicle_id;
    
    -- Enregistrer dans le journal de sécurité
    INSERT INTO vehicle_security_log (
        vehicle_id,
        action,
        actor_id,
        actor_type,
        description,
        metadata
    ) VALUES (
        p_vehicle_id,
        'DECLARED_STOLEN',
        p_declared_by,
        'bureau',
        'Véhicule déclaré volé: ' || p_reason,
        jsonb_build_object(
            'reason', p_reason,
            'location', p_location,
            'declared_at', NOW()
        )
    );
    
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Véhicule déclaré volé avec succès',
        'vehicle_id', p_vehicle_id
    );
END;
$$;

-- 3. Recréer la fonction declare_vehicle_recovered pour vérifier les deux colonnes
CREATE OR REPLACE FUNCTION declare_vehicle_recovered(
    p_vehicle_id UUID,
    p_recovered_by UUID,
    p_recovery_notes TEXT DEFAULT NULL,
    p_recovery_location TEXT DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_vehicle RECORD;
BEGIN
    -- Vérifier que le véhicule existe
    SELECT * INTO v_vehicle FROM vehicles WHERE id = p_vehicle_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Véhicule non trouvé');
    END IF;
    
    -- CORRECTION: Vérifier stolen_status OU is_stolen (pas seulement is_stolen)
    IF v_vehicle.stolen_status != 'stolen' AND v_vehicle.is_stolen != true THEN
        RETURN jsonb_build_object('success', false, 'error', 'Ce véhicule n''est pas déclaré volé');
    END IF;
    
    -- Mettre à jour le véhicule
    UPDATE vehicles SET
        is_stolen = false,
        stolen_status = 'recovered',
        status = 'active',
        security_lock_level = 0,
        recovery_notes = p_recovery_notes,
        recovery_location = p_recovery_location,
        recovered_at = NOW(),
        recovered_by = p_recovered_by,
        updated_at = NOW()
    WHERE id = p_vehicle_id;
    
    -- Résoudre toutes les alertes de fraude associées
    UPDATE vehicle_fraud_alerts SET
        is_resolved = true,
        resolved_at = NOW(),
        resolved_by = p_recovered_by,
        resolution_notes = 'Véhicule récupéré'
    WHERE vehicle_id = p_vehicle_id AND is_resolved = false;
    
    -- Enregistrer dans le journal de sécurité
    INSERT INTO vehicle_security_log (
        vehicle_id,
        action,
        actor_id,
        actor_type,
        description,
        metadata
    ) VALUES (
        p_vehicle_id,
        'RECOVERED',
        p_recovered_by,
        'bureau',
        'Véhicule récupéré: ' || COALESCE(p_recovery_notes, 'Aucune note'),
        jsonb_build_object(
            'notes', p_recovery_notes,
            'location', p_recovery_location,
            'recovered_at', NOW()
        )
    );
    
    RETURN jsonb_build_object(
        'success', true,
        'message', 'Véhicule marqué comme récupéré avec succès',
        'vehicle_id', p_vehicle_id
    );
END;
$$;