-- Mettre à jour l'abonnement actif vers le plan gratuit
UPDATE subscriptions 
SET 
  plan_id = '26f08578-dad1-4642-951b-3a363c3e6577',
  status = 'active',
  started_at = NOW(),
  current_period_end = NOW() + INTERVAL '100 years',
  price_paid_gnf = 0,
  billing_cycle = 'lifetime',
  payment_method = 'free',
  updated_at = NOW()
WHERE user_id = 'b11e7223-c98f-4f06-a99e-70bf098bf411'
  AND status = 'active';
