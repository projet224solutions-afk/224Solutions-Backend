-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE — Contrôleur : code TOUJOURS visible (organisateur) + reset mot de passe
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — appliqué en prod via l'API Management.
-- Le login_code est un IDENTIFIANT (pas un secret — le secret est le mdp haché) : il reste lisible
-- par l'organisateur/prestataire via la policy ectrl_read existante. Si le contrôleur oublie son
-- mot de passe, l'organisateur le RÉINITIALISE (sessions existantes tuées par sécurité).

CREATE OR REPLACE FUNCTION public.reset_event_controller_password(p_controller_id uuid, p_new_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_c event_controllers%ROWTYPE; v_e events%ROWTYPE;
BEGIN
  SELECT * INTO v_c FROM event_controllers WHERE id = p_controller_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND'); END IF;
  SELECT * INTO v_e FROM events WHERE id = v_c.event_id;
  IF auth.uid() NOT IN (v_e.organizer_user_id, v_e.provider_user_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_ALLOWED');
  END IF;
  IF length(btrim(p_new_password)) < 4 THEN RETURN jsonb_build_object('success', false, 'error', 'CODE_TOO_SHORT'); END IF;
  UPDATE event_controllers
     SET code_hash = extensions.crypt(btrim(p_new_password), extensions.gen_salt('bf')), is_active = true
   WHERE id = p_controller_id;
  DELETE FROM controller_sessions WHERE controller_id = p_controller_id;  -- anciennes sessions tuées
  RETURN jsonb_build_object('success', true, 'login_code', v_c.login_code);
END; $$;

REVOKE ALL ON FUNCTION public.reset_event_controller_password(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reset_event_controller_password(uuid, text) TO authenticated, service_role;
