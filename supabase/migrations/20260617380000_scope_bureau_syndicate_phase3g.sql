-- ============================================================================
-- 🔒 ISOLATION — PALIER 3g : bureau / syndicat → PDG + backend (service_role).
--
-- ⚠️ Particularité : le bureau s'authentifie via un JWT signé custom (useBureauAuth,
-- stocké en sessionStorage), PAS une session Supabase → auth.uid() est VIDE pour
-- un utilisateur bureau. On NE PEUT donc PAS scoper ces tables par auth.uid().
-- Décision : verrouiller l'accès {authenticated} (ferme la fuite inter-bureaux pour
-- les comptes normaux : client/vendeur/etc. qui voyaient TOUS les travailleurs/
-- badges/alertes/plaintes de TOUS les bureaux) ; l'accès bureau passe par le BACKEND
-- /api/v2/bureau (verifyBureauJWT + service_role, qui BYPASS RLS) ; les dashboards
-- PDG gardent l'accès via is_admin_or_pdg.
--
-- syndicate_worker_permissions : déjà verrouillé backend-only (palier 2).
--
-- Idempotent. Conserve service_role.
-- ============================================================================

-- ── syndicate_workers : trou d'écriture (« postgres » = {authenticated} true) +
-- lecture ouverte → PDG/backend uniquement. ─────────────────────────────────
DROP POLICY IF EXISTS "Allow postgres role full access" ON public.syndicate_workers;
DROP POLICY IF EXISTS "Allow authenticated users to read syndicate workers" ON public.syndicate_workers;
CREATE POLICY "syndicate_workers_admin_all" ON public.syndicate_workers
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- ── syndicate_alerts : lecture ouverte → PDG/backend ─────────────────────────
DROP POLICY IF EXISTS "Public can view syndicate_alerts with valid bureau" ON public.syndicate_alerts;
CREATE POLICY "syndicate_alerts_admin_select" ON public.syndicate_alerts
  FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())));

-- ── worker_complaints : gestion/lecture/création ouvertes → PDG/backend ──────
DROP POLICY IF EXISTS "Bureaus can manage complaints" ON public.worker_complaints;
DROP POLICY IF EXISTS "Workers can view their complaints" ON public.worker_complaints;
DROP POLICY IF EXISTS "Workers can create complaints" ON public.worker_complaints;
CREATE POLICY "worker_complaints_admin_all" ON public.worker_complaints
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

-- ── syndicat_badges : gestion = PDG/backend ; LECTURE chauffeur conservée
-- (les chauffeurs ont une session Supabase : driver_id → drivers.user_id). ────
DROP POLICY IF EXISTS "Syndicat can manage badges" ON public.syndicat_badges;
DROP POLICY IF EXISTS "Drivers can view their badges" ON public.syndicat_badges;
CREATE POLICY "syndicat_badges_admin_all" ON public.syndicat_badges
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));
CREATE POLICY "syndicat_badges_driver_select" ON public.syndicat_badges
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_pdg((select auth.uid()))
    OR driver_id IN (SELECT id FROM public.drivers WHERE user_id = (select auth.uid()))
  );

-- ── transport_ticket_batches : PDG + créateur (si session Supabase) ; backend ─
DROP POLICY IF EXISTS "Admins can delete all ticket batches" ON public.transport_ticket_batches;
DROP POLICY IF EXISTS "Allow bureau ticket batch creation" ON public.transport_ticket_batches;
DROP POLICY IF EXISTS "Admins can view all ticket batches" ON public.transport_ticket_batches;
CREATE POLICY "transport_batches_admin_creator_select" ON public.transport_ticket_batches
  FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())) OR created_by = (select auth.uid()));
CREATE POLICY "transport_batches_admin_creator_write" ON public.transport_ticket_batches
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())) OR created_by = (select auth.uid()))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())) OR created_by = (select auth.uid()));

-- ── members : DELETE ouvert (« Admins can delete » = {authenticated} true) → admin ─
DROP POLICY IF EXISTS "Admins can delete members" ON public.members;
CREATE POLICY "members_admin_delete" ON public.members
  FOR DELETE TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())));

SELECT 'Palier 3g OK : syndicate_workers (trou écriture fermé)/syndicate_alerts/worker_complaints/syndicat_badges/transport_ticket_batches/members → PDG + backend service_role (accès bureau via /api/v2/bureau) ; badges = vue chauffeur conservée ; ticket batches = créateur conservé. LOT 3g TERMINÉ. Audit isolation : reste 3d-3 (dispatch taxi/véhicules/SOS).' AS status;
