-- ============================================================================
-- FIX audit_role_change : NEW.role (enum user_role) compare a v_privileged (text[])
-- via = ANY() -> 42883 'operator does not exist: user_role = text' -> TOUT
-- changement de role (UPDATE profiles.role) echouait en 500 (promotion vendeur/
-- agent/admin bloquee). Meme famille que le cast enum M4/POS. Fix: NEW.role::text.
-- (Texte des alertes en ASCII pour eviter toute corruption d'encodage via l'API.)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.audit_role_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor      uuid := auth.uid();
  v_privileged text[] := ARRAY['admin','pdg','ceo','actionnaire','agent','vendor_agent','restaurant_agent','syndicat'];
BEGIN
  IF NEW.role IS NOT DISTINCT FROM OLD.role THEN RETURN NEW; END IF;
  INSERT INTO public.audit_logs (action, actor_id, target_id, target_type, data_json)
  VALUES ('role.changed', v_actor, NEW.id, 'profiles',
          jsonb_build_object('from', OLD.role, 'to', NEW.role, 'by_service_role', (v_actor IS NULL)));
  IF NEW.role::text = ANY (v_privileged) THEN
    INSERT INTO public.system_alerts (title, message, severity, module, status, created_by, metadata)
    VALUES ('Attribution role privilegie',
            format('Profil %s : %s -> %s', NEW.id, OLD.role, NEW.role),
            CASE WHEN NEW.role::text IN ('admin','pdg','ceo') THEN 'critical' ELSE 'high' END,
            'security', 'active', v_actor,
            jsonb_build_object('from', OLD.role, 'to', NEW.role, 'actor', v_actor,
                               'by_service_role', (v_actor IS NULL), 'kind', 'privileged_role_grant'));
  END IF;
  RETURN NEW;
END;
$function$;