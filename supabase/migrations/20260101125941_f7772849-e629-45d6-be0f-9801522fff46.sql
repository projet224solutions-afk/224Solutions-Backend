-- Réinitialisation des soldes wallet pour centralisation Jomy.africa
-- Tous les soldes sont remis à 0, seuls les paiements Jomy valides compteront

-- Reset des wallets utilisateurs
UPDATE public.wallets SET balance = 0, updated_at = now();

-- Reset des wallets agents
UPDATE public.agent_wallets SET balance = 0, updated_at = now();

-- Reset des wallets bureaux
UPDATE public.bureau_wallets SET balance = 0, updated_at = now();

-- Log de la réinitialisation
INSERT INTO public.djomy_webhook_logs (event_type, transaction_id, payload, processed_at)
VALUES (
  'system.balance_reset',
  'RESET-' || gen_random_uuid()::text,
  jsonb_build_object(
    'reason', 'Centralisation paiements Jomy.africa',
    'reset_date', now(),
    'tables_affected', ARRAY['wallets', 'agent_wallets', 'bureau_wallets']
  ),
  now()
);