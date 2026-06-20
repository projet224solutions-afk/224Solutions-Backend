-- Ajouter politique pour que les admins puissent voir tous les profils vendeurs
CREATE POLICY "admins_can_view_all_profiles" ON public.profiles
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() AND p.role = 'admin'
  )
);

-- Ajouter politique pour permettre aux PDG dans pdg_management de voir les certifications
CREATE POLICY "PDG can read all certifications" ON public.vendor_certifications
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM pdg_management 
    WHERE pdg_management.user_id = auth.uid()
  )
);

-- Ajouter politique pour permettre aux PDG d'insérer des certifications
CREATE POLICY "PDG can insert certifications" ON public.vendor_certifications
FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM pdg_management 
    WHERE pdg_management.user_id = auth.uid()
  )
);

-- Ajouter politique pour permettre aux PDG de mettre à jour les certifications
CREATE POLICY "PDG can update certifications" ON public.vendor_certifications
FOR UPDATE
USING (
  EXISTS (
    SELECT 1 FROM pdg_management 
    WHERE pdg_management.user_id = auth.uid()
  )
);