-- Harmoniser les remises annuelles à 15% sur toutes les tables d'abonnement

-- 1. Mettre à jour la table plans (vendeurs)
UPDATE plans 
SET yearly_discount_percentage = 15,
    yearly_price_gnf = monthly_price_gnf * 12 * 0.85,
    updated_at = NOW()
WHERE yearly_discount_percentage != 15;

-- 2. Mettre à jour la table service_plans (services professionnels)
UPDATE service_plans 
SET yearly_discount_percentage = 15,
    yearly_price_gnf = monthly_price_gnf * 12 * 0.85,
    updated_at = NOW()
WHERE yearly_discount_percentage != 15;

-- 3. Mettre à jour la table driver_subscription_config (chauffeurs)
UPDATE driver_subscription_config 
SET yearly_discount_percentage = 15,
    yearly_price = price * 12 * 0.85,
    updated_at = NOW()
WHERE yearly_discount_percentage != 15;