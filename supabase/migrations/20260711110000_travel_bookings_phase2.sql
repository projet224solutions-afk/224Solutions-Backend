-- ════════════════════════════════════════════════════════════════════════════
-- Vol/Hôtel Phase 2 — Extension de `travel_bookings` pour le flux réservation + escrow.
--
-- Cycle de vie : pending (client a demandé) → price_confirmed (agence a confirmé le prix, ±30 %)
--   → paid (client a payé, fonds en SÉQUESTRE) → ticket_delivered (agence a déposé le billet)
--   → completed (client a confirmé OU auto-release J+14). Terminaux : cancelled / refunded.
--
-- L'argent réel passe par la RPC hold_travel_booking_escrow + release_escrow_to_seller (migration
-- suivante). Ici : colonnes de liaison + garanties d'intégrité + lecture agence.
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.travel_bookings
  ADD COLUMN IF NOT EXISTS agency_service_id     uuid REFERENCES public.professional_services(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS escrow_id             uuid,
  ADD COLUMN IF NOT EXISTS order_id              uuid,
  ADD COLUMN IF NOT EXISTS confirmed_amount      numeric(12,2),   -- prix confirmé par l'agence (ce que le client paie)
  ADD COLUMN IF NOT EXISTS price_confirmed_at    timestamptz,
  ADD COLUMN IF NOT EXISTS ticket_url            text,            -- billet unique (repli) ; document_urls = liste
  ADD COLUMN IF NOT EXISTS document_urls         jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS delivery_confirmed_at timestamptz;

-- CHECK status : couvre les anciennes valeurs (pending/confirmed/cancelled/completed) + les
-- nouvelles du flux escrow. On (re)crée la contrainte sans casser les lignes existantes.
DO $$
DECLARE v_con text;
BEGIN
  SELECT conname INTO v_con FROM pg_constraint
   WHERE conrelid = 'public.travel_bookings'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) ILIKE '%status%';
  IF v_con IS NOT NULL THEN EXECUTE format('ALTER TABLE public.travel_bookings DROP CONSTRAINT %I', v_con); END IF;
  ALTER TABLE public.travel_bookings
    ADD CONSTRAINT travel_bookings_status_check
    CHECK (status IN ('pending','confirmed','price_confirmed','paid','ticket_delivered','completed','cancelled','refunded'));
END $$;

-- CHECK booking_type (flight/hotel/package).
DO $$
DECLARE v_con text;
BEGIN
  SELECT conname INTO v_con FROM pg_constraint
   WHERE conrelid = 'public.travel_bookings'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) ILIKE '%booking_type%';
  IF v_con IS NULL THEN
    ALTER TABLE public.travel_bookings
      ADD CONSTRAINT travel_bookings_type_check CHECK (booking_type IN ('flight','hotel','package'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_travel_bookings_agency ON public.travel_bookings(agency_service_id);
CREATE INDEX IF NOT EXISTS idx_travel_bookings_escrow ON public.travel_bookings(escrow_id);

-- ⚠️ CORRECTIF SÉCURITÉ (revue argent) : Phase 1 avait créé des policies d'ÉCRITURE client
-- (INSERT/UPDATE WITH CHECK auth.uid()=user_id). Combinées au GRANT authenticated, elles
-- laissaient le client forger EN DIRECT (PostgREST) status='paid'/escrow_id/confirmed_amount,
-- contournant TOUT le circuit escrow (se faire livrer sans payer, sous-payer). On les SUPPRIME :
-- toutes les écritures passent EXCLUSIVEMENT par le backend (service_role, qui bypass RLS).
-- Le client ne conserve que la LECTURE de SES réservations (policy self existante).
DROP POLICY IF EXISTS "Users can create their own bookings" ON public.travel_bookings;
DROP POLICY IF EXISTS "Users can update their own bookings" ON public.travel_bookings;

-- ── RLS : lecture agence (le prestataire voit les réservations de SON service) ──
-- La lecture self existe déjà (auth.uid() = user_id). On ajoute la lecture agence + PDG.
DROP POLICY IF EXISTS "Agency can view its bookings" ON public.travel_bookings;
CREATE POLICY "Agency can view its bookings" ON public.travel_bookings
  FOR SELECT USING (
    agency_service_id IS NOT NULL
    AND (public.check_service_owner(agency_service_id) OR public.is_admin_or_pdg(auth.uid()))
  );
