BEGIN;

-- ════════════════════════════════════════════════════════════
-- 1. Table d'archive FROIDE (mêmes colonnes que audit_logs)
-- ════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.audit_logs_archive (
  LIKE public.audit_logs INCLUDING DEFAULTS,
  archived_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  archived_by UUID
);

ALTER TABLE public.audit_logs_archive ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "audit_archive_read_admin" ON public.audit_logs_archive;
CREATE POLICY "audit_archive_read_admin" ON public.audit_logs_archive
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.profiles
                 WHERE id = auth.uid()
                   AND role IN ('admin','pdg','super_admin','ceo')));

-- ════════════════════════════════════════════════════════════
-- 2. RPC : archive_old_audit_logs — DÉPLACE (jamais supprime) + auto-audit
-- ════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.archive_old_audit_logs(
  p_days_old   integer,
  p_mfa_token  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_role   text;
  v_cutoff timestamptz;
  v_count  integer;
BEGIN
  -- Garde 1 : rôle privilégié
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('admin','pdg','super_admin','ceo') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHORIZED');
  END IF;

  -- Garde 2 : preuve MFA fournie
  IF p_mfa_token IS NULL OR length(p_mfa_token) < 6 THEN
    RETURN jsonb_build_object('success', false, 'error', 'MFA_REQUIRED');
  END IF;

  -- Garde 3 : rétention minimale 90 jours
  IF p_days_old < 90 THEN
    RETURN jsonb_build_object('success', false, 'error', 'MIN_RETENTION_90_DAYS');
  END IF;

  v_cutoff := now() - (p_days_old || ' days')::interval;

  -- Déplacement atomique : retirer de la table chaude → insérer dans l'archive
  WITH moved AS (
    DELETE FROM public.audit_logs
    WHERE created_at < v_cutoff
    RETURNING *
  )
  INSERT INTO public.audit_logs_archive
  SELECT moved.*, now() AS archived_at, v_uid AS archived_by
  FROM moved;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- ✅ AUTO-AUDIT : l'archivage est lui-même journalisé
  INSERT INTO public.audit_logs (action, data_json, created_at)
  VALUES (
    'audit_logs_archived',
    jsonb_build_object(
      'archived_by', v_uid,
      'days_old',    p_days_old,
      'cutoff',      v_cutoff,
      'rows_moved',  v_count
    ),
    now()
  );

  RETURN jsonb_build_object('success', true, 'archived', v_count, 'cutoff', v_cutoff);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.archive_old_audit_logs(integer, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.archive_old_audit_logs(integer, text) TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='archive_old_audit_logs')
  THEN RAISE EXCEPTION 'RPC archive_old_audit_logs absente'; END IF;
  IF to_regclass('public.audit_logs_archive') IS NULL
  THEN RAISE EXCEPTION 'Table audit_logs_archive absente'; END IF;
  RAISE NOTICE '✅ Migration audit_logs_archive OK';
END; $$;

COMMIT;
