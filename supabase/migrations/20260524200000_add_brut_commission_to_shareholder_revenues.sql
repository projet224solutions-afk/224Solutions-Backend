-- ============================================================================
-- Ajouter colonnes brut + commission sur shareholder_revenues
-- pour afficher la décomposition dans la section revenus
-- ============================================================================

ALTER TABLE public.shareholder_revenues
  ADD COLUMN IF NOT EXISTS total_paid_revenue_brut  NUMERIC DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_agent_commission   NUMERIC DEFAULT 0;

COMMENT ON COLUMN public.shareholder_revenues.total_paid_revenue_brut IS
  'Montant brut encaissé avant déduction des commissions agents';

COMMENT ON COLUMN public.shareholder_revenues.total_agent_commission IS
  'Total des commissions agents déduites du montant brut';
