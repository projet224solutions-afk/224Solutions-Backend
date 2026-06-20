-- Ajouter une politique RLS pour permettre aux admins de créer des bureaux
CREATE POLICY "Admins can create bureaus"
ON public.bureaus
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- Ajouter une politique RLS pour permettre aux admins de mettre à jour des bureaux
CREATE POLICY "Admins can update bureaus"
ON public.bureaus
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);

-- Ajouter une politique RLS pour permettre aux admins de voir tous les bureaux
CREATE POLICY "Admins can view all bureaus"
ON public.bureaus
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE profiles.id = auth.uid()
    AND profiles.role = 'admin'
  )
);