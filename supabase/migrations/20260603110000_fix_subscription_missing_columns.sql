-- =====================================================================
-- FIX : colonnes manquantes référencées par les fonctions d'abonnement
-- =====================================================================
-- L'ACHAT d'abonnement a été déplacé dans le backend Node.js
-- (POST /api/subscriptions/purchase) — il ne dépend plus des RPC Postgres.
--
-- Mais la RPC de LECTURE `get_active_subscription()` (encore utilisée par
-- useSubscription.tsx et components/subscriptions/SubscriptionPlans.tsx) reste
-- cassée : elle lit `plans.duration_days` et `plans.user_role`, colonnes
-- absentes de `plans` → « 42703 column "duration_days"/"user_role" does not exist ».
-- Les fonctions les consomment via COALESCE(..., défaut) : il suffit d'ajouter
-- les colonnes (nullable) pour réparer ces lectures.
--   - duration_days NULL -> COALESCE(...,30)
--   - user_role NULL     -> COALESCE(...,'vendeur')
--
-- (Optionnel : on pourra à terme migrer ces lectures vers le backend et
--  supprimer les RPC subscribe_user/record_subscription_payment/get_active_subscription.)
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

ALTER TABLE public.plans ADD COLUMN IF NOT EXISTS duration_days INTEGER;
ALTER TABLE public.plans ADD COLUMN IF NOT EXISTS user_role   TEXT;

-- Optionnel : valeurs explicites (sinon les COALESCE des fonctions s'en chargent)
UPDATE public.plans SET duration_days = 30      WHERE duration_days IS NULL;
UPDATE public.plans SET user_role     = 'vendeur' WHERE user_role IS NULL;
