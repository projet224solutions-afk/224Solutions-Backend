-- Fonction pour récupérer la configuration de commission active
CREATE OR REPLACE FUNCTION get_active_commission_config(
    p_service_name TEXT,
    p_transaction_type TEXT,
    p_amount DECIMAL DEFAULT NULL
)
RETURNS TABLE(
    id UUID,
    service_name TEXT,
    transaction_type TEXT,
    commission_type TEXT,
    commission_value DECIMAL,
    min_amount DECIMAL,
    max_amount DECIMAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        cc.id,
        cc.service_name,
        cc.transaction_type,
        cc.commission_type,
        cc.commission_value,
        cc.min_amount,
        cc.max_amount
    FROM commission_config cc
    WHERE cc.service_name = p_service_name
        AND cc.transaction_type = p_transaction_type
        AND cc.is_active = true
        AND (p_amount IS NULL OR (
            (cc.min_amount IS NULL OR p_amount >= cc.min_amount)
            AND (cc.max_amount IS NULL OR p_amount <= cc.max_amount)
        ))
    ORDER BY cc.created_at DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour calculer la commission selon la configuration
CREATE OR REPLACE FUNCTION calculate_commission_from_config(
    p_service_name TEXT,
    p_transaction_type TEXT,
    p_amount DECIMAL
)
RETURNS TABLE(
    commission_amount DECIMAL,
    commission_rate DECIMAL,
    total_amount DECIMAL,
    config_id UUID
) AS $$
DECLARE
    v_config RECORD;
    v_commission DECIMAL := 0;
    v_rate DECIMAL := 0;
BEGIN
    -- Récupérer la configuration active
    SELECT * INTO v_config
    FROM get_active_commission_config(p_service_name, p_transaction_type, p_amount);
    
    IF v_config IS NULL THEN
        -- Pas de config, retourner montant sans commission
        RETURN QUERY SELECT 0::DECIMAL, 0::DECIMAL, p_amount, NULL::UUID;
        RETURN;
    END IF;
    
    -- Calculer selon le type de commission
    CASE v_config.commission_type
        WHEN 'percentage' THEN
            v_rate := v_config.commission_value / 100;
            v_commission := p_amount * v_rate;
        WHEN 'fixed' THEN
            v_commission := v_config.commission_value;
        WHEN 'hybrid' THEN
            -- Pour hybrid: valeur fixe + pourcentage (ex: 1000 + 1.5%)
            v_rate := 0.015; -- 1.5% par défaut pour hybrid
            v_commission := v_config.commission_value + (p_amount * v_rate);
        ELSE
            v_commission := 0;
    END CASE;
    
    RETURN QUERY SELECT 
        v_commission,
        v_rate,
        p_amount + v_commission,
        v_config.id;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour enregistrer une transaction avec commission configurée
CREATE OR REPLACE FUNCTION record_service_transaction(
    p_service_name TEXT,
    p_transaction_type TEXT,
    p_amount DECIMAL,
    p_from_user_id UUID,
    p_to_user_id UUID DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_transaction_id UUID;
    v_commission_calc RECORD;
    v_from_wallet_id UUID;
    v_to_wallet_id UUID;
BEGIN
    -- Récupérer les wallet IDs
    SELECT id INTO v_from_wallet_id FROM wallets WHERE user_id = p_from_user_id AND is_active = true LIMIT 1;
    IF p_to_user_id IS NOT NULL THEN
        SELECT id INTO v_to_wallet_id FROM wallets WHERE user_id = p_to_user_id AND is_active = true LIMIT 1;
    END IF;
    
    -- Calculer la commission
    SELECT * INTO v_commission_calc
    FROM calculate_commission_from_config(p_service_name, p_transaction_type, p_amount);
    
    -- Créer la transaction
    INSERT INTO wallet_transactions (
        from_wallet_id,
        to_wallet_id,
        amount,
        fee,
        currency,
        transaction_type,
        status,
        description,
        metadata
    ) VALUES (
        v_from_wallet_id,
        v_to_wallet_id,
        p_amount,
        v_commission_calc.commission_amount,
        'GNF',
        p_service_name || '_' || p_transaction_type,
        'completed',
        COALESCE(p_description, p_service_name || ' - ' || p_transaction_type),
        COALESCE(p_metadata, '{}'::jsonb) || jsonb_build_object(
            'service_name', p_service_name,
            'transaction_type', p_transaction_type,
            'commission_config_id', v_commission_calc.config_id,
            'commission_rate', v_commission_calc.commission_rate
        )
    ) RETURNING id INTO v_transaction_id;
    
    -- Mettre à jour les soldes des wallets
    IF v_from_wallet_id IS NOT NULL THEN
        UPDATE wallets 
        SET balance = balance - (p_amount + v_commission_calc.commission_amount),
            updated_at = NOW()
        WHERE id = v_from_wallet_id;
    END IF;
    
    IF v_to_wallet_id IS NOT NULL THEN
        UPDATE wallets 
        SET balance = balance + p_amount,
            updated_at = NOW()
        WHERE id = v_to_wallet_id;
    END IF;
    
    RETURN v_transaction_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_active_commission_config IS 'Récupère la configuration de commission active pour un service';
COMMENT ON FUNCTION calculate_commission_from_config IS 'Calcule la commission selon la configuration active';
COMMENT ON FUNCTION record_service_transaction IS 'Enregistre une transaction avec commission automatique depuis config';