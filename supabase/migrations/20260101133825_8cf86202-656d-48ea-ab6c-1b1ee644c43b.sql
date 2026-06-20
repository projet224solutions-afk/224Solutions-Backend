-- Ajouter une politique pour permettre au PDG de voir tous les profils
CREATE POLICY "pdg_select_all_profiles" 
ON public.profiles 
FOR SELECT 
USING (
  EXISTS (
    SELECT 1 FROM pdg_management 
    WHERE user_id = auth.uid()
  )
);

-- Ajouter une politique pour permettre au PDG de voir toutes les transactions
CREATE POLICY "pdg_select_all_enhanced_transactions" 
ON public.enhanced_transactions 
FOR SELECT 
USING (
  EXISTS (
    SELECT 1 FROM pdg_management 
    WHERE user_id = auth.uid()
  )
);