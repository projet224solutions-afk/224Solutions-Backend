-- ═══════════════════════════════════════════════════════════════════════════════════════
-- VOYAGE PHASE 3 — Tracking des clics d'affiliation (vols / hôtels / produits voyage).
-- Jusqu'ici les redirections partenaires étaient « fire-and-forget » : aucun enregistrement,
-- aucune attribution possible. Cette table journalise chaque clic sortant.
-- Table BACKEND-ONLY : RLS activée SANS policy (ni lecture ni écriture côté client) —
-- écrite exclusivement par le backend (service_role) via POST /api/v2/travel/affiliate-clicks.
-- ═══════════════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.travel_affiliate_clicks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  offer_type   text NOT NULL CHECK (offer_type IN ('flight', 'hotel', 'digital')),
  offer_id     uuid,
  partner_name text,
  target_url   text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_travel_aff_clicks_offer   ON public.travel_affiliate_clicks(offer_type, offer_id);
CREATE INDEX IF NOT EXISTS idx_travel_aff_clicks_created ON public.travel_affiliate_clicks(created_at DESC);

ALTER TABLE public.travel_affiliate_clicks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.travel_affiliate_clicks FROM PUBLIC, anon, authenticated;
