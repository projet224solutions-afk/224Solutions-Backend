-- ============================================================================
-- 🕐 GESTION DU PERSONNEL prestataire — POINTAGE (06/08/2026)
-- Pointage horodaté à l'HEURE SERVEUR (now() — jamais l'heure du téléphone),
-- token-scopé (un agent ne pointe QUE pour lui), anti-double (transitions
-- valides), preuve QR du centre optionnelle (secret révocable), horaires prévus
-- par agent (v1 : un horaire + jours cochés), corrections patron TOUJOURS
-- tracées au journal append-only. Retards/absences calculés sur l'heure serveur.
-- ============================================================================

-- Horaires prévus (v1 simple, portés par l'agent).
ALTER TABLE public.provider_agents
  ADD COLUMN IF NOT EXISTS schedule_days int[] DEFAULT '{1,2,3,4,5,6}', -- 1=lundi … 7=dimanche
  ADD COLUMN IF NOT EXISTS schedule_start time,
  ADD COLUMN IF NOT EXISTS schedule_end time;

-- Réglages pointage du centre.
CREATE TABLE IF NOT EXISTS public.provider_time_settings (
  provider_user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  require_qr boolean NOT NULL DEFAULT false,
  qr_secret text,
  late_tolerance_min int NOT NULL DEFAULT 10 CHECK (late_tolerance_min BETWEEN 0 AND 120),
  breaks_enabled boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.provider_time_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pts_owner_all ON public.provider_time_settings;
CREATE POLICY pts_owner_all ON public.provider_time_settings
  FOR ALL TO authenticated
  USING (provider_user_id = auth.uid()) WITH CHECK (provider_user_id = auth.uid());

-- Pointages (IMMUABLES — une correction = nouvelle ligne tracée, jamais un écrasement).
CREATE TABLE IF NOT EXISTS public.provider_time_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  agent_id uuid NOT NULL REFERENCES public.provider_agents(id) ON DELETE CASCADE,
  entry_type text NOT NULL CHECK (entry_type IN ('arrivee', 'depart', 'pause_debut', 'pause_fin')),
  at timestamptz NOT NULL DEFAULT now(), -- HEURE SERVEUR (défaut) ; correction patron = valeur fournie + trace
  method text NOT NULL DEFAULT 'simple' CHECK (method IN ('simple', 'qr', 'correction')),
  invalidated boolean NOT NULL DEFAULT false,
  correction_note text CHECK (char_length(correction_note) <= 300),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pte_agent_day ON public.provider_time_entries (agent_id, at DESC);
CREATE INDEX IF NOT EXISTS idx_pte_owner_day ON public.provider_time_entries (provider_user_id, at DESC);
ALTER TABLE public.provider_time_entries ENABLE ROW LEVEL SECURITY;
-- Patron : lecture seule directe (les écritures passent par les RPC tracées).
DROP POLICY IF EXISTS pte_owner_select ON public.provider_time_entries;
CREATE POLICY pte_owner_select ON public.provider_time_entries
  FOR SELECT TO authenticated USING (provider_user_id = auth.uid());

-- Requalification d'une absence (congé/maladie/autorisé) — tracée.
CREATE TABLE IF NOT EXISTS public.provider_absence_marks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  agent_id uuid NOT NULL REFERENCES public.provider_agents(id) ON DELETE CASCADE,
  day date NOT NULL,
  status text NOT NULL CHECK (status IN ('conge', 'maladie', 'autorise', 'absent')),
  note text CHECK (char_length(note) <= 300),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agent_id, day)
);
ALTER TABLE public.provider_absence_marks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pam_owner_all ON public.provider_absence_marks;
CREATE POLICY pam_owner_all ON public.provider_absence_marks
  FOR ALL TO authenticated
  USING (provider_user_id = auth.uid()) WITH CHECK (provider_user_id = auth.uid());

-- ── QR du centre : générer/révoquer (patron) ──
CREATE OR REPLACE FUNCTION public.regenerate_center_qr()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_secret text := upper(substr(md5(gen_random_uuid()::text), 1, 10));
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  INSERT INTO public.provider_time_settings (provider_user_id, qr_secret)
  VALUES (auth.uid(), v_secret)
  ON CONFLICT (provider_user_id) DO UPDATE SET qr_secret = v_secret, updated_at = now();
  RETURN v_secret;
END;
$$;
REVOKE ALL ON FUNCTION public.regenerate_center_qr() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.regenerate_center_qr() TO authenticated;

-- ── POINTAGE agent (token-scopé, heure SERVEUR, anti-double, QR si exigé) ──
CREATE OR REPLACE FUNCTION public.agent_clock(p_token text, p_type text, p_qr_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_agent public.provider_agents%ROWTYPE;
  v_settings public.provider_time_settings%ROWTYPE;
  v_last text;
  v_id uuid;
  v_at timestamptz;
BEGIN
  v_agent := public.provider_agent_from_token(p_token); -- session valide = SOI-MÊME uniquement
  IF p_type NOT IN ('arrivee', 'depart', 'pause_debut', 'pause_fin') THEN
    RAISE EXCEPTION 'INVALID_TYPE';
  END IF;
  SELECT * INTO v_settings FROM public.provider_time_settings WHERE provider_user_id = v_agent.provider_user_id;
  -- Preuve de présence : le QR du CENTRE est exigé → scanner (ou saisir) le code.
  IF coalesce(v_settings.require_qr, false) THEN
    IF v_settings.qr_secret IS NULL OR upper(trim(coalesce(p_qr_code, ''))) <> v_settings.qr_secret THEN
      RAISE EXCEPTION 'QR_REQUIRED';
    END IF;
  END IF;
  -- Anti-double : transitions valides depuis le DERNIER pointage du jour (heure serveur).
  SELECT entry_type INTO v_last FROM public.provider_time_entries
  WHERE agent_id = v_agent.id AND invalidated = false AND at >= date_trunc('day', now())
  ORDER BY at DESC LIMIT 1;
  IF p_type = 'arrivee' AND v_last IN ('arrivee', 'pause_debut', 'pause_fin') THEN RAISE EXCEPTION 'ALREADY_IN'; END IF;
  IF p_type = 'depart' AND (v_last IS NULL OR v_last = 'depart') THEN RAISE EXCEPTION 'NOT_IN'; END IF;
  IF p_type = 'pause_debut' AND (NOT coalesce(v_settings.breaks_enabled, false) OR v_last NOT IN ('arrivee', 'pause_fin')) THEN RAISE EXCEPTION 'INVALID_TRANSITION'; END IF;
  IF p_type = 'pause_fin' AND v_last <> 'pause_debut' THEN RAISE EXCEPTION 'INVALID_TRANSITION'; END IF;

  INSERT INTO public.provider_time_entries (provider_user_id, agent_id, entry_type, method)
  VALUES (v_agent.provider_user_id, v_agent.id, p_type,
          CASE WHEN coalesce(v_settings.require_qr, false) THEN 'qr' ELSE 'simple' END)
  RETURNING id, at INTO v_id, v_at;
  PERFORM public.log_agent_activity(v_agent.provider_user_id, v_agent.id, v_agent.name,
    'pointage_' || p_type, jsonb_build_object('at', v_at));
  RETURN jsonb_build_object('id', v_id, 'at', v_at, 'type', p_type);
END;
$$;
REVOKE ALL ON FUNCTION public.agent_clock(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.agent_clock(text, text, text) TO anon, authenticated;

-- L'agent voit SES pointages (aujourd'hui + période) — jamais ceux des autres.
CREATE OR REPLACE FUNCTION public.agent_my_time(p_token text, p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_agent public.provider_agents%ROWTYPE; v_out jsonb;
BEGIN
  v_agent := public.provider_agent_from_token(p_token);
  SELECT coalesce(jsonb_agg(jsonb_build_object('type', e.entry_type, 'at', e.at, 'invalidated', e.invalidated) ORDER BY e.at), '[]'::jsonb)
  INTO v_out
  FROM public.provider_time_entries e
  WHERE e.agent_id = v_agent.id AND e.invalidated = false
    AND e.at >= coalesce(p_from, current_date)::timestamptz
    AND e.at < (coalesce(p_to, current_date) + 1)::timestamptz;
  RETURN jsonb_build_object('agent_name', v_agent.name,
    'schedule_start', v_agent.schedule_start, 'schedule_end', v_agent.schedule_end,
    'entries', v_out);
END;
$$;
REVOKE ALL ON FUNCTION public.agent_my_time(text, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.agent_my_time(text, date, date) TO anon, authenticated;

-- ── Corrections PATRON — TOUJOURS tracées (jamais d'écrasement silencieux) ──
-- p_action 'add' : pointage manuel (oubli) ; 'invalidate' : pointage erroné neutralisé.
CREATE OR REPLACE FUNCTION public.owner_adjust_time_entry(
  p_action text, p_agent_id uuid, p_entry_id uuid DEFAULT NULL,
  p_type text DEFAULT NULL, p_at timestamptz DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_owner uuid := auth.uid();
  v_agent public.provider_agents%ROWTYPE;
  v_old public.provider_time_entries%ROWTYPE;
  v_id uuid;
BEGIN
  SELECT * INTO v_agent FROM public.provider_agents WHERE id = p_agent_id AND provider_user_id = v_owner;
  IF NOT FOUND THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_action = 'add' THEN
    IF p_type NOT IN ('arrivee', 'depart', 'pause_debut', 'pause_fin') OR p_at IS NULL THEN
      RAISE EXCEPTION 'INVALID_CORRECTION';
    END IF;
    INSERT INTO public.provider_time_entries (provider_user_id, agent_id, entry_type, at, method, correction_note)
    VALUES (v_owner, p_agent_id, p_type, p_at, 'correction', p_note)
    RETURNING id INTO v_id;
    PERFORM public.log_agent_activity(v_owner, p_agent_id, v_agent.name, 'pointage_corrige',
      jsonb_build_object('action', 'ajout', 'type', p_type, 'at', p_at, 'note', p_note));
    RETURN v_id;
  ELSIF p_action = 'invalidate' THEN
    SELECT * INTO v_old FROM public.provider_time_entries
    WHERE id = p_entry_id AND provider_user_id = v_owner;
    IF NOT FOUND THEN RAISE EXCEPTION 'ENTRY_NOT_FOUND'; END IF;
    UPDATE public.provider_time_entries SET invalidated = true, correction_note = p_note WHERE id = p_entry_id;
    PERFORM public.log_agent_activity(v_owner, p_agent_id, v_agent.name, 'pointage_corrige',
      jsonb_build_object('action', 'invalidation', 'ancien_type', v_old.entry_type, 'ancien_at', v_old.at, 'note', p_note));
    RETURN p_entry_id;
  END IF;
  RAISE EXCEPTION 'INVALID_ACTION';
END;
$$;
REVOKE ALL ON FUNCTION public.owner_adjust_time_entry(text, uuid, uuid, text, timestamptz, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.owner_adjust_time_entry(text, uuid, uuid, text, timestamptz, text) TO authenticated;
