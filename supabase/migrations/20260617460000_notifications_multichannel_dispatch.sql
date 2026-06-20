-- ============================================================================
-- 🔔 NOTIFICATIONS MULTICANAL — email + SMS pour TOUTES les notifications.
--
-- Funnel UNIQUE : un trigger AFTER INSERT sur `notifications` envoie, via pg_net, la
-- notification au backend Node (/api/v2/notifications/dispatch), qui récupère l'email
-- et le téléphone du destinataire (profiles) et envoie email (Resend) + SMS (Twilio).
-- → couvre toutes les sources d'insertion (backend, frontend direct, RPC) sans
--   double-envoi, et sans toucher chaque appelant.
--
-- 100 % best-effort : si le webhook échoue ou n'est pas configuré, l'insertion (et donc
-- la notification IN-APP) réussit quand même — une notification ne bloque jamais le métier.
--
-- ⚙️ CONFIGURATION REQUISE (Supabase → Vault / Project Settings → Vault, ajouter 2 secrets) :
--    • BACKEND_URL       = URL publique du backend Node (ex: https://api.224solution.net)
--    • INTERNAL_API_KEY  = même valeur que la variable d'env backend INTERNAL_API_KEY
--   Sans ces secrets, le trigger ne fait RIEN (notifications in-app seulement).
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public.dispatch_notification_channels()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_backend_url text;
  v_internal_key text;
BEGIN
  -- Secrets depuis Vault. Si Vault/secret absent → on sort proprement (in-app only).
  BEGIN
    SELECT decrypted_secret INTO v_backend_url  FROM vault.decrypted_secrets WHERE name = 'BACKEND_URL' LIMIT 1;
    SELECT decrypted_secret INTO v_internal_key FROM vault.decrypted_secrets WHERE name = 'INTERNAL_API_KEY' LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
  END;

  IF v_backend_url IS NULL OR v_internal_key IS NULL OR NEW.user_id IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url := rtrim(v_backend_url, '/') || '/api/v2/notifications/dispatch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-internal-api-key', v_internal_key
    ),
    body := jsonb_build_object(
      'notification_id', NEW.id,
      'user_id', NEW.user_id,
      'title', NEW.title,
      'message', NEW.message,
      'type', NEW.type
    )
  );
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Ne JAMAIS bloquer l'insertion de la notification.
  RAISE WARNING '[notif-dispatch] échec webhook: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_dispatch_notification_channels ON public.notifications;
CREATE TRIGGER trg_dispatch_notification_channels
  AFTER INSERT ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION public.dispatch_notification_channels();

SELECT 'Trigger multicanal posé sur notifications (email+SMS via backend). Configurer BACKEND_URL + INTERNAL_API_KEY dans Vault pour activer l''envoi.' AS status;
