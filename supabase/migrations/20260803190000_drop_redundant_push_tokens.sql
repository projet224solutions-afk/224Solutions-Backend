-- NETTOYAGE : la table `user_fcm_tokens` (déjà peuplée, ~41 tokens, utilisée par push.service.ts →
-- sendPushToUser → Edge smart-notifications → FCM) est LA table de tokens. `push_tokens` créée dans
-- 20260803180000 faisait doublon (découverte après coup) → on la retire (aucune donnée, aucun usage).
-- Les autres apports de 20260803180000 restent : notifications.link/category/read_at,
-- notification_preferences, notification_channel_enabled, create_notification.
DROP TABLE IF EXISTS public.push_tokens;
