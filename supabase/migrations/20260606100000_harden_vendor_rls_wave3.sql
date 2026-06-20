-- 🔒 DURCISSEMENT RLS — vague 3 : reviews, pos_settings, expense_alerts/budgets/categories.
-- Clôture les dernières policies permissives `true`. vendor_id de ces tables = vendors.id
-- (confirmé par les policies scoped existantes qui font `vendors.id = vendor_id`).

-- ── reviews : propriété CLIENT (customer_id = auth.uid()). Le vendeur ne doit pas éditer
--    les avis clients. On supprime la policy `true` ; restent `customers_own_reviews`
--    (le client gère son avis) + `Everyone can view verified reviews` (lecture publique).
DROP POLICY IF EXISTS "Customers can manage their reviews" ON public.reviews;

-- ── pos_settings : `vendors_and_agents_own_pos_settings` (is_vendor_or_agent) couvre déjà
--    tout. On supprime les 3 policies permissives `true`.
DROP POLICY IF EXISTS "Vendors can insert their own POS settings" ON public.pos_settings;
DROP POLICY IF EXISTS "Vendors can view their own POS settings" ON public.pos_settings;
DROP POLICY IF EXISTS "Vendors can update their own POS settings" ON public.pos_settings;

-- ── expense_* : la policy scoped existante est propriétaire-SEUL → l'agent (module Dépenses)
--    perdrait l'accès. On supprime la policy `true` et on ajoute un scope vendeur+agent+admin.
DROP POLICY IF EXISTS "Vendors can manage their alerts" ON public.expense_alerts;
DROP POLICY IF EXISTS "expense_alerts_vendor_agent_manage" ON public.expense_alerts;
CREATE POLICY "expense_alerts_vendor_agent_manage" ON public.expense_alerts
  FOR ALL TO authenticated
  USING (public.is_vendor_or_agent(vendor_id) OR public.is_admin())
  WITH CHECK (public.is_vendor_or_agent(vendor_id) OR public.is_admin());

DROP POLICY IF EXISTS "Vendors can manage their budgets" ON public.expense_budgets;
DROP POLICY IF EXISTS "expense_budgets_vendor_agent_manage" ON public.expense_budgets;
CREATE POLICY "expense_budgets_vendor_agent_manage" ON public.expense_budgets
  FOR ALL TO authenticated
  USING (public.is_vendor_or_agent(vendor_id) OR public.is_admin())
  WITH CHECK (public.is_vendor_or_agent(vendor_id) OR public.is_admin());

DROP POLICY IF EXISTS "Vendors can manage their categories" ON public.expense_categories;
DROP POLICY IF EXISTS "expense_categories_vendor_agent_manage" ON public.expense_categories;
CREATE POLICY "expense_categories_vendor_agent_manage" ON public.expense_categories
  FOR ALL TO authenticated
  USING (public.is_vendor_or_agent(vendor_id) OR public.is_admin())
  WITH CHECK (public.is_vendor_or_agent(vendor_id) OR public.is_admin());
