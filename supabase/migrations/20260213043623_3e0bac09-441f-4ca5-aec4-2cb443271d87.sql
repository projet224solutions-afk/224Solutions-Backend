
-- Créditer le wallet pour le dépôt Stripe réussi (pi_3T0DzoRxqizQJVjL1L1FT0bJ)
INSERT INTO wallet_transactions (
  transaction_id, transaction_type, amount, net_amount, fee, currency, status, 
  description, receiver_wallet_id, receiver_user_id, metadata
) VALUES (
  'TOP_MANUAL_' || extract(epoch from now())::bigint,
  'deposit',
  5250,
  5250,
  0,
  'GNF',
  'completed',
  'Recharge wallet par carte bancaire (Stripe) - correction manuelle',
  81,
  '906e1b70-4584-4925-9fd7-f5cf6a9d7785',
  '{"stripe_payment_intent_id": "pi_3T0DzoRxqizQJVjL1L1FT0bJ", "manual_correction": true}'::jsonb
);

-- Mettre à jour le solde du wallet
UPDATE wallets SET balance = balance + 5250 WHERE id = 81;
