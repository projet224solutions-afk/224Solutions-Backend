-- =====================================================
-- SÉCURISATION DE LA TABLE PAYMENT_LINKS
-- Correction de l'exposition publique des transactions
-- =====================================================

-- 1. Supprimer la politique dangereuse qui expose TOUT
DROP POLICY IF EXISTS "Anyone can view payment links by payment_id" ON public.payment_links;

-- 2. Créer une fonction sécurisée pour vérifier si un payment_link est accessible publiquement
-- Un payment_link est accessible uniquement s'il est:
-- - Non expiré (expires_at > now)
-- - En statut 'pending' (en attente de paiement)
CREATE OR REPLACE FUNCTION public.is_payment_link_publicly_accessible(p_payment_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 
    FROM public.payment_links
    WHERE payment_id = p_payment_id
    AND expires_at > now()
    AND status = 'pending'
  );
$$;

-- 3. Créer une nouvelle politique sécurisée pour l'accès public
-- Permet uniquement de voir les payment_links valides via leur payment_id
CREATE POLICY "Public access to valid payment links only"
ON public.payment_links
FOR SELECT
USING (
  -- Accès public uniquement pour les liens valides (non expirés, en attente)
  (
    expires_at > now() 
    AND status = 'pending'
    AND payment_id IS NOT NULL
  )
  OR
  -- OU l'utilisateur est le vendeur propriétaire
  (
    EXISTS (
      SELECT 1 FROM public.vendors
      WHERE vendors.id = payment_links.vendeur_id
      AND vendors.user_id = auth.uid()
    )
  )
  OR
  -- OU l'utilisateur est le client assigné
  (
    client_id = auth.uid()
  )
  OR
  -- OU l'utilisateur est un administrateur
  (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid()
      AND profiles.role = 'admin'
    )
  )
);

-- 4. Ajouter un commentaire explicatif
COMMENT ON POLICY "Public access to valid payment links only" ON public.payment_links IS 
'Permet l''accès public uniquement aux payment_links non expirés et en attente de paiement. Les vendeurs, clients et admins ont un accès complet à leurs liens respectifs.';

-- 5. Vérifier que les autres politiques restrictives existent toujours
-- (Ces politiques devraient déjà exister dans les migrations précédentes)

-- Note: Les politiques suivantes doivent déjà exister:
-- - "Vendors view own payment links" (vendors peuvent voir leurs liens)
-- - "Clients view their payment links" (clients peuvent voir leurs liens assignés)
-- - Ces politiques restent inchangées et continuent de fonctionner