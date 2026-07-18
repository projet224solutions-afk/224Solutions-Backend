-- ============================================================
-- 💵 CONTRE-REMBOURSEMENT (COD) — LEDGER livreur → vendeur
-- À la remise d'une livraison COD, le livreur encaisse le montant de la
-- commande POUR LE COMPTE du vendeur : cette dette est TRACÉE ici, puis
-- SOLDÉE par un transfert wallet atomique idempotent (clé cod-settle:<id>)
-- via le moteur wallet existant. Écritures BACKEND UNIQUEMENT (service_role) ;
-- lecture RLS : le livreur voit SES dettes, le vendeur voit SES créances.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.delivery_cod_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id uuid NOT NULL UNIQUE REFERENCES public.deliveries(id) ON DELETE CASCADE,
  order_id uuid,
  vendor_id uuid,
  vendor_user_id uuid NOT NULL,
  driver_user_id uuid NOT NULL,
  amount_due numeric NOT NULL CHECK (amount_due > 0),
  currency text NOT NULL DEFAULT 'GNF',
  collected_at timestamptz NOT NULL DEFAULT now(),
  settled_at timestamptz,
  settle_transaction_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS delivery_cod_ledger_driver_open_idx
  ON public.delivery_cod_ledger (driver_user_id) WHERE settled_at IS NULL;
CREATE INDEX IF NOT EXISTS delivery_cod_ledger_vendor_open_idx
  ON public.delivery_cod_ledger (vendor_user_id) WHERE settled_at IS NULL;

ALTER TABLE public.delivery_cod_ledger ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cod_ledger_driver_select ON public.delivery_cod_ledger;
CREATE POLICY cod_ledger_driver_select ON public.delivery_cod_ledger
  FOR SELECT TO authenticated USING (driver_user_id = auth.uid());

DROP POLICY IF EXISTS cod_ledger_vendor_select ON public.delivery_cod_ledger;
CREATE POLICY cod_ledger_vendor_select ON public.delivery_cod_ledger
  FOR SELECT TO authenticated USING (vendor_user_id = auth.uid());

-- AUCUNE policy INSERT/UPDATE/DELETE : écritures réservées au backend (service_role).
