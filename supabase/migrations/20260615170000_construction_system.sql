-- ============================================================================
-- CONSTRUCTION / BTP (PHASE 3) — projets + journal de chantier (verrou 24h) +
-- jalons de paiement ESCROW (signatures Procore).
-- ----------------------------------------------------------------------------
-- - construction_projects : portfolio du prestataire (client lié pour le suivi).
-- - construction_daily_logs : journal quotidien, modifiable 24h puis VERROUILLÉ (RLS).
-- - construction_milestones : jalons de paiement en escrow (financés par le client,
--   libérés vers le prestataire à la validation, via RPC atomique).
-- REVOKE FROM PUBLIC sur les RPC argent. Rejouable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.construction_projects (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  client_user_id          uuid REFERENCES auth.users(id),
  name                    text NOT NULL,
  client_name             text,
  description             text,
  location                text,
  budget                  numeric(14,2) NOT NULL DEFAULT 0,
  spent                   numeric(14,2) NOT NULL DEFAULT 0,
  progress_percent        integer NOT NULL DEFAULT 0,
  status                  text NOT NULL DEFAULT 'planning' CHECK (status IN ('planning','in_progress','late','completed','cancelled')),
  deadline                date,
  created_at              timestamptz DEFAULT now(),
  updated_at              timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_construction_projects_service ON public.construction_projects (professional_service_id, status);
CREATE INDEX IF NOT EXISTS idx_construction_projects_client ON public.construction_projects (client_user_id);

CREATE TABLE IF NOT EXISTS public.construction_daily_logs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES public.construction_projects(id) ON DELETE CASCADE,
  log_date      date NOT NULL DEFAULT current_date,
  weather       text,
  workers       jsonb NOT NULL DEFAULT '[]',   -- [{trade, count}]
  description   text,
  photos        text[] DEFAULT '{}',
  incidents     text,
  created_at    timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_construction_logs_project ON public.construction_daily_logs (project_id, log_date DESC);

CREATE TABLE IF NOT EXISTS public.construction_milestones (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES public.construction_projects(id) ON DELETE CASCADE,
  title         text NOT NULL,
  amount        numeric(14,2) NOT NULL DEFAULT 0,
  order_index   integer NOT NULL DEFAULT 0,
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','funded','released','cancelled')),
  funded_at     timestamptz,
  released_at   timestamptz,
  created_at    timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_construction_milestones_project ON public.construction_milestones (project_id, order_index);

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.construction_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.construction_daily_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.construction_milestones ENABLE ROW LEVEL SECURITY;

-- Projets : prestataire gère ; client voit le sien.
DROP POLICY IF EXISTS cproj_owner ON public.construction_projects;
CREATE POLICY cproj_owner ON public.construction_projects
  FOR ALL USING (public.check_service_owner(professional_service_id)) WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS cproj_client_read ON public.construction_projects;
CREATE POLICY cproj_client_read ON public.construction_projects
  FOR SELECT TO authenticated USING (client_user_id = auth.uid());

-- Journal : prestataire insère/voit ; UPDATE uniquement < 24h (VERROU juridique) ;
-- le client lit en lecture seule.
DROP POLICY IF EXISTS clog_owner_ins ON public.construction_daily_logs;
CREATE POLICY clog_owner_ins ON public.construction_daily_logs
  FOR INSERT TO authenticated WITH CHECK (public.check_service_owner((SELECT professional_service_id FROM public.construction_projects WHERE id = project_id)));
DROP POLICY IF EXISTS clog_owner_sel ON public.construction_daily_logs;
CREATE POLICY clog_owner_sel ON public.construction_daily_logs
  FOR SELECT TO authenticated USING (
    public.check_service_owner((SELECT professional_service_id FROM public.construction_projects WHERE id = project_id))
    OR EXISTS (SELECT 1 FROM public.construction_projects p WHERE p.id = project_id AND p.client_user_id = auth.uid())
  );
DROP POLICY IF EXISTS clog_owner_upd ON public.construction_daily_logs;
CREATE POLICY clog_owner_upd ON public.construction_daily_logs
  FOR UPDATE TO authenticated USING (
    public.check_service_owner((SELECT professional_service_id FROM public.construction_projects WHERE id = project_id))
    AND created_at > now() - interval '24 hours'
  );

-- Jalons : prestataire gère ; client voit ceux de son projet.
DROP POLICY IF EXISTS cmile_owner ON public.construction_milestones;
CREATE POLICY cmile_owner ON public.construction_milestones
  FOR ALL USING (public.check_service_owner((SELECT professional_service_id FROM public.construction_projects WHERE id = project_id)))
  WITH CHECK (public.check_service_owner((SELECT professional_service_id FROM public.construction_projects WHERE id = project_id)));
DROP POLICY IF EXISTS cmile_client_read ON public.construction_milestones;
CREATE POLICY cmile_client_read ON public.construction_milestones
  FOR SELECT TO authenticated USING (EXISTS (SELECT 1 FROM public.construction_projects p WHERE p.id = project_id AND p.client_user_id = auth.uid()));

-- ── RPC : le CLIENT finance un jalon (débit wallet → escrow « funded ») ──────
CREATE OR REPLACE FUNCTION public.fund_construction_milestone_atomic(p_milestone_id uuid, p_actor_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m public.construction_milestones%ROWTYPE; v_client uuid;
BEGIN
  SELECT * INTO m FROM public.construction_milestones WHERE id = p_milestone_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MILESTONE_NOT_FOUND'; END IF;
  SELECT client_user_id INTO v_client FROM public.construction_projects WHERE id = m.project_id;
  IF p_actor_user_id <> v_client THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;
  IF m.status <> 'pending' THEN RETURN jsonb_build_object('success', true, 'already', true, 'status', m.status); END IF;
  IF COALESCE(m.amount,0) <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;

  PERFORM public.wallet_debit_internal(p_actor_user_id, m.amount, 'Financement jalon BTP', 'btp-fund-' || m.id::text);
  UPDATE public.construction_milestones SET status = 'funded', funded_at = now() WHERE id = p_milestone_id;
  RETURN jsonb_build_object('success', true, 'status', 'funded');
END;
$$;

-- ── RPC : le CLIENT valide un jalon → libère l'escrow vers le prestataire ────
CREATE OR REPLACE FUNCTION public.release_construction_milestone_atomic(p_milestone_id uuid, p_actor_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m public.construction_milestones%ROWTYPE; v_client uuid; v_provider uuid; v_psid uuid; v_commission numeric; v_pdg uuid;
BEGIN
  SELECT * INTO m FROM public.construction_milestones WHERE id = p_milestone_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MILESTONE_NOT_FOUND'; END IF;
  SELECT client_user_id, professional_service_id INTO v_client, v_psid FROM public.construction_projects WHERE id = m.project_id;
  IF p_actor_user_id <> v_client THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;
  IF m.status = 'released' THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;
  IF m.status <> 'funded' THEN RAISE EXCEPTION 'NOT_FUNDED'; END IF;

  SELECT user_id INTO v_provider FROM public.professional_services WHERE id = v_psid;
  v_commission := round(m.amount * 0.05);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  PERFORM public.credit_user_wallet_safe(v_provider, m.amount - v_commission, 'GNF', 'btp_milestone_release', m.id::text);
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'btp_milestone_commission', m.id::text);
  END IF;
  UPDATE public.construction_milestones SET status = 'released', released_at = now() WHERE id = p_milestone_id;
  RETURN jsonb_build_object('success', true, 'released', m.amount - v_commission);
END;
$$;

-- ── Lecture publique via le LIEN partagé (le client ouvre /chantier/:id) ────
DROP POLICY IF EXISTS cproj_public_read ON public.construction_projects;
CREATE POLICY cproj_public_read ON public.construction_projects FOR SELECT USING (true);
DROP POLICY IF EXISTS cmile_public_read ON public.construction_milestones;
CREATE POLICY cmile_public_read ON public.construction_milestones FOR SELECT USING (true);
DROP POLICY IF EXISTS clog_public_read ON public.construction_daily_logs;
CREATE POLICY clog_public_read ON public.construction_daily_logs FOR SELECT USING (true);

-- ── RPC : le client RÉCLAME le chantier (se lie au projet via le lien) ──────
CREATE OR REPLACE FUNCTION public.claim_construction_project(p_project_id uuid, p_actor_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_client uuid;
BEGIN
  SELECT client_user_id INTO v_client FROM public.construction_projects WHERE id = p_project_id FOR UPDATE;
  IF v_client IS NOT NULL AND v_client <> p_actor_user_id THEN RAISE EXCEPTION 'ALREADY_CLAIMED'; END IF;
  UPDATE public.construction_projects SET client_user_id = p_actor_user_id WHERE id = p_project_id AND client_user_id IS NULL;
  RETURN jsonb_build_object('success', true);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.claim_construction_project(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.claim_construction_project(uuid, uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.fund_construction_milestone_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.release_construction_milestone_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fund_construction_milestone_atomic(uuid, uuid) TO service_role;
GRANT  EXECUTE ON FUNCTION public.release_construction_milestone_atomic(uuid, uuid) TO service_role;

SELECT 'BTP créé : projets + journal (verrou 24h RLS) + jalons escrow + RPC atomiques.' AS status;
