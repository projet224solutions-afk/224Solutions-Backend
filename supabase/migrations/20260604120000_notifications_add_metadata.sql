-- =====================================================
-- FIX NOTIFICATIONS : colonne metadata manquante
-- Symptôme : le badge affiche un nombre mais la page /notifications est vide,
-- car les hooks faisaient .select(...,'metadata') sur une colonne inexistante
-- (erreur 400 -> liste vide). Certaines insertions backend (notifications de
-- commande) écrivaient aussi `metadata` et échouaient.
-- Front corrigé en select('*') ; ici on ajoute la colonne pour les écritures.
-- =====================================================

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;
