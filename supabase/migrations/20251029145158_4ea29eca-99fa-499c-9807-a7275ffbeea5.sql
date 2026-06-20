-- Correction des politiques RLS pour user_ids
-- Problème: Les politiques actuelles peuvent bloquer la lecture des custom_ids d'autres utilisateurs

-- Supprimer les politiques existantes
DROP POLICY IF EXISTS "Anyone can read user_ids" ON public.user_ids;
DROP POLICY IF EXISTS "Users can read their own user_id" ON public.user_ids;
DROP POLICY IF EXISTS "Users can view their own custom ID" ON public.user_ids;

-- Créer une politique simple et claire pour permettre à tous les utilisateurs authentifiés
-- de lire les user_ids (nécessaire pour les transferts)
CREATE POLICY "Authenticated users can read user_ids"
  ON public.user_ids
  FOR SELECT
  TO authenticated
  USING (true);

-- Permettre au service_role d'avoir un accès complet
-- (cette politique existe déjà mais on la recrée pour être sûr)
DROP POLICY IF EXISTS "service_role_all" ON public.user_ids;
CREATE POLICY "service_role_all"
  ON public.user_ids
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);