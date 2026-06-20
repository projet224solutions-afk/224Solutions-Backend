-- ============================================================================
-- ÉDUCATION / FORMATION (PHASE 3) — cours + curriculum + sessions live + inscription
-- payante atomique + certificat vérifiable par QR (signatures Udemy / Coursera).
-- ----------------------------------------------------------------------------
-- - courses            : catalogue du formateur (publiable, certificat activable).
-- - course_lessons     : curriculum ordonné (vidéo/texte/pdf), aperçu public ou payant.
-- - course_live_sessions : visios planifiées (URL réservée aux inscrits).
-- - course_enrollments : inscription PAYANTE (débit élève → net formateur + commission
--   PDG, atomique & idempotent) + progression + certificat (code QR vérifiable).
-- RPC argent REVOKE FROM PUBLIC. Vérification de certificat exposée (anon) mais
-- ne renvoyant que des champs publics. Rejouable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.courses (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  title                   text NOT NULL,
  category                text,
  level                   text NOT NULL DEFAULT 'debutant' CHECK (level IN ('debutant','intermediaire','avance')),
  format                  text NOT NULL DEFAULT 'en_ligne' CHECK (format IN ('presentiel','en_ligne','hybride')),
  description             text,
  cover_image            text,
  instructor_name         text,
  duration_label          text,
  price                   numeric(12,2) NOT NULL DEFAULT 0,
  max_students            integer NOT NULL DEFAULT 0,         -- 0 = illimité
  certificate_enabled     boolean NOT NULL DEFAULT true,
  rating                  numeric(3,2) NOT NULL DEFAULT 0,
  status                  text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','archived')),
  start_date              date,
  created_at              timestamptz DEFAULT now(),
  updated_at              timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_courses_service ON public.courses (professional_service_id, status);

CREATE TABLE IF NOT EXISTS public.course_lessons (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id     uuid NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
  title         text NOT NULL,
  position      integer NOT NULL DEFAULT 0,
  content_type  text NOT NULL DEFAULT 'video' CHECK (content_type IN ('video','text','pdf','live')),
  content_url   text,
  content_text  text,
  duration_minutes integer NOT NULL DEFAULT 0,
  is_preview    boolean NOT NULL DEFAULT false,
  created_at    timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_course_lessons_course ON public.course_lessons (course_id, position);

CREATE TABLE IF NOT EXISTS public.course_live_sessions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id     uuid NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
  title         text NOT NULL,
  scheduled_at  timestamptz NOT NULL,
  meeting_url   text,
  status        text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','live','ended','cancelled')),
  created_at    timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_course_live_course ON public.course_live_sessions (course_id, scheduled_at);

CREATE TABLE IF NOT EXISTS public.course_enrollments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id       uuid NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
  student_user_id uuid REFERENCES auth.users(id),
  student_name    text,
  student_phone   text,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed','cancelled')),
  progress_percent integer NOT NULL DEFAULT 0,
  amount_paid     numeric(12,2) NOT NULL DEFAULT 0,
  certificate_code text UNIQUE,
  certificate_issued_at timestamptz,
  created_at      timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_course_enroll_course ON public.course_enrollments (course_id, status);
CREATE INDEX IF NOT EXISTS idx_course_enroll_student ON public.course_enrollments (student_user_id);
-- Une seule inscription active par (cours, élève)
CREATE UNIQUE INDEX IF NOT EXISTS uq_course_enroll_active
  ON public.course_enrollments (course_id, student_user_id)
  WHERE status <> 'cancelled';

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.courses              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_lessons       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_live_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_enrollments   ENABLE ROW LEVEL SECURITY;

-- Cours : formateur gère ; lecture publique des cours actifs.
DROP POLICY IF EXISTS courses_owner ON public.courses;
CREATE POLICY courses_owner ON public.courses
  FOR ALL USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS courses_public_read ON public.courses;
CREATE POLICY courses_public_read ON public.courses FOR SELECT USING (status = 'active');

-- Leçons : formateur gère ; lecture = aperçu public OU élève inscrit OU propriétaire.
DROP POLICY IF EXISTS lessons_owner ON public.course_lessons;
CREATE POLICY lessons_owner ON public.course_lessons
  FOR ALL USING (public.check_service_owner((SELECT professional_service_id FROM public.courses WHERE id = course_id)))
  WITH CHECK (public.check_service_owner((SELECT professional_service_id FROM public.courses WHERE id = course_id)));
DROP POLICY IF EXISTS lessons_read ON public.course_lessons;
CREATE POLICY lessons_read ON public.course_lessons FOR SELECT USING (
  is_preview = true
  OR EXISTS (SELECT 1 FROM public.course_enrollments e WHERE e.course_id = course_lessons.course_id AND e.student_user_id = auth.uid() AND e.status <> 'cancelled')
);

-- Sessions live : formateur gère ; URL réservée propriétaire + inscrits.
DROP POLICY IF EXISTS live_owner ON public.course_live_sessions;
CREATE POLICY live_owner ON public.course_live_sessions
  FOR ALL USING (public.check_service_owner((SELECT professional_service_id FROM public.courses WHERE id = course_id)))
  WITH CHECK (public.check_service_owner((SELECT professional_service_id FROM public.courses WHERE id = course_id)));
DROP POLICY IF EXISTS live_read ON public.course_live_sessions;
CREATE POLICY live_read ON public.course_live_sessions FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.course_enrollments e WHERE e.course_id = course_live_sessions.course_id AND e.student_user_id = auth.uid() AND e.status <> 'cancelled')
  OR public.check_service_owner((SELECT professional_service_id FROM public.courses WHERE id = course_id))
);

-- Inscriptions : l'élève voit les siennes ; le formateur voit celles de ses cours.
-- (écriture uniquement via RPC service_role)
DROP POLICY IF EXISTS enroll_student_read ON public.course_enrollments;
CREATE POLICY enroll_student_read ON public.course_enrollments
  FOR SELECT TO authenticated USING (student_user_id = auth.uid());
DROP POLICY IF EXISTS enroll_owner_read ON public.course_enrollments;
CREATE POLICY enroll_owner_read ON public.course_enrollments
  FOR SELECT TO authenticated USING (public.check_service_owner((SELECT professional_service_id FROM public.courses WHERE id = course_id)));

-- ── RPC : inscription PAYANTE atomique (débit élève → net formateur + commission) ──
CREATE OR REPLACE FUNCTION public.enroll_course_atomic(p_actor_user_id uuid, p_course_id uuid, p_student_name text DEFAULT NULL, p_student_phone text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.courses%ROWTYPE; v_existing uuid; v_count int; v_instructor uuid; v_rate numeric; v_commission numeric; v_pdg uuid; v_enroll uuid;
BEGIN
  SELECT * INTO c FROM public.courses WHERE id = p_course_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'COURSE_NOT_FOUND'; END IF;
  IF c.status <> 'active' THEN RAISE EXCEPTION 'COURSE_NOT_ACTIVE'; END IF;

  -- Idempotence : inscription déjà active
  SELECT id INTO v_existing FROM public.course_enrollments
  WHERE course_id = p_course_id AND student_user_id = p_actor_user_id AND status <> 'cancelled';
  IF v_existing IS NOT NULL THEN RETURN jsonb_build_object('success', true, 'already', true, 'enrollment_id', v_existing); END IF;

  -- Places disponibles
  IF c.max_students > 0 THEN
    SELECT count(*) INTO v_count FROM public.course_enrollments WHERE course_id = p_course_id AND status <> 'cancelled';
    IF v_count >= c.max_students THEN RAISE EXCEPTION 'COURSE_FULL'; END IF;
  END IF;

  SELECT user_id INTO v_instructor FROM public.professional_services WHERE id = c.professional_service_id;

  -- Paiement (gratuit = pas de mouvement)
  IF COALESCE(c.price,0) > 0 THEN
    PERFORM public.wallet_debit_internal(p_actor_user_id, c.price, 'Inscription formation', 'edu-enroll-' || p_course_id::text || '-' || p_actor_user_id::text);
    v_rate := public.resolve_service_commission_rate(v_instructor, 'education', 12.0);
    v_commission := round(c.price * v_rate / 100.0);
    SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
    IF v_instructor IS NOT NULL THEN
      PERFORM public.credit_user_wallet_safe(v_instructor, c.price - v_commission, 'GNF', 'course_enrollment', p_course_id::text);
    END IF;
    IF v_pdg IS NOT NULL AND v_commission > 0 THEN
      PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'course_commission', p_course_id::text);
    END IF;
  END IF;

  INSERT INTO public.course_enrollments (course_id, student_user_id, student_name, student_phone, amount_paid)
  VALUES (p_course_id, p_actor_user_id, p_student_name, p_student_phone, COALESCE(c.price,0))
  RETURNING id INTO v_enroll;

  RETURN jsonb_build_object('success', true, 'enrollment_id', v_enroll);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.enroll_course_atomic(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.enroll_course_atomic(uuid, uuid, text, text) TO service_role;

-- ── RPC : le formateur met à jour la progression d'un élève ──────────────────
CREATE OR REPLACE FUNCTION public.set_enrollment_progress_atomic(p_actor_user_id uuid, p_enrollment_id uuid, p_percent integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_psid uuid; v_owner uuid;
BEGIN
  SELECT c.professional_service_id INTO v_psid
  FROM public.course_enrollments e JOIN public.courses c ON c.id = e.course_id WHERE e.id = p_enrollment_id;
  IF v_psid IS NULL THEN RAISE EXCEPTION 'ENROLLMENT_NOT_FOUND'; END IF;
  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = v_psid;
  IF v_owner <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_OWNER'; END IF;
  UPDATE public.course_enrollments SET progress_percent = least(greatest(p_percent,0),100) WHERE id = p_enrollment_id;
  RETURN jsonb_build_object('success', true);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.set_enrollment_progress_atomic(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.set_enrollment_progress_atomic(uuid, uuid, integer) TO service_role;

-- ── RPC : le formateur délivre le certificat (code QR vérifiable) ────────────
CREATE OR REPLACE FUNCTION public.issue_course_certificate_atomic(p_actor_user_id uuid, p_enrollment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE e public.course_enrollments%ROWTYPE; c public.courses%ROWTYPE; v_owner uuid; v_code text;
BEGIN
  SELECT * INTO e FROM public.course_enrollments WHERE id = p_enrollment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ENROLLMENT_NOT_FOUND'; END IF;
  SELECT * INTO c FROM public.courses WHERE id = e.course_id;
  IF NOT c.certificate_enabled THEN RAISE EXCEPTION 'CERTIFICATE_DISABLED'; END IF;
  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = c.professional_service_id;
  IF v_owner <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_OWNER'; END IF;

  IF e.certificate_code IS NOT NULL THEN RETURN jsonb_build_object('success', true, 'already', true, 'code', e.certificate_code); END IF;
  v_code := 'CERT-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
  UPDATE public.course_enrollments
    SET certificate_code = v_code, certificate_issued_at = now(), status = 'completed', progress_percent = 100
    WHERE id = p_enrollment_id;
  RETURN jsonb_build_object('success', true, 'code', v_code);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.issue_course_certificate_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.issue_course_certificate_atomic(uuid, uuid) TO service_role;

-- ── RPC : vérification PUBLIQUE d'un certificat (anon) — champs publics seulement ──
CREATE OR REPLACE FUNCTION public.verify_certificate(p_code text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE r record;
BEGIN
  SELECT e.student_name, e.certificate_issued_at, c.title AS course_title, c.level,
         ps.business_name AS institution
  INTO r
  FROM public.course_enrollments e
  JOIN public.courses c ON c.id = e.course_id
  JOIN public.professional_services ps ON ps.id = c.professional_service_id
  WHERE e.certificate_code = p_code;
  IF NOT FOUND THEN RETURN jsonb_build_object('valid', false); END IF;
  RETURN jsonb_build_object('valid', true, 'student_name', r.student_name, 'course_title', r.course_title,
    'level', r.level, 'institution', r.institution, 'issued_at', r.certificate_issued_at);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.verify_certificate(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.verify_certificate(text) TO anon, authenticated, service_role;

SELECT 'Éducation créé : cours + curriculum + sessions live + inscription atomique + certificat QR.' AS status;
