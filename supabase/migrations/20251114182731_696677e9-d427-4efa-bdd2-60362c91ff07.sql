-- Table pour les abonnements Taxi Moto et Livreur
CREATE TABLE IF NOT EXISTS driver_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('taxi', 'livreur')),
  price NUMERIC NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'expired', 'pending', 'suspended')),
  start_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  end_date TIMESTAMPTZ NOT NULL,
  payment_method TEXT NOT NULL CHECK (payment_method IN ('wallet', 'mobile_money', 'card')),
  transaction_id TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index pour optimiser les requêtes
CREATE INDEX idx_driver_subscriptions_user_id ON driver_subscriptions(user_id);
CREATE INDEX idx_driver_subscriptions_status ON driver_subscriptions(status);
CREATE INDEX idx_driver_subscriptions_end_date ON driver_subscriptions(end_date);

-- Table pour la configuration du prix de l'abonnement
CREATE TABLE IF NOT EXISTS driver_subscription_config (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_type TEXT NOT NULL UNIQUE CHECK (subscription_type IN ('taxi', 'livreur', 'both')),
  price NUMERIC NOT NULL,
  duration_days INTEGER NOT NULL DEFAULT 30,
  is_active BOOLEAN DEFAULT TRUE,
  updated_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Insérer la configuration par défaut (50 000 GNF/mois)
INSERT INTO driver_subscription_config (subscription_type, price, duration_days) 
VALUES ('both', 50000, 30)
ON CONFLICT (subscription_type) DO NOTHING;

-- Table pour l'historique des revenus d'abonnement
CREATE TABLE IF NOT EXISTS driver_subscription_revenues (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id UUID NOT NULL REFERENCES driver_subscriptions(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id),
  amount NUMERIC NOT NULL,
  payment_method TEXT NOT NULL,
  transaction_id TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Fonction pour vérifier si l'utilisateur a un abonnement actif
CREATE OR REPLACE FUNCTION has_active_driver_subscription(p_user_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM driver_subscriptions
    WHERE user_id = p_user_id
    AND status = 'active'
    AND end_date > NOW()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour obtenir l'abonnement actif d'un utilisateur
CREATE OR REPLACE FUNCTION get_active_driver_subscription(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  type TEXT,
  price NUMERIC,
  status TEXT,
  start_date TIMESTAMPTZ,
  end_date TIMESTAMPTZ,
  days_remaining INTEGER,
  payment_method TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    ds.id,
    ds.type,
    ds.price,
    ds.status,
    ds.start_date,
    ds.end_date,
    EXTRACT(DAY FROM (ds.end_date - NOW()))::INTEGER as days_remaining,
    ds.payment_method
  FROM driver_subscriptions ds
  WHERE ds.user_id = p_user_id
  AND ds.status = 'active'
  ORDER BY ds.end_date DESC
  LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour créer ou renouveler un abonnement
CREATE OR REPLACE FUNCTION subscribe_driver(
  p_user_id UUID,
  p_type TEXT,
  p_payment_method TEXT,
  p_transaction_id TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_price NUMERIC;
  v_duration_days INTEGER;
  v_subscription_id UUID;
  v_end_date TIMESTAMPTZ;
BEGIN
  -- Récupérer le prix et la durée
  SELECT price, duration_days INTO v_price, v_duration_days
  FROM driver_subscription_config
  WHERE subscription_type = 'both' AND is_active = TRUE
  LIMIT 1;
  
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'Configuration d''abonnement non trouvée';
  END IF;
  
  -- Calculer la date de fin
  v_end_date := NOW() + (v_duration_days || ' days')::INTERVAL;
  
  -- Désactiver les anciens abonnements
  UPDATE driver_subscriptions
  SET status = 'expired', updated_at = NOW()
  WHERE user_id = p_user_id AND status = 'active';
  
  -- Créer le nouvel abonnement
  INSERT INTO driver_subscriptions (
    user_id, type, price, status, start_date, end_date, payment_method, transaction_id
  ) VALUES (
    p_user_id, p_type, v_price, 'active', NOW(), v_end_date, p_payment_method, p_transaction_id
  ) RETURNING id INTO v_subscription_id;
  
  -- Enregistrer le revenu
  INSERT INTO driver_subscription_revenues (
    subscription_id, user_id, amount, payment_method, transaction_id
  ) VALUES (
    v_subscription_id, p_user_id, v_price, p_payment_method, p_transaction_id
  );
  
  RETURN v_subscription_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour marquer les abonnements expirés
CREATE OR REPLACE FUNCTION mark_expired_driver_subscriptions()
RETURNS INTEGER AS $$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE driver_subscriptions
  SET status = 'expired', updated_at = NOW()
  WHERE status = 'active' AND end_date < NOW()
  RETURNING COUNT(*) INTO v_count;
  
  RETURN COALESCE(v_count, 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RLS Policies
ALTER TABLE driver_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_subscription_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_subscription_revenues ENABLE ROW LEVEL SECURITY;

-- Utilisateurs peuvent voir leurs propres abonnements
CREATE POLICY "Users can view own subscriptions"
ON driver_subscriptions FOR SELECT
USING (auth.uid() = user_id);

-- Admins peuvent tout voir
CREATE POLICY "Admins can view all subscriptions"
ON driver_subscriptions FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

-- Service role peut tout faire
CREATE POLICY "Service role full access subscriptions"
ON driver_subscriptions FOR ALL
USING (auth.role() = 'service_role');

-- Config: Admins peuvent gérer
CREATE POLICY "Admins manage subscription config"
ON driver_subscription_config FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

-- Config: Tout le monde peut voir
CREATE POLICY "Everyone can view subscription config"
ON driver_subscription_config FOR SELECT
USING (TRUE);

-- Revenus: Admins seulement
CREATE POLICY "Admins manage revenues"
ON driver_subscription_revenues FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM profiles
    WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
  )
);

-- Trigger pour mettre à jour updated_at
CREATE OR REPLACE FUNCTION update_driver_subscription_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER driver_subscriptions_updated_at
BEFORE UPDATE ON driver_subscriptions
FOR EACH ROW EXECUTE FUNCTION update_driver_subscription_updated_at();

CREATE TRIGGER driver_subscription_config_updated_at
BEFORE UPDATE ON driver_subscription_config
FOR EACH ROW EXECUTE FUNCTION update_driver_subscription_updated_at();