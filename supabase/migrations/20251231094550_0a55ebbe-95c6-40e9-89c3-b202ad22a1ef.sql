-- Batch 4h (v4): Tables vérifiées

-- revenus_pdg (user_id existe)
DROP POLICY IF EXISTS "Admins can view all revenus_pdg" ON public.revenus_pdg;
CREATE POLICY "PDG can view their revenues" ON public.revenus_pdg
  FOR ALL TO authenticated
  USING (user_id = auth.uid());

-- sales (vendor_id existe)
DROP POLICY IF EXISTS "Vendors can view their own sales" ON public.sales;
DROP POLICY IF EXISTS "Vendors can update their own sales" ON public.sales;
CREATE POLICY "Vendors can manage their sales" ON public.sales
  FOR ALL TO authenticated
  USING (vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()))
  WITH CHECK (vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()));

-- subscriptions (user_id existe)
DROP POLICY IF EXISTS "Users can view their own subscriptions" ON public.subscriptions;
DROP POLICY IF EXISTS "Admins can view all subscriptions" ON public.subscriptions;
DROP POLICY IF EXISTS "Admins can manage all subscriptions" ON public.subscriptions;
DROP POLICY IF EXISTS "Service role full access to subscriptions" ON public.subscriptions;
CREATE POLICY "Users can manage their subscriptions" ON public.subscriptions
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- transactions (user_id existe)
DROP POLICY IF EXISTS "Users can view their own transactions" ON public.transactions;
DROP POLICY IF EXISTS "Users can view own transactions" ON public.transactions;
CREATE POLICY "Users can view their transactions" ON public.transactions
  FOR ALL TO authenticated
  USING (user_id = auth.uid());

-- wallets (user_id existe)
DROP POLICY IF EXISTS "Users can view own wallet" ON public.wallets;
DROP POLICY IF EXISTS "Users can update own wallet" ON public.wallets;
DROP POLICY IF EXISTS "Users can view own wallet only" ON public.wallets;
DROP POLICY IF EXISTS "Admins can view all wallets" ON public.wallets;
DROP POLICY IF EXISTS "Admins full access to wallets" ON public.wallets;
DROP POLICY IF EXISTS "PDG can view all wallets" ON public.wallets;
DROP POLICY IF EXISTS "PDG can manage all wallets" ON public.wallets;
DROP POLICY IF EXISTS "Service role can manage all wallets" ON public.wallets;
CREATE POLICY "Users can manage their wallets" ON public.wallets
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- wallet_transactions (via wallet_id -> wallets.user_id)
DROP POLICY IF EXISTS "Users can view their own transactions" ON public.wallet_transactions;
DROP POLICY IF EXISTS "Users can view own transactions" ON public.wallet_transactions;
DROP POLICY IF EXISTS "Admins can view all transactions" ON public.wallet_transactions;
DROP POLICY IF EXISTS "Users can update their transactions" ON public.wallet_transactions;
CREATE POLICY "Users can view their wallet transactions" ON public.wallet_transactions
  FOR ALL TO authenticated
  USING (
    sender_wallet_id IN (SELECT id FROM public.wallets WHERE user_id = auth.uid()) OR
    receiver_wallet_id IN (SELECT id FROM public.wallets WHERE user_id = auth.uid())
  );

-- vendors (user_id existe)
DROP POLICY IF EXISTS "Vendors can manage their own profile" ON public.vendors;
DROP POLICY IF EXISTS "Admins can manage all vendors" ON public.vendors;
DROP POLICY IF EXISTS "Everyone can view active vendors" ON public.vendors;
CREATE POLICY "Vendors can manage their profile" ON public.vendors
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Everyone can view active vendors" ON public.vendors
  FOR SELECT TO authenticated
  USING (is_active = true);

-- virtual_cards (user_id existe)
DROP POLICY IF EXISTS "Users can manage their own virtual cards" ON public.virtual_cards;
DROP POLICY IF EXISTS "Users can view own cards" ON public.virtual_cards;
CREATE POLICY "Users can manage their virtual cards" ON public.virtual_cards
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- wishlists (user_id existe)
DROP POLICY IF EXISTS "Users manage wishlist" ON public.wishlists;
CREATE POLICY "Users can manage their wishlist" ON public.wishlists
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());