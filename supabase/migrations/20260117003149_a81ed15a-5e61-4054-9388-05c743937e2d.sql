-- Ajouter une policy permettant aux propriétaires de voir leur boutique même inactive
-- Cela résout le problème où le vendeur ne peut pas accéder à sa propre page boutique

CREATE POLICY "Owners can always view their own vendor"
ON public.vendors
FOR SELECT
TO authenticated
USING (user_id = auth.uid());