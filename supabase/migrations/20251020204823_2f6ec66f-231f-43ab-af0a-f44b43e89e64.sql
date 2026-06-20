-- Créer des policies pour permettre aux admins d'accéder à toutes les données financières

-- Policy pour les transactions - accès admin
CREATE POLICY "Admins can view all transactions"
ON public.wallet_transactions
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- Policy pour les wallets - accès admin
CREATE POLICY "Admins can view all wallets"
ON public.wallets
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- Fonction pour obtenir les statistiques financières (accessible aux admins)
CREATE OR REPLACE FUNCTION public.get_finance_stats()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result JSON;
  is_admin BOOLEAN;
BEGIN
  -- Vérifier si l'utilisateur est admin
  SELECT role = 'admin' INTO is_admin
  FROM profiles
  WHERE id = auth.uid();
  
  IF NOT is_admin THEN
    RAISE EXCEPTION 'Access denied - Admin only';
  END IF;
  
  -- Calculer les statistiques
  SELECT json_build_object(
    'total_revenue', COALESCE(SUM(CASE WHEN status = 'completed' THEN amount ELSE 0 END), 0),
    'total_commissions', COALESCE(SUM(CASE WHEN status = 'completed' THEN fee ELSE 0 END), 0),
    'pending_payments', COALESCE(SUM(CASE WHEN status = 'pending' THEN amount ELSE 0 END), 0),
    'active_wallets', (SELECT COUNT(*) FROM wallets),
    'total_transactions', COUNT(*),
    'completed_transactions', SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END),
    'pending_transactions', SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END)
  ) INTO result
  FROM wallet_transactions;
  
  RETURN result;
END;
$$;