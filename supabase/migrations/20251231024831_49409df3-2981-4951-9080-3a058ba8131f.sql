-- ===========================================
-- SECURITY FIXES BATCH 4 FINAL - Fix Financial Tables  
-- ===========================================

-- wallets (has user_id)
DROP POLICY IF EXISTS "Users can view own wallet" ON public.wallets;
CREATE POLICY "Users can view own wallet" ON public.wallets
FOR SELECT TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Users can update own wallet" ON public.wallets;
CREATE POLICY "Users can update own wallet" ON public.wallets
FOR UPDATE TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Admins can view all wallets" ON public.wallets;
CREATE POLICY "Admins can view all wallets" ON public.wallets
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "PDG can view all wallets" ON public.wallets;
CREATE POLICY "PDG can view all wallets" ON public.wallets
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- wallet_transactions (uses wallet_id references)
DROP POLICY IF EXISTS "Users can view own transactions" ON public.wallet_transactions;
CREATE POLICY "Users can view own transactions" ON public.wallet_transactions
FOR SELECT TO authenticated
USING (
  sender_wallet_id IN (SELECT id FROM public.wallets WHERE user_id = auth.uid())
  OR receiver_wallet_id IN (SELECT id FROM public.wallets WHERE user_id = auth.uid())
);

DROP POLICY IF EXISTS "Admins can view all transactions" ON public.wallet_transactions;
CREATE POLICY "Admins can view all transactions" ON public.wallet_transactions
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

-- transactions (has user_id)
DROP POLICY IF EXISTS "Users can view own transactions" ON public.transactions;
CREATE POLICY "Users can view own transactions" ON public.transactions
FOR SELECT TO authenticated
USING (user_id = auth.uid());

-- financial_transactions (has user_id)
DROP POLICY IF EXISTS "Users can view their own transactions" ON public.financial_transactions;
CREATE POLICY "Users can view their own transactions" ON public.financial_transactions
FOR SELECT TO authenticated
USING (user_id = auth.uid());

-- financial_ledger (uses actor_id)
DROP POLICY IF EXISTS "PDG full access to ledger" ON public.financial_ledger;
CREATE POLICY "PDG full access to ledger" ON public.financial_ledger
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Users view own ledger" ON public.financial_ledger;
CREATE POLICY "Users view own ledger" ON public.financial_ledger
FOR SELECT TO authenticated
USING (actor_id = auth.uid());

-- financial_quarantine
DROP POLICY IF EXISTS "PDG full access to quarantine" ON public.financial_quarantine;
CREATE POLICY "PDG full access to quarantine" ON public.financial_quarantine
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- financial_rules
DROP POLICY IF EXISTS "PDG full access to rules" ON public.financial_rules;
CREATE POLICY "PDG full access to rules" ON public.financial_rules
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- pdg_financial tables
DROP POLICY IF EXISTS "PDG full access to alerts" ON public.pdg_financial_alerts;
CREATE POLICY "PDG full access to alerts" ON public.pdg_financial_alerts
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "PDG full access to control" ON public.pdg_financial_control;
CREATE POLICY "PDG full access to control" ON public.pdg_financial_control
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "PDG full access to stats" ON public.pdg_financial_stats;
CREATE POLICY "PDG full access to stats" ON public.pdg_financial_stats
FOR ALL TO authenticated
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- virtual_cards
DROP POLICY IF EXISTS "Users can manage their own virtual cards" ON public.virtual_cards;
CREATE POLICY "Users can manage their own virtual cards" ON public.virtual_cards
FOR ALL TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

-- card_transactions
DROP POLICY IF EXISTS "Users can view their own card transactions" ON public.card_transactions;
CREATE POLICY "Users can view their own card transactions" ON public.card_transactions
FOR SELECT TO authenticated
USING (user_id = auth.uid());

-- escrow_transactions
DROP POLICY IF EXISTS "Users can view own escrow" ON public.escrow_transactions;
CREATE POLICY "Users can view own escrow" ON public.escrow_transactions
FOR SELECT TO authenticated
USING (payer_id = auth.uid() OR receiver_id = auth.uid());

-- escrows
DROP POLICY IF EXISTS "Users can view escrows where they are buyer or seller" ON public.escrows;
CREATE POLICY "Users can view escrows where they are buyer or seller" ON public.escrows
FOR SELECT TO authenticated
USING (buyer_id = auth.uid() OR seller_id = auth.uid());

-- escrow_logs (uses performed_by)
DROP POLICY IF EXISTS "Admins can view all escrow logs" ON public.escrow_logs;
CREATE POLICY "Admins can view all escrow logs" ON public.escrow_logs
FOR SELECT TO authenticated
USING (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Users can view their escrow logs" ON public.escrow_logs;
CREATE POLICY "Users can view their escrow logs" ON public.escrow_logs
FOR SELECT TO authenticated
USING (performed_by = auth.uid());

-- p2p_transactions
DROP POLICY IF EXISTS "Users can view their own transactions" ON public.p2p_transactions;
CREATE POLICY "Users can view their own transactions" ON public.p2p_transactions
FOR SELECT TO authenticated
USING (sender_id = auth.uid() OR receiver_id = auth.uid());

DROP POLICY IF EXISTS "Users can update received transactions" ON public.p2p_transactions;
CREATE POLICY "Users can update received transactions" ON public.p2p_transactions
FOR UPDATE TO authenticated
USING (receiver_id = auth.uid());