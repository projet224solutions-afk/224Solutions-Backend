
-- CORRECTION PROFONDE: Synchroniser agent_wallets avec wallets et modifier process_wallet_transaction

-- 1. D'abord, synchroniser les soldes actuels de wallets vers agent_wallets
UPDATE agent_wallets aw
SET balance = w.balance,
    updated_at = now()
FROM agents_management am
JOIN wallets w ON w.user_id = am.user_id
WHERE aw.agent_id = am.id;

-- 2. Recréer la fonction process_wallet_transaction pour créditer AUSSI agent_wallets
CREATE OR REPLACE FUNCTION process_wallet_transaction(
    p_sender_id UUID,
    p_receiver_id UUID,
    p_amount NUMERIC,
    p_currency VARCHAR DEFAULT 'GNF',
    p_description TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    transaction_id UUID;
    sender_wallet_balance NUMERIC;
    v_fee_percent NUMERIC;
    v_fee_amount NUMERIC;
    v_total_debit NUMERIC;
    v_receiver_agent_id UUID;
BEGIN
    -- Vérifier le solde de l'expéditeur
    SELECT balance INTO sender_wallet_balance 
    FROM wallets 
    WHERE user_id = p_sender_id AND currency = p_currency;
    
    IF sender_wallet_balance IS NULL THEN
        RAISE EXCEPTION 'Wallet non trouvé pour l''expéditeur';
    END IF;
    
    -- Récupérer le taux de frais depuis system_settings
    SELECT COALESCE(
        (SELECT setting_value::NUMERIC FROM system_settings WHERE setting_key = 'transfer_fee_percent'),
        1.5
    ) INTO v_fee_percent;
    
    -- Calculer les frais et le total à débiter
    v_fee_amount := ROUND((p_amount * v_fee_percent / 100), 2);
    v_total_debit := p_amount + v_fee_amount;
    
    -- Vérifier le solde suffisant (montant + frais)
    IF sender_wallet_balance < v_total_debit THEN
        RAISE EXCEPTION 'Solde insuffisant. Solde: % GNF, Requis: % GNF (dont % GNF de frais)', 
            sender_wallet_balance, v_total_debit, v_fee_amount;
    END IF;
    
    -- Créer la transaction avec les métadonnées des frais
    INSERT INTO enhanced_transactions (sender_id, receiver_id, amount, currency, method, metadata, status)
    VALUES (p_sender_id, p_receiver_id, p_amount, p_currency, 'wallet', 
            jsonb_build_object(
                'description', COALESCE(p_description, ''),
                'fee_percent', v_fee_percent,
                'fee_amount', v_fee_amount,
                'total_debit', v_total_debit,
                'amount_received', p_amount
            ), 'pending')
    RETURNING id INTO transaction_id;
    
    -- Débiter l'expéditeur (montant + frais) dans wallets
    UPDATE wallets 
    SET balance = balance - v_total_debit, updated_at = now()
    WHERE user_id = p_sender_id AND currency = p_currency;
    
    -- Créditer le destinataire dans wallets
    INSERT INTO wallets (user_id, balance, currency)
    VALUES (p_receiver_id, p_amount, p_currency)
    ON CONFLICT (user_id, currency) 
    DO UPDATE SET balance = wallets.balance + p_amount, updated_at = now();
    
    -- NOUVEAU: Si le destinataire est un agent, créditer aussi agent_wallets
    SELECT am.id INTO v_receiver_agent_id
    FROM agents_management am
    WHERE am.user_id = p_receiver_id;
    
    IF v_receiver_agent_id IS NOT NULL THEN
        -- Créer ou mettre à jour le wallet agent
        INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
        VALUES (v_receiver_agent_id, p_amount, p_currency, 'active')
        ON CONFLICT (agent_id) 
        DO UPDATE SET balance = agent_wallets.balance + p_amount, updated_at = now();
    END IF;
    
    -- Si l'expéditeur est un agent, débiter aussi agent_wallets
    SELECT am.id INTO v_receiver_agent_id
    FROM agents_management am
    WHERE am.user_id = p_sender_id;
    
    IF v_receiver_agent_id IS NOT NULL THEN
        UPDATE agent_wallets 
        SET balance = balance - v_total_debit, updated_at = now()
        WHERE agent_id = v_receiver_agent_id;
    END IF;
    
    -- Marquer comme complétée
    UPDATE enhanced_transactions 
    SET status = 'completed', updated_at = now()
    WHERE id = transaction_id;
    
    RETURN transaction_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 3. Créer un trigger pour garder les wallets synchronisés automatiquement
CREATE OR REPLACE FUNCTION sync_agent_wallet_balance()
RETURNS TRIGGER AS $$
DECLARE
    v_agent_id UUID;
BEGIN
    -- Trouver si cet utilisateur est un agent
    SELECT id INTO v_agent_id
    FROM agents_management
    WHERE user_id = NEW.user_id;
    
    IF v_agent_id IS NOT NULL THEN
        -- Synchroniser le solde vers agent_wallets
        INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
        VALUES (v_agent_id, NEW.balance, NEW.currency, 'active')
        ON CONFLICT (agent_id) 
        DO UPDATE SET balance = NEW.balance, updated_at = now();
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Supprimer le trigger s'il existe déjà
DROP TRIGGER IF EXISTS sync_wallet_to_agent_wallet ON wallets;

-- Créer le trigger
CREATE TRIGGER sync_wallet_to_agent_wallet
AFTER INSERT OR UPDATE ON wallets
FOR EACH ROW
EXECUTE FUNCTION sync_agent_wallet_balance();

-- 4. Synchroniser tous les agents existants maintenant
INSERT INTO agent_wallets (agent_id, balance, currency, wallet_status)
SELECT 
    am.id,
    COALESCE(w.balance, 0),
    COALESCE(w.currency, 'GNF'),
    'active'
FROM agents_management am
LEFT JOIN wallets w ON w.user_id = am.user_id
ON CONFLICT (agent_id) 
DO UPDATE SET 
    balance = EXCLUDED.balance,
    updated_at = now();
