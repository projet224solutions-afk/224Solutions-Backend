BEGIN;

-- RPC : journalise une action PDG dans audit_logs. Réservé aux rôles privilégiés.
-- before/after permettent de tracer la valeur avant et après modification.
CREATE OR REPLACE FUNCTION public.log_pdg_action(
  p_action      text,
  p_target_type text DEFAULT NULL,
  p_target_id   uuid DEFAULT NULL,
  p_before      jsonb DEFAULT NULL,
  p_after       jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_role text;
  v_id   uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHENTICATED');
  END IF;

  -- Rôles réels de l'enum user_role (pas de super_admin) ; 'agent' inclus (sous-PDG)
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('admin','pdg','ceo','agent') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHORIZED');
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, target_type, target_id, data_json, created_at)
  VALUES (
    v_uid,
    p_action,
    p_target_type,
    p_target_id,
    jsonb_build_object('before', p_before, 'after', p_after, 'role', v_role),
    now()
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'log_id', v_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.log_pdg_action(text, text, uuid, jsonb, jsonb) FROM anon;
GRANT  EXECUTE ON FUNCTION public.log_pdg_action(text, text, uuid, jsonb, jsonb) TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='log_pdg_action')
  THEN RAISE EXCEPTION 'RPC log_pdg_action absente'; END IF;
  RAISE NOTICE '✅ Migration pdg_audit_helper OK';
END; $$;

COMMIT;
