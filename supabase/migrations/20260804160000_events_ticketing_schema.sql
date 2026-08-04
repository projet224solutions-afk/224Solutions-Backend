-- ═══════════════════════════════════════════════════════════════════════════════
-- BILLETTERIE ÉVÉNEMENTS (marque blanche) — SCHÉMA + RLS + commission PDG
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — appliqué en prod via l'API Management (même canal que le déploiement).
--
-- Modèle (validé Thierno) : le PRESTATAIRE crée l'événement + le compte organisateur + génère les tickets
-- en PRÉPAYANT la commission PDG (N × X GNF, débit wallet) → SEULEMENT après paiement, les tickets existent.
-- L'ORGANISATEUR suit les ventes, scanne les QR, RETIRE l'argent (portefeuille temporaire = retrait only).
-- Le CLIENT achète (wallet/agrégateur) et reçoit un QR unique. Cette migration = structure + garde-fous ;
-- les RPC atomiques (génération prépayée, achat, scan, retrait) sont dans 20260804160100.

-- ── Événements ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id uuid NOT NULL,                 -- prestataire créateur (service billetterie)
  organizer_user_id uuid,                          -- compte organisateur (créé ensuite par le prestataire)
  professional_service_id uuid,                    -- service billetterie du prestataire (lien marketplace)
  title text NOT NULL,
  description text,
  venue text,
  event_date timestamptz,
  cover_image text,
  promo_video_url text,                            -- vidéo marketing courte (promotion marketplace)
  promo_tagline text,
  is_promoted boolean NOT NULL DEFAULT false,      -- visible dans le marketplace (si status='active')
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','ended','cancelled','archived')),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ── Types de billets (VIP / Standard…) ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.event_ticket_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  name text NOT NULL,
  price numeric NOT NULL DEFAULT 0 CHECK (price >= 0),
  quantity_total integer NOT NULL DEFAULT 0 CHECK (quantity_total >= 0),
  quantity_sold integer NOT NULL DEFAULT 0 CHECK (quantity_sold >= 0),
  currency text NOT NULL DEFAULT 'GNF',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sold_le_total CHECK (quantity_sold <= quantity_total)
);

-- ── Billets individuels (QR unique = jeton aléatoire long, non devinable) ────
CREATE TABLE IF NOT EXISTS public.event_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  ticket_type_id uuid NOT NULL REFERENCES public.event_ticket_types(id) ON DELETE CASCADE,
  batch_id uuid,
  buyer_user_id uuid,
  buyer_phone text,
  qr_code text NOT NULL UNIQUE,                    -- jeton aléatoire (QR + lien privé /billet/:token)
  purchase_ref text UNIQUE,                        -- idempotence de l'ACHAT (rejeu → même billet, pas de double vente)
  status text NOT NULL DEFAULT 'valid' CHECK (status IN ('valid','used','refunded','void')),
  scanned_at timestamptz,
  scanned_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ── Portefeuille TEMPORAIRE organisateur (RETRAIT ONLY, jamais négatif) ──────
CREATE TABLE IF NOT EXISTS public.organizer_wallets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizer_user_id uuid NOT NULL,
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  balance numeric NOT NULL DEFAULT 0 CHECK (balance >= 0),
  currency text NOT NULL DEFAULT 'GNF',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id)
);

-- ── Lots de génération prépayée (trace : N × X payé AVANT génération) ────────
CREATE TABLE IF NOT EXISTS public.event_ticket_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  ticket_type_id uuid REFERENCES public.event_ticket_types(id) ON DELETE SET NULL,
  quantity integer NOT NULL CHECK (quantity > 0),
  commission_per_ticket numeric NOT NULL CHECK (commission_per_ticket >= 0),
  total_commission_paid numeric NOT NULL CHECK (total_commission_paid >= 0),
  payment_ref text UNIQUE,                         -- idempotence de la génération prépayée
  paid_at timestamptz NOT NULL DEFAULT now()
);

-- ── Retraits organisateur (ledger — retrait only, machine à états) ───────────
CREATE TABLE IF NOT EXISTS public.organizer_withdrawals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizer_wallet_id uuid NOT NULL REFERENCES public.organizer_wallets(id) ON DELETE CASCADE,
  organizer_user_id uuid NOT NULL,
  amount numeric NOT NULL CHECK (amount > 0),
  method text NOT NULL CHECK (method IN ('orange_money','card','bank_transfer')),
  destination text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','paid','failed')),
  idempotency_key text UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_events_status         ON public.events(status);
CREATE INDEX IF NOT EXISTS idx_events_provider       ON public.events(provider_user_id);
CREATE INDEX IF NOT EXISTS idx_events_organizer      ON public.events(organizer_user_id);
CREATE INDEX IF NOT EXISTS idx_ett_event             ON public.event_ticket_types(event_id);
CREATE INDEX IF NOT EXISTS idx_etk_event             ON public.event_tickets(event_id);
CREATE INDEX IF NOT EXISTS idx_etk_type              ON public.event_tickets(ticket_type_id);
CREATE INDEX IF NOT EXISTS idx_etk_buyer             ON public.event_tickets(buyer_user_id);
CREATE INDEX IF NOT EXISTS idx_ow_organizer          ON public.organizer_wallets(organizer_user_id);
CREATE INDEX IF NOT EXISTS idx_owd_wallet            ON public.organizer_withdrawals(organizer_wallet_id);

-- ── RLS ─────────────────────────────────────────────────────────────────────
-- Les mouvements passent par des RPC SECURITY DEFINER ; les policies ne servent qu'à la LECTURE.
ALTER TABLE public.events                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_ticket_types     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_tickets          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organizer_wallets      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_ticket_batches   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organizer_withdrawals  ENABLE ROW LEVEL SECURITY;

-- Événements : public voit les 'active' (vente) ; prestataire + organisateur voient les leurs.
DROP POLICY IF EXISTS events_read ON public.events;
CREATE POLICY events_read ON public.events FOR SELECT
  USING (status = 'active' OR provider_user_id = auth.uid() OR organizer_user_id = auth.uid());
-- Le prestataire gère SES événements (création/édition) ; les mouvements sensibles restent RPC-only.
DROP POLICY IF EXISTS events_provider_write ON public.events;
CREATE POLICY events_provider_write ON public.events FOR ALL
  USING (provider_user_id = auth.uid()) WITH CHECK (provider_user_id = auth.uid());

DROP POLICY IF EXISTS ett_read ON public.event_ticket_types;
CREATE POLICY ett_read ON public.event_ticket_types FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.events e WHERE e.id = event_id
    AND (e.status = 'active' OR e.provider_user_id = auth.uid() OR e.organizer_user_id = auth.uid())));
DROP POLICY IF EXISTS ett_provider_write ON public.event_ticket_types;
CREATE POLICY ett_provider_write ON public.event_ticket_types FOR ALL
  USING (EXISTS (SELECT 1 FROM public.events e WHERE e.id = event_id AND e.provider_user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.events e WHERE e.id = event_id AND e.provider_user_id = auth.uid()));

-- Billets : l'acheteur voit les siens ; prestataire + organisateur voient ceux de l'événement.
DROP POLICY IF EXISTS etk_read ON public.event_tickets;
CREATE POLICY etk_read ON public.event_tickets FOR SELECT
  USING (buyer_user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.events e WHERE e.id = event_id
      AND (e.provider_user_id = auth.uid() OR e.organizer_user_id = auth.uid())));

-- Portefeuille organisateur : l'organisateur lit le sien (aucune écriture directe — RPC only).
DROP POLICY IF EXISTS ow_read ON public.organizer_wallets;
CREATE POLICY ow_read ON public.organizer_wallets FOR SELECT
  USING (organizer_user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.events e WHERE e.id = event_id AND e.provider_user_id = auth.uid()));

DROP POLICY IF EXISTS batches_read ON public.event_ticket_batches;
CREATE POLICY batches_read ON public.event_ticket_batches FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.events e WHERE e.id = event_id
    AND (e.provider_user_id = auth.uid() OR e.organizer_user_id = auth.uid())));

DROP POLICY IF EXISTS owd_read ON public.organizer_withdrawals;
CREATE POLICY owd_read ON public.organizer_withdrawals FOR SELECT
  USING (organizer_user_id = auth.uid());

-- ── Commission PDG par ticket (configurable) ────────────────────────────────
INSERT INTO public.pdg_settings (setting_key, setting_value, description)
VALUES ('event_ticket_commission_gnf', '{"value": 500}'::jsonb, 'Commission PDG prépayée par ticket généré (GNF)')
ON CONFLICT (setting_key) DO NOTHING;

-- ── revenus_pdg : nouvelle source officielle 'event_ticket_commission' ──────
ALTER TABLE public.revenus_pdg DROP CONSTRAINT IF EXISTS revenus_pdg_source_type_check;
ALTER TABLE public.revenus_pdg ADD CONSTRAINT revenus_pdg_source_type_check
  CHECK (source_type = ANY (ARRAY['frais_transaction_wallet','frais_achat_commande','frais_abonnement',
    'abonnement_vendeur','abonnement_service','abonnement_chauffeur','frais_retrait','frais_paiement_lien',
    'event_ticket_commission','autre']));
