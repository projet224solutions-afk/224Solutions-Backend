-- ============================================================================
-- ⛔ ANTI-DOUBLE-COMPTAGE DES REVENUS ACTIONNAIRE - 224SOLUTIONS
-- ============================================================================
-- PROBLÈME : calculate_shareholder_revenue compte les abonnements "actifs durant
-- la période" à PRIX COMPLET. La contrainte UNIQUE(assignment_id, period_start,
-- period_end) n'empêche que les périodes IDENTIQUES. Si le PDG calcule deux
-- périodes qui se CHEVAUCHENT (ex. mensuel sur un abonnement annuel), le même
-- abonnement est compté plusieurs fois → revenu actionnaire SURÉVALUÉ.
--
-- CORRECTION : un trigger interdit d'enregistrer un revenu dont la période
-- chevauche une période déjà enregistrée pour la même attribution. Le PDG est
-- ainsi forcé d'utiliser des périodes DISJOINTES → chaque abonnement compté une
-- seule fois. (On lève le code 23505 pour réutiliser la gestion DUPLICATE_REVENUE
-- déjà en place côté backend.)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.shareholder_revenues_check_overlap()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.shareholder_revenues r
    WHERE r.assignment_id = NEW.assignment_id
      AND r.id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
      -- Chevauchement de périodes (bornes incluses : un jour partagé = chevauchement)
      AND daterange(r.period_start, r.period_end, '[]')
          && daterange(NEW.period_start, NEW.period_end, '[]')
  ) THEN
    RAISE EXCEPTION
      'OVERLAPPING_REVENUE_PERIOD: cette période chevauche une période de revenu déjà enregistrée pour cet actionnaire (évite le double comptage). Utilisez des périodes disjointes.'
      USING ERRCODE = '23505';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shareholder_revenues_no_overlap ON public.shareholder_revenues;
CREATE TRIGGER trg_shareholder_revenues_no_overlap
  BEFORE INSERT OR UPDATE OF period_start, period_end, assignment_id
  ON public.shareholder_revenues
  FOR EACH ROW
  EXECUTE FUNCTION public.shareholder_revenues_check_overlap();
