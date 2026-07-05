-- ============================================================================
-- 💸 POLITIQUE COÛT SMS — réglage PDG : quels types de notifications déclenchent un SMS.
-- ----------------------------------------------------------------------------
-- Contexte : le dispatcher multicanal (backend /api/v2/notifications/dispatch) envoyait un
-- SMS pour CHAQUE notification dès que le profil avait un téléphone → coût explosif.
-- Ici : un réglage `pdg_settings` (clé `sms_notification_types`, jsonb LISTE) restreint les
-- SMS aux types CRITIQUES. Les autres notifications restent en email + in-app.
--
-- Le dispatcher lit ce réglage avec un cache mémoire ~60s (voir notificationDispatch.routes.ts)
-- et le PDG le modifie via GET/PUT /api/admin/sms-notification-types (admin.routes.ts).
--
-- ⚠️ N'AFFECTE PAS l'OTP : les codes OTP de connexion/inscription partent DIRECTEMENT
--    (Supabase Auth SMS pour l'OTP de login, `sendSms()` pour l'inscription) et NE passent
--    PAS par la table `notifications` ni par ce dispatcher. Ils partent donc toujours.
-- ============================================================================

INSERT INTO public.pdg_settings (setting_key, setting_value, description)
VALUES (
  'sms_notification_types',
  '["transfer","withdrawal","security","otp","payment_received"]'::jsonb,
  'Types de notifications qui déclenchent un SMS (politique coût). Les autres restent email + in-app.'
)
ON CONFLICT (setting_key) DO NOTHING;

SELECT 'Réglage sms_notification_types posé (défaut: transfer, withdrawal, security, otp, payment_received).' AS status;
