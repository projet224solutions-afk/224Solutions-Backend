-- ============================================================================
-- 🩹 DURCISSEMENT : apply_signup_role échouait silencieusement (cast text→enum)
-- ----------------------------------------------------------------------------
-- BUG (même classe que update_user_presence, trouvé à l'audit adverse 2026-07-09) :
-- profiles.role est un ENUM `user_role`, mais la fonction faisait
--   UPDATE profiles SET role = p_role  (p_role text)  → SANS cast
-- → ERROR 42804 « column "role" is of type user_role but expression is of type text ».
-- L'erreur était AVALÉE par le `EXCEPTION WHEN OTHERS THEN RETURN success:false` → la
-- correction de rôle au signup (client → vendeur/livreur/taxi/transitaire/prestataire,
-- ex. via OAuth) ÉCHOUAIT en silence : l'utilisateur restait bloqué en 'client'.
--
-- FIX : cast explicite p_role::user_role dans l'UPDATE. Toute la logique de sécurité est
-- conservée à l'identique (garde auth.uid(), liste blanche self-service client→X seulement,
-- journalisation audit_logs + system_alerts sur tentative refusée). Idempotent (CREATE OR REPLACE).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.apply_signup_role(p_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller       uuid := auth.uid();
  v_current      text;
  v_self_service text[] := ARRAY['client','vendeur','livreur','taxi','transitaire','prestataire'];
BEGIN
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'unauthenticated');
  END IF;
  SELECT role INTO v_current FROM public.profiles WHERE id = v_caller;
  IF v_current IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'no_profile');
  END IF;
  IF v_current = p_role THEN
    RETURN jsonb_build_object('success', true, 'already_applied', true, 'role', v_current);
  END IF;
  -- Liste blanche : seul un 'client' peut évoluer vers un rôle self-service (jamais admin/pdg/…).
  IF v_current <> 'client' OR NOT (p_role = ANY (v_self_service)) THEN
    INSERT INTO public.audit_logs (action, actor_id, target_id, target_type, data_json)
    VALUES ('role.correction_denied', v_caller, v_caller, 'profiles',
            jsonb_build_object('from', v_current, 'requested', p_role));
    INSERT INTO public.system_alerts (title, message, severity, module, status, created_by, metadata)
    VALUES ('Tentative de correction de rôle refusée',
            format('Profil %s : tentative %s → %s refusée', v_caller, v_current, p_role),
            'high', 'security', 'active', v_caller,
            jsonb_build_object('from', v_current, 'requested', p_role, 'kind', 'role_correction_denied'));
    RETURN jsonb_build_object('success', false, 'error', 'role_not_allowed');
  END IF;
  -- ⬇️ Cast explicite text → enum user_role (le fix : la colonne est un enum).
  UPDATE public.profiles SET role = p_role::user_role, updated_at = now() WHERE id = v_caller;
  RETURN jsonb_build_object('success', true, 'role', p_role);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;
