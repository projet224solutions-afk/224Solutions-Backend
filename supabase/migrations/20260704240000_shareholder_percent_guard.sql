-- ============================================================================
-- 🛡️ GARDE-FOU 100 % — la somme des parts actionnaires actives ne dépasse jamais 100 %
-- ----------------------------------------------------------------------------
-- VOLET 4B : chaque part ≤ 100 %, mais la SOMME des parts ACTIVES par (category,
-- action_scope, country) pouvait dépasser 100 % (ex. 3 × 50 % = 150 % distribués →
-- sur-versement du coffre). Enforcement EN BASE (trigger BEFORE) : un insert direct ne
-- peut pas contourner. La route (shareholders.routes.ts) mappe l'erreur en
-- SHAREHOLDER_PERCENT_OVERFLOW.
--
-- NB V5.1 : wallet_effective_cap exempte DÉJÀ le PDG (retourne NULL) → le coffre n'est
-- jamais flaggé par wallet_over_cap. Aucun changement requis.
--
-- Migration livrée — NON exécutée.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.check_shareholder_percent_sum()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sum numeric;
BEGIN
  -- Ne contrôler que si la ligne entrante est ACTIVE (une part inactive ne distribue rien).
  IF NEW.status <> 'active' THEN
    RETURN NEW;
  END IF;

  -- Somme des parts ACTIVES de même (category, action_scope, country) — country comparé
  -- avec IS NOT DISTINCT FROM (NULL = NULL) — en EXCLUANT la ligne mise à jour, puis en
  -- ajoutant la part entrante.
  SELECT COALESCE(sum(percentage), 0) INTO v_sum
  FROM public.shareholder_assignments
  WHERE status = 'active'
    AND category = NEW.category
    AND action_scope = NEW.action_scope
    AND country IS NOT DISTINCT FROM NEW.country
    AND id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);

  IF v_sum + COALESCE(NEW.percentage, 0) > 100 THEN
    RAISE EXCEPTION 'Somme des parts actionnaires (% %%) > 100 %% pour cette catégorie/portée',
      round(v_sum + COALESCE(NEW.percentage, 0), 2)
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shareholder_percent_sum ON public.shareholder_assignments;
CREATE TRIGGER trg_shareholder_percent_sum
  BEFORE INSERT OR UPDATE ON public.shareholder_assignments
  FOR EACH ROW EXECUTE FUNCTION public.check_shareholder_percent_sum();

SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_shareholder_percent_sum')
  THEN '✅ garde-fou somme des parts ≤ 100 % actif (BEFORE INSERT/UPDATE)' ELSE '❌ trigger absent' END AS status;
