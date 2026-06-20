-- ============================================================================
-- 🔒 DURCISSEMENT : verrouillage RÉEL des dépenses liées à un achat (is_locked).
--
-- Les dépenses créées par `validate_stock_purchase` (achats fournisseurs) sont
-- `is_locked = true` et NE doivent PAS être modifiées/supprimées manuellement (sinon
-- désynchronisation achat ↔ dette ↔ dépense). Les anciennes policies « Prevent … »
-- étaient PERMISSIVES → annulées par la policy permissive « Vendors can manage their
-- own expenses » (FOR ALL) qui s'OU-additionne → la protection ne s'appliquait pas.
--
-- FIX : policies RESTRICTIVE (elles s'AND-combinent avec les permissives → réellement
-- bloquantes). Résultat : un verrou ne peut être modifié/supprimé que par le backend
-- (service_role, qui bypass la RLS) — jamais depuis le frontend.
-- ============================================================================

-- On remplace les anciennes policies permissives (inefficaces) par des RESTRICTIVE.
DROP POLICY IF EXISTS "Prevent update on locked expenses" ON public.vendor_expenses;
DROP POLICY IF EXISTS "Prevent delete on locked expenses" ON public.vendor_expenses;

CREATE POLICY "no_update_locked_expenses" ON public.vendor_expenses
  AS RESTRICTIVE FOR UPDATE TO authenticated
  USING (is_locked = false);

CREATE POLICY "no_delete_locked_expenses" ON public.vendor_expenses
  AS RESTRICTIVE FOR DELETE TO authenticated
  USING (is_locked = false);

SELECT 'Dépenses verrouillées (achats) : modification/suppression bloquées côté client (RLS restrictive).' AS status;
