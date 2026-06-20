-- 🔒 DURCISSEMENT RLS — vague 2 : products, debts, contracts, disputes.
-- Suite de 20260605160000. Remplace/supprime les policies permissives `true` en
-- écriture, en gardant l'accès vendeur + agent (+ admin), et le client pour disputes.

-- ── products : supprimer les 3 policies ALL `true` redondantes. Les policies gardées
--    couvrent déjà l'écriture : `Vendors can manage own products` (is_vendor_or_agent,
--    WITH CHECK hérité du USING) + `Admins full access` (is_admin). Les SELECT publics
--    du marketplace (Everyone/authenticated_read/public_view) sont volontairement conservés.
DROP POLICY IF EXISTS "Admins can manage all products" ON public.products;
DROP POLICY IF EXISTS "Vendors can manage their own products" ON public.products;
DROP POLICY IF EXISTS "Vendors can manage their products" ON public.products;

-- ── debts : outil vendeur. Remplacer les policies permissives par un scope vendeur/agent/admin.
DROP POLICY IF EXISTS "Vendors can create debts" ON public.debts;
DROP POLICY IF EXISTS "Vendors can view their own debts" ON public.debts;
DROP POLICY IF EXISTS "Vendors can update their own debts" ON public.debts;
DROP POLICY IF EXISTS "debts_vendor_agent_manage" ON public.debts;
CREATE POLICY "debts_vendor_agent_manage" ON public.debts
  FOR ALL TO authenticated
  USING (public.is_vendor_or_agent(vendor_id) OR public.is_admin())
  WITH CHECK (public.is_vendor_or_agent(vendor_id) OR public.is_admin());

-- ── contracts : vendor_id = vendors.id (traité ainsi par les policies existantes).
--    Supprimer l'INSERT `true`, ajouter un scope vendeur/agent/admin.
DROP POLICY IF EXISTS "Vendors can create contracts" ON public.contracts;
DROP POLICY IF EXISTS "contracts_vendor_agent_manage" ON public.contracts;
CREATE POLICY "contracts_vendor_agent_manage" ON public.contracts
  FOR ALL TO authenticated
  USING (public.is_vendor_or_agent(vendor_id) OR public.is_admin())
  WITH CHECK (public.is_vendor_or_agent(vendor_id) OR public.is_admin());

-- ── disputes : MULTI-PARTIES (client_id + vendor_id). Remplacer les policies `true`
--    par un accès des parties : le client concerné OU le vendeur/agent OU un admin.
DROP POLICY IF EXISTS "Clients can create disputes" ON public.disputes;
DROP POLICY IF EXISTS "Users can view their own disputes" ON public.disputes;
DROP POLICY IF EXISTS "Parties can update their disputes" ON public.disputes;
DROP POLICY IF EXISTS "disputes_party_access" ON public.disputes;
CREATE POLICY "disputes_party_access" ON public.disputes
  FOR ALL TO authenticated
  USING (client_id = auth.uid() OR public.is_vendor_or_agent(vendor_id) OR public.is_admin())
  WITH CHECK (client_id = auth.uid() OR public.is_vendor_or_agent(vendor_id) OR public.is_admin());
