-- =====================================================
-- MIGRATION: Suppression complète de CinetPay
-- Date: 2026-01-13
-- Description: Supprimer toutes les tables et références CinetPay
-- =====================================================

-- 1. Supprimer les politiques RLS de la table cinetpay_payments (si elle existe encore)
DROP POLICY IF EXISTS "Users can view own cinetpay payments" ON public.cinetpay_payments;
DROP POLICY IF EXISTS "Users can insert own cinetpay payments" ON public.cinetpay_payments;
DROP POLICY IF EXISTS "Users can update own cinetpay payments" ON public.cinetpay_payments;
DROP POLICY IF EXISTS "Admins can view all cinetpay payments" ON public.cinetpay_payments;

-- 2. Supprimer les index
DROP INDEX IF EXISTS idx_cinetpay_payments_user_id;
DROP INDEX IF EXISTS idx_cinetpay_payments_transaction_id;
DROP INDEX IF EXISTS idx_cinetpay_payments_status;

-- 3. Supprimer la table cinetpay_payments
DROP TABLE IF EXISTS public.cinetpay_payments CASCADE;

-- 4. Commentaire de documentation
COMMENT ON SCHEMA public IS 'CinetPay supprimé le 2026-01-13. Utiliser ChapChapPay pour les paiements Mobile Money.';
