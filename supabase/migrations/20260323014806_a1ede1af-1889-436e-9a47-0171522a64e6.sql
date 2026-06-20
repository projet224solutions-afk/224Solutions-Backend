-- Restaurer is_verified pour tous les vendeurs qui ont été incorrectement marqués false
-- par la Edge Function subscription-expiry-check
UPDATE public.vendors SET is_verified = true, updated_at = now()
WHERE is_verified = false;