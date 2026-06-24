-- ============================================================================
-- BTP CONSTRUCTION — Upgrade professionnel (style Archipad)
-- Ajoute 4 nouvelles tables sans toucher aux tables existantes :
--   construction_lots         → Corps d'état / Lots par métier
--   construction_reserves     → Réserves / Punch list
--   construction_meetings     → Comptes-rendus de réunion OPC
--   construction_intervenants → Multi-intervenants (archi, BET, sous-trait.)
-- Rejouable (IF NOT EXISTS + DROP POLICY/TRIGGER IF EXISTS partout).
-- RLS calquée sur les tables construction_* existantes (check_service_owner).
-- ============================================================================

-- ── 1. CORPS D'ÉTAT / LOTS ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.construction_lots (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id      uuid NOT NULL REFERENCES public.construction_projects(id) ON DELETE CASCADE,
  name            text NOT NULL,
  trade_type      text NOT NULL DEFAULT 'autre' CHECK (trade_type IN (
                    'gros_oeuvre','terrassement','charpente_couverture',
                    'electricite','plomberie_sanitaire','menuiserie_bois',
                    'menuiserie_alu','carrelage_faience','peinture_revetement',
                    'vitrerie_miroiterie','facade_enduit','reseau_vrd',
                    'climatisation','ascenseur','serrurerie','autre'
                  )),
  company_name    text,
  company_contact text,
  company_phone   text,
  budget_amount   numeric(14,2) NOT NULL DEFAULT 0,
  spent_amount    numeric(14,2) NOT NULL DEFAULT 0,
  progress_percent integer NOT NULL DEFAULT 0 CHECK (progress_percent BETWEEN 0 AND 100),
  status          text NOT NULL DEFAULT 'not_started' CHECK (status IN (
                    'not_started','in_progress','completed','cancelled'
                  )),
  notes           text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_construction_lots_project
  ON public.construction_lots (project_id, trade_type);

-- ── 2. RÉSERVES / PUNCH LIST ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.construction_reserves (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id       uuid NOT NULL REFERENCES public.construction_projects(id) ON DELETE CASCADE,
  lot_id           uuid REFERENCES public.construction_lots(id) ON DELETE SET NULL,
  reserve_number   integer,
  title            text NOT NULL,
  description      text,
  location_note    text,
  photo_urls       text[] DEFAULT '{}',
  priority         text NOT NULL DEFAULT 'medium' CHECK (priority IN (
                     'critical','high','medium','low'
                   )),
  status           text NOT NULL DEFAULT 'open' CHECK (status IN (
                     'open','in_progress','resolved','closed'
                   )),
  assigned_to      text,
  due_date         date,
  resolved_at      timestamptz,
  resolution_note  text,
  resolution_photos text[] DEFAULT '{}',
  created_by       uuid REFERENCES auth.users(id),
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_construction_reserves_project
  ON public.construction_reserves (project_id, status, priority);
CREATE INDEX IF NOT EXISTS idx_construction_reserves_lot
  ON public.construction_reserves (lot_id);

-- Séquence automatique du numéro de réserve par projet
CREATE OR REPLACE FUNCTION public.set_reserve_number()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.reserve_number IS NULL THEN
    SELECT COALESCE(MAX(reserve_number), 0) + 1
    INTO NEW.reserve_number
    FROM public.construction_reserves
    WHERE project_id = NEW.project_id;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_reserve_number ON public.construction_reserves;
CREATE TRIGGER trg_reserve_number
  BEFORE INSERT ON public.construction_reserves
  FOR EACH ROW EXECUTE FUNCTION public.set_reserve_number();

-- ── 3. COMPTES-RENDUS DE RÉUNION OPC ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.construction_meetings (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id           uuid NOT NULL REFERENCES public.construction_projects(id) ON DELETE CASCADE,
  meeting_number       integer NOT NULL DEFAULT 1,
  meeting_date         date NOT NULL,
  location             text,
  weather              text,
  attendees            jsonb NOT NULL DEFAULT '[]',
  general_observations text,
  decisions            jsonb NOT NULL DEFAULT '[]',
  action_items         jsonb NOT NULL DEFAULT '[]',
  next_meeting_date    date,
  next_meeting_location text,
  validated_at         timestamptz,
  created_by           uuid REFERENCES auth.users(id),
  created_at           timestamptz DEFAULT now(),
  updated_at           timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_construction_meetings_project
  ON public.construction_meetings (project_id, meeting_date DESC);

-- Séquence automatique du numéro de réunion par projet
CREATE OR REPLACE FUNCTION public.set_meeting_number()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.meeting_number = 1 THEN
    SELECT COALESCE(MAX(meeting_number), 0) + 1
    INTO NEW.meeting_number
    FROM public.construction_meetings
    WHERE project_id = NEW.project_id;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_meeting_number ON public.construction_meetings;
CREATE TRIGGER trg_meeting_number
  BEFORE INSERT ON public.construction_meetings
  FOR EACH ROW EXECUTE FUNCTION public.set_meeting_number();

-- ── 4. INTERVENANTS / MULTI-STAKEHOLDERS ────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.construction_intervenants (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES public.construction_projects(id) ON DELETE CASCADE,
  name       text NOT NULL,
  role       text NOT NULL CHECK (role IN (
               'maitre_ouvrage','maitre_oeuvre','architecte',
               'bet_structure','bet_fluides','bet_electricite',
               'coordinateur_sps','bureau_controle',
               'entreprise_generale','sous_traitant',
               'geometre','notaire','autre'
             )),
  company    text,
  phone      text,
  email      text,
  lot_id     uuid REFERENCES public.construction_lots(id) ON DELETE SET NULL,
  notes      text,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_construction_intervenants_project
  ON public.construction_intervenants (project_id, role);

-- ── RLS — mêmes politiques que les tables construction_* existantes ──────────
ALTER TABLE public.construction_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.construction_reserves ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.construction_meetings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.construction_intervenants ENABLE ROW LEVEL SECURITY;

-- Lots : prestataire gère ; client lit
DROP POLICY IF EXISTS lots_owner ON public.construction_lots;
CREATE POLICY lots_owner ON public.construction_lots FOR ALL
  USING (public.check_service_owner(
    (SELECT professional_service_id FROM public.construction_projects WHERE id = project_id)
  ))
  WITH CHECK (public.check_service_owner(
    (SELECT professional_service_id FROM public.construction_projects WHERE id = project_id)
  ));
DROP POLICY IF EXISTS lots_client_read ON public.construction_lots;
CREATE POLICY lots_client_read ON public.construction_lots FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.construction_projects p
    WHERE p.id = project_id AND p.client_user_id = auth.uid()
  ));

-- Réserves : prestataire gère ; client lit
DROP POLICY IF EXISTS reserves_owner ON public.construction_reserves;
CREATE POLICY reserves_owner ON public.construction_reserves FOR ALL
  USING (public.check_service_owner(
    (SELECT professional_service_id FROM public.construction_projects WHERE id = project_id)
  ))
  WITH CHECK (public.check_service_owner(
    (SELECT professional_service_id FROM public.construction_projects WHERE id = project_id)
  ));
DROP POLICY IF EXISTS reserves_client_read ON public.construction_reserves;
CREATE POLICY reserves_client_read ON public.construction_reserves FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.construction_projects p
    WHERE p.id = project_id AND p.client_user_id = auth.uid()
  ));

-- Réunions : prestataire gère ; client lit
DROP POLICY IF EXISTS meetings_owner ON public.construction_meetings;
CREATE POLICY meetings_owner ON public.construction_meetings FOR ALL
  USING (public.check_service_owner(
    (SELECT professional_service_id FROM public.construction_projects WHERE id = project_id)
  ))
  WITH CHECK (public.check_service_owner(
    (SELECT professional_service_id FROM public.construction_projects WHERE id = project_id)
  ));
DROP POLICY IF EXISTS meetings_client_read ON public.construction_meetings;
CREATE POLICY meetings_client_read ON public.construction_meetings FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.construction_projects p
    WHERE p.id = project_id AND p.client_user_id = auth.uid()
  ));

-- Intervenants : prestataire gère ; client lit
DROP POLICY IF EXISTS intervenants_owner ON public.construction_intervenants;
CREATE POLICY intervenants_owner ON public.construction_intervenants FOR ALL
  USING (public.check_service_owner(
    (SELECT professional_service_id FROM public.construction_projects WHERE id = project_id)
  ))
  WITH CHECK (public.check_service_owner(
    (SELECT professional_service_id FROM public.construction_projects WHERE id = project_id)
  ));
DROP POLICY IF EXISTS intervenants_client_read ON public.construction_intervenants;
CREATE POLICY intervenants_client_read ON public.construction_intervenants FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.construction_projects p
    WHERE p.id = project_id AND p.client_user_id = auth.uid()
  ));
