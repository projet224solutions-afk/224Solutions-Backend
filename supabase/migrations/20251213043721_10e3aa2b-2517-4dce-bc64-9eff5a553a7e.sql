-- Supprimer l'ancienne fonction et la recréer
DROP FUNCTION IF EXISTS public.declare_vehicle_recovered(uuid, uuid, uuid, text, text, text);

CREATE OR REPLACE FUNCTION public.declare_vehicle_recovered(
    p_vehicle_id UUID,
    p_bureau_id UUID,
    p_recovered_by UUID,
    p_recovery_notes TEXT DEFAULT NULL,
    p_ip_address TEXT DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_vehicle RECORD;
BEGIN
    SELECT * INTO v_vehicle FROM vehicles WHERE id = p_vehicle_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Véhicule non trouvé');
    END IF;
    
    IF v_vehicle.is_stolen != true THEN
        RETURN jsonb_build_object('success', false, 'error', 'Ce véhicule n''est pas déclaré volé');
    END IF;
    
    UPDATE vehicles SET
        is_stolen = false,
        stolen_status = 'recovered',
        status = 'active',
        updated_at = NOW()
    WHERE id = p_vehicle_id;
    
    INSERT INTO vehicle_security_log (
        vehicle_id, bureau_id, action, actor_id, actor_type,
        description, ip_address, user_agent, metadata
    ) VALUES (
        p_vehicle_id, p_bureau_id, 'stolen_recovered', p_recovered_by, 'bureau',
        'Récupération du véhicule: ' || COALESCE(v_vehicle.license_plate, 'N/A'),
        p_ip_address, p_user_agent,
        jsonb_build_object('recovery_notes', p_recovery_notes, 'license_plate', v_vehicle.license_plate, 'recovered_at', NOW())
    );
    
    INSERT INTO vehicle_fraud_alerts (
        vehicle_id, bureau_id, alert_type, severity, description, is_resolved
    ) VALUES (
        p_vehicle_id, p_bureau_id, 'RECOVERY_DECLARATION', 'low',
        'Véhicule récupéré: ' || COALESCE(v_vehicle.license_plate, 'N/A'), true
    );
    
    UPDATE vehicle_fraud_alerts SET
        is_resolved = true, resolved_at = NOW(), resolved_by = p_recovered_by, resolution_notes = 'Véhicule récupéré'
    WHERE vehicle_id = p_vehicle_id AND alert_type = 'THEFT_DECLARATION' AND is_resolved = false;
    
    RETURN jsonb_build_object('success', true, 'message', 'Véhicule récupéré avec succès', 'vehicle_id', p_vehicle_id);
    
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;