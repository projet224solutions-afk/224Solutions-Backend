-- ============================================================================
-- VOL/HÔTEL — Phase 1 : PROPRIÉTÉ des offres par une AGENCE de voyage.
-- Les offres peuvent désormais appartenir à une agence (professional_services) qui
-- les gère elle-même (CRUD), au lieu d'INSERT SQL manuels. Offre plateforme/affiliation
-- historique = agency_service_id NULL (reste service_role only, lecture publique conservée).
-- Le CLIENT paiera le montant CONFIRMÉ serveur (Phase 2), jamais un prix du body.
-- ============================================================================

-- ── flight_offers : propriété agence + statut + champs CRUD (escales, bagages) ──
ALTER TABLE public.flight_offers
  ADD COLUMN IF NOT EXISTS agency_service_id uuid REFERENCES public.professional_services(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'expired')),
  ADD COLUMN IF NOT EXISTS stops int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS baggage_allowance text,
  ADD COLUMN IF NOT EXISTS image_url text;
CREATE INDEX IF NOT EXISTS idx_flight_offers_agency ON public.flight_offers(agency_service_id);

-- ── hotel_offers : propriété agence + statut + champs dénormalisés (nom/ville/étoiles) ──
-- (hotel_partners existe mais une agence doit pouvoir publier une offre AUTONOME sans
--  dépendre d'un partenaire plateforme → on dénormalise le minimum nécessaire.)
ALTER TABLE public.hotel_offers
  ADD COLUMN IF NOT EXISTS agency_service_id uuid REFERENCES public.professional_services(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'expired')),
  ADD COLUMN IF NOT EXISTS hotel_name text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS country text,
  ADD COLUMN IF NOT EXISTS star_rating int;
CREATE INDEX IF NOT EXISTS idx_hotel_offers_agency ON public.hotel_offers(agency_service_id);

-- ── RLS : lecture publique des actives CONSERVÉE (policies existantes). On ajoute :
--    • lecture par l'agence propriétaire (voit aussi ses offres paused/expired) ;
--    • écriture (INSERT/UPDATE/DELETE) réservée à l'agence propriétaire + admin.
--    Les offres plateforme (agency NULL) : check_service_owner(NULL)=false → service_role only. ──

DROP POLICY IF EXISTS flight_offers_owner_read ON public.flight_offers;
CREATE POLICY flight_offers_owner_read ON public.flight_offers
  FOR SELECT TO authenticated
  USING (agency_service_id IS NOT NULL AND (public.check_service_owner(agency_service_id) OR public.is_admin_or_pdg(auth.uid())));

DROP POLICY IF EXISTS flight_offers_owner_write ON public.flight_offers;
CREATE POLICY flight_offers_owner_write ON public.flight_offers
  FOR ALL TO authenticated
  USING (agency_service_id IS NOT NULL AND (public.check_service_owner(agency_service_id) OR public.is_admin_or_pdg(auth.uid())))
  WITH CHECK (agency_service_id IS NOT NULL AND (public.check_service_owner(agency_service_id) OR public.is_admin_or_pdg(auth.uid())));

DROP POLICY IF EXISTS hotel_offers_owner_read ON public.hotel_offers;
CREATE POLICY hotel_offers_owner_read ON public.hotel_offers
  FOR SELECT TO authenticated
  USING (agency_service_id IS NOT NULL AND (public.check_service_owner(agency_service_id) OR public.is_admin_or_pdg(auth.uid())));

DROP POLICY IF EXISTS hotel_offers_owner_write ON public.hotel_offers;
CREATE POLICY hotel_offers_owner_write ON public.hotel_offers
  FOR ALL TO authenticated
  USING (agency_service_id IS NOT NULL AND (public.check_service_owner(agency_service_id) OR public.is_admin_or_pdg(auth.uid())))
  WITH CHECK (agency_service_id IS NOT NULL AND (public.check_service_owner(agency_service_id) OR public.is_admin_or_pdg(auth.uid())));
