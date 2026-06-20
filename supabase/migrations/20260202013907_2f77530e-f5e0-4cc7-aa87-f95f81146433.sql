-- Mettre à jour la contrainte billing_cycle pour accepter les abonnements offerts
ALTER TABLE driver_subscriptions 
DROP CONSTRAINT IF EXISTS driver_subscriptions_billing_cycle_check;

ALTER TABLE driver_subscriptions 
ADD CONSTRAINT driver_subscriptions_billing_cycle_check 
CHECK (billing_cycle = ANY (ARRAY['monthly'::text, 'yearly'::text, 'lifetime'::text, 'custom'::text]));