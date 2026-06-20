-- Ajouter politique DELETE pour permettre aux bureaux de supprimer leurs lots de tickets
CREATE POLICY "Allow bureau ticket batch deletion"
ON transport_ticket_batches
FOR DELETE
TO public
USING (
  public.bureau_exists(bureau_id)
);

-- Politique admin pour supprimer tous les lots
CREATE POLICY "Admins can delete all ticket batches"
ON transport_ticket_batches
FOR DELETE
USING (
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = auth.uid() 
    AND profiles.role = 'admin'::user_role
  )
);