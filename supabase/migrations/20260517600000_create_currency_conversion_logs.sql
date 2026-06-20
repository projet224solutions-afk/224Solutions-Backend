-- ================================================================
-- TABLE currency_conversion_logs
-- Enregistre chaque tentative de conversion de devises lors des
-- achats marketplace, pour monitoring PDG en temps réel.
--
-- Alimentée par le backend (orders.routes.ts) après chaque appel
-- à buildOrderFinancialSummary — succès ET erreurs.
-- ================================================================

CREATE TABLE IF NOT EXISTS public.currency_conversion_logs (
  id                   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id             UUID         REFERENCES public.orders(id) ON DELETE SET NULL,
  buyer_user_id        UUID         REFERENCES auth.users(id) ON DELETE SET NULL,
  vendor_id            UUID         REFERENCES public.vendors(id) ON DELETE SET NULL,

  -- Devises
  from_currency        VARCHAR(3)   NOT NULL,
  to_currency          VARCHAR(3)   NOT NULL,
  is_cross_currency    BOOLEAN      NOT NULL DEFAULT false,

  -- Montants
  original_amount      DECIMAL(20,4),          -- total produit en devise vendeur
  converted_amount     DECIMAL(20,4),          -- total produit en devise acheteur
  commission_original  DECIMAL(20,4),          -- commission en devise vendeur
  commission_converted DECIMAL(20,4),          -- commission en devise acheteur
  wallet_debit_amount  DECIMAL(20,4),          -- montant final débité du wallet

  -- Taux
  exchange_rate        DECIMAL(20,8),
  exchange_rate_source TEXT,
  rate_fetched_at      TIMESTAMPTZ,

  -- Statut
  status               VARCHAR(20)  NOT NULL DEFAULT 'success'
                       CHECK (status IN ('success', 'error', 'skipped')),
  error_message        TEXT,

  -- Métadonnées
  metadata             JSONB,
  created_at           TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Index pour les requêtes PDG (last N conversions, filter by status/currency)
CREATE INDEX IF NOT EXISTS idx_ccl_created_at    ON public.currency_conversion_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ccl_status        ON public.currency_conversion_logs (status);
CREATE INDEX IF NOT EXISTS idx_ccl_buyer         ON public.currency_conversion_logs (buyer_user_id);
CREATE INDEX IF NOT EXISTS idx_ccl_from_to       ON public.currency_conversion_logs (from_currency, to_currency);
CREATE INDEX IF NOT EXISTS idx_ccl_order         ON public.currency_conversion_logs (order_id);

-- RLS : lecture réservée aux admins PDG ; écriture via service_role (backend)
ALTER TABLE public.currency_conversion_logs ENABLE ROW LEVEL SECURITY;

-- Supprimer la policy si elle existe déjà (idempotence)
DROP POLICY IF EXISTS "pdg_read_conversion_logs" ON public.currency_conversion_logs;

-- Les admins PDG peuvent lire les logs de conversion
CREATE POLICY "pdg_read_conversion_logs"
  ON public.currency_conversion_logs
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.role IN ('pdg', 'admin')
    )
  );

-- Le backend (service_role) peut insérer sans passer par RLS
-- (service_role bypasses RLS by default in Supabase)

-- Activer Supabase Realtime (idempotent)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND tablename = 'currency_conversion_logs'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.currency_conversion_logs;
  END IF;
END;
$$;

SELECT 'currency_conversion_logs créée avec succès.' AS status;
