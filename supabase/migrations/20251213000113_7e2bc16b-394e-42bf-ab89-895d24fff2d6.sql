-- Synchroniser les soldes agent_wallets avec wallets (source de vérité)
UPDATE agent_wallets aw
SET balance = w.balance, updated_at = now()
FROM agents_management am
JOIN wallets w ON am.user_id = w.user_id
WHERE aw.agent_id = am.id
AND aw.balance != w.balance;

-- Vérifier la synchronisation
SELECT 
  am.name,
  aw.balance as agent_wallet_balance,
  w.balance as main_wallet_balance,
  CASE WHEN aw.balance = w.balance THEN 'SYNCED' ELSE 'MISMATCH' END as sync_status
FROM agents_management am
JOIN agent_wallets aw ON am.id = aw.agent_id
JOIN wallets w ON am.user_id = w.user_id;