
-- =============================================
-- CORRECTION SÉCURITÉ: Restreindre les politiques aux utilisateurs authentifiés
-- =============================================

-- 1. Transactions - accès authentifié uniquement (colonnes correctes: sender_wallet_id, receiver_wallet_id)
DROP POLICY IF EXISTS "Users can view own transactions" ON public.wallet_transactions;
CREATE POLICY "Users can view own transactions" ON public.wallet_transactions
  FOR SELECT TO authenticated
  USING (
    sender_wallet_id IN (SELECT id FROM wallets WHERE user_id = auth.uid())
    OR receiver_wallet_id IN (SELECT id FROM wallets WHERE user_id = auth.uid())
  );

DROP POLICY IF EXISTS "Users can insert transactions" ON public.wallet_transactions;
CREATE POLICY "Users can insert transactions" ON public.wallet_transactions
  FOR INSERT TO authenticated
  WITH CHECK (sender_wallet_id IN (SELECT id FROM wallets WHERE user_id = auth.uid()));

-- 2. Advanced carts - authentifié uniquement
DROP POLICY IF EXISTS "Users manage their cart" ON public.advanced_carts;
CREATE POLICY "Users manage their cart" ON public.advanced_carts
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- 3. Agent wallets - authentifié uniquement
DROP POLICY IF EXISTS "agents_read_own_wallet" ON public.agent_wallets;
CREATE POLICY "agents_read_own_wallet" ON public.agent_wallets
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM agents_management am 
      WHERE am.id = agent_wallets.agent_id 
      AND am.user_id = auth.uid()
    )
  );

-- 4. Bureau wallets - authentifié uniquement  
DROP POLICY IF EXISTS "Bureau can view own wallet" ON public.bureau_wallets;
CREATE POLICY "Bureau can view own wallet" ON public.bureau_wallets
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM bureaus b 
      WHERE b.id = bureau_wallets.bureau_id
    )
  );

-- 5. Escrow transactions - authentifié uniquement
DROP POLICY IF EXISTS "Users can view own escrow" ON public.escrow_transactions;
CREATE POLICY "Users can view own escrow" ON public.escrow_transactions
  FOR SELECT TO authenticated
  USING (buyer_id = auth.uid() OR seller_id = auth.uid());

-- 6. Deliveries - authentifié uniquement
DROP POLICY IF EXISTS "Users can view relevant deliveries" ON public.deliveries;
CREATE POLICY "Users can view relevant deliveries" ON public.deliveries
  FOR SELECT TO authenticated
  USING (
    driver_id = auth.uid() 
    OR vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid())
    OR client_id = auth.uid()
  );

-- 7. Messages - authentifié uniquement (colonnes: sender_id, recipient_id)
DROP POLICY IF EXISTS "Users can view own messages" ON public.messages;
CREATE POLICY "Users can view own messages" ON public.messages
  FOR SELECT TO authenticated
  USING (sender_id = auth.uid() OR recipient_id = auth.uid());

-- 8. Conversations - authentifié uniquement
DROP POLICY IF EXISTS "Participants can view conversations" ON public.conversations;
CREATE POLICY "Participants can view conversations" ON public.conversations
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM conversation_participants cp 
      WHERE cp.conversation_id = conversations.id 
      AND cp.user_id = auth.uid()
    )
    OR creator_id = auth.uid()
  );

-- 9. Agent commissions - authentifié uniquement
DROP POLICY IF EXISTS "Agents can view own commission logs" ON public.agent_commissions_log;
CREATE POLICY "Agents can view own commission logs" ON public.agent_commissions_log
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM agents_management am 
      WHERE am.id = agent_commissions_log.agent_id 
      AND am.user_id = auth.uid()
    )
  );

-- 10. Agent permissions - authentifié uniquement
DROP POLICY IF EXISTS "Agent can view own permissions" ON public.agent_permissions;
CREATE POLICY "Agent can view own permissions" ON public.agent_permissions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM agents_management am 
      WHERE am.id = agent_permissions.agent_id 
      AND am.user_id = auth.uid()
    )
  );
