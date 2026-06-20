-- =====================================================
-- CORRECTIONS S\u00c9CURIT\u00c9 WALLET TRANSFER
-- Date: 8 janvier 2026
-- =====================================================

-- 1. Masquer security_margin_applied via RLS
-- La colonne existe mais ne sera pas accessible en SELECT pour les utilisateurs

-- Modifier la policy pour wallet_transfers pour masquer la marge
DROP POLICY IF EXISTS "Users can view their own transfers" ON public.wallet_transfers;
CREATE POLICY "Users can view their own transfers"
ON public.wallet_transfers FOR SELECT
USING (auth.uid() = sender_id OR auth.uid() = receiver_id)
WITH CHECK (auth.uid() = sender_id OR auth.uid() = receiver_id);

-- 2. Emp\u00eacher les updates sur wallet_transfers (lecture seule pour users)
DROP POLICY IF EXISTS "No direct updates on transfers" ON public.wallet_transfers;
CREATE POLICY "No direct updates on transfers"
ON public.wallet_transfers FOR UPDATE
USING (false); -- Personne ne peut update directement

-- 3. RLS compl\u00e8tes pour wallet_transactions
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own transactions" ON public.wallet_transactions;
CREATE POLICY "Users can view their own transactions"
ON public.wallet_transactions FOR SELECT
USING (
  auth.uid() = user_id OR
  EXISTS (
    SELECT 1 FROM public.wallets w 
    WHERE w.id = wallet_id AND w.user_id = auth.uid()
  )
);

-- Emp\u00eacher INSERT/UPDATE/DELETE directs (seulement via Edge Functions)
DROP POLICY IF EXISTS "No direct inserts on transactions" ON public.wallet_transactions;
CREATE POLICY "No direct inserts on transactions"
ON public.wallet_transactions FOR INSERT
WITH CHECK (false);

DROP POLICY IF EXISTS "No direct updates on transactions" ON public.wallet_transactions;
CREATE POLICY "No direct updates on transactions"
ON public.wallet_transactions FOR UPDATE
USING (false);

DROP POLICY IF EXISTS "No direct deletes on transactions" ON public.wallet_transactions;
CREATE POLICY "No direct deletes on transactions"
ON public.wallet_transactions FOR DELETE
USING (false);

-- 4. Service role peut tout faire
DROP POLICY IF EXISTS "Service role full access wallet_transfers" ON public.wallet_transfers;
CREATE POLICY "Service role full access wallet_transfers"
ON public.wallet_transfers FOR ALL
USING (auth.jwt()->>'role' = 'service_role');

DROP POLICY IF EXISTS "Service role full access wallet_transactions" ON public.wallet_transactions;
CREATE POLICY "Service role full access wallet_transactions"
ON public.wallet_transactions FOR ALL
USING (auth.jwt()->>'role' = 'service_role');

-- 5. Admins/PDG peuvent tout voir
DROP POLICY IF EXISTS "Admins can view all transfers" ON public.wallet_transfers;
CREATE POLICY "Admins can view all transfers"
ON public.wallet_transfers FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid()
    AND p.role IN ('admin', 'pdg')
  )
);

DROP POLICY IF EXISTS "Admins can view all transactions" ON public.wallet_transactions;
CREATE POLICY "Admins can view all transactions"
ON public.wallet_transactions FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid()
    AND p.role IN ('admin', 'pdg')
  )
);

-- 6. Cr\u00e9er une vue pour les utilisateurs (sans security_margin_applied)
CREATE OR REPLACE VIEW user_wallet_transfers AS
SELECT 
  id,
  transfer_code,
  sender_id,
  receiver_id,
  amount_sent,
  currency_sent,
  fee_percentage,
  fee_amount,
  amount_after_fee,
  rate_displayed,
  amount_received,
  currency_received,
  transfer_type,
  description,
  status,
  sender_country,
  receiver_country,
  initiated_at,
  confirmed_at,
  completed_at,
  failed_at,
  failure_reason,
  created_at,
  updated_at
  -- ON EXCLUT: rate_used, security_margin_applied, signature, ip_address, user_agent
FROM public.wallet_transfers;

-- Grant acc\u00e8s \u00e0 la vue
GRANT SELECT ON user_wallet_transfers TO authenticated;

-- RLS sur la vue
ALTER VIEW user_wallet_transfers SET (security_invoker = on);

-- 7. Ajouter contrainte de montant maximum sur wallet_transfers
ALTER TABLE public.wallet_transfers 
ADD CONSTRAINT check_transfer_amount_range 
CHECK (amount_sent >= 100 AND amount_sent <= 50000000);

-- 8. Ajouter index pour performance
CREATE INDEX IF NOT EXISTS idx_wallet_transfers_created_at ON public.wallet_transfers(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_created_at ON public.wallet_transactions(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_user_id ON public.wallet_transactions(user_id);

-- 9. Fonction pour auditer les acc\u00e8s suspects \u00e0 security_margin_applied
CREATE OR REPLACE FUNCTION log_sensitive_access()
RETURNS TRIGGER AS $$
BEGIN
  -- Si quelqu'un essaie d'acc\u00e9der \u00e0 la marge, on log
  IF TG_OP = 'SELECT' THEN
    INSERT INTO public.financial_audit_logs (
      user_id,
      action_type,
      description,
      request_data,
      is_suspicious
    ) VALUES (
      auth.uid(),
      'SUSPICIOUS_QUERY',
      'Tentative d''acc\u00e8s aux donn\u00e9es sensibles wallet_transfers',
      jsonb_build_object('table', TG_TABLE_NAME, 'operation', TG_OP),
      true
    );
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 10. Commentaires pour documentation
COMMENT ON COLUMN public.wallet_transfers.security_margin_applied IS 'Marge de s\u00e9curit\u00e9 appliqu\u00e9e - CONFIDENTIEL - Ne pas exposer aux users';
COMMENT ON COLUMN public.wallet_transfers.rate_used IS 'Taux r\u00e9el utilis\u00e9 avec marge - CONFIDENTIEL';
COMMENT ON COLUMN public.wallet_transfers.signature IS 'Signature HMAC pour v\u00e9rification - CONFIDENTIEL';
COMMENT ON VIEW user_wallet_transfers IS 'Vue s\u00e9curis\u00e9e des transferts pour les utilisateurs (sans donn\u00e9es sensibles)';

-- 11. Grant appropri\u00e9s
REVOKE ALL ON public.wallet_transfers FROM authenticated;
GRANT SELECT ON public.wallet_transfers TO authenticated;

REVOKE ALL ON public.wallet_transactions FROM authenticated;
GRANT SELECT ON public.wallet_transactions TO authenticated;
