-- ====================================================================
-- AJOUT DU RÔLE PDG À L'ENUM user_role
-- Date: 2026-02-01
-- ====================================================================

ALTER TYPE public.user_role ADD VALUE IF NOT EXISTS 'pdg';
