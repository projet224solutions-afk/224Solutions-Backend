
-- Corriger les wallets existants avec solde 0 dont la devise ne correspond pas à la devise détectée du profil
UPDATE wallets w
SET currency = p.detected_currency, updated_at = now()
FROM profiles p
WHERE p.id = w.user_id
AND p.detected_currency IS NOT NULL
AND w.currency != p.detected_currency
AND w.balance = 0;
