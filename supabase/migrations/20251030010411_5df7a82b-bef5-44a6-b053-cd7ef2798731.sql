-- Désactiver RLS sur id_counters car c'est une table système
-- utilisée uniquement par des fonctions SECURITY DEFINER
ALTER TABLE public.id_counters DISABLE ROW LEVEL SECURITY;

-- Supprimer les politiques existantes (elles ne sont plus nécessaires)
DROP POLICY IF EXISTS "Anyone can view id counters" ON public.id_counters;
DROP POLICY IF EXISTS "Service role can manage id counters" ON public.id_counters;