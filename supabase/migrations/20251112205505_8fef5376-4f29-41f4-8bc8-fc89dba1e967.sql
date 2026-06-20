-- Ajouter une politique RLS pour permettre aux vendeurs de supprimer leurs propres payment links

-- Vérifier si la politique existe déjà et la supprimer si c'est le cas
DROP POLICY IF EXISTS "Vendors can delete their own payment links" ON public.payment_links;

-- Créer la politique pour permettre aux vendeurs de supprimer leurs propres liens
CREATE POLICY "Vendors can delete their own payment links"
ON public.payment_links
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.vendors
    WHERE vendors.id = payment_links.vendeur_id
    AND vendors.user_id = auth.uid()
  )
);