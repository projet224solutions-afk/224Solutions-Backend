-- ============================================================================
-- 🔒 ISOLATION — PALIER 3a : fuites OUVERTES À PUBLIC / ANON sur données sensibles.
--
-- L'audit complet a révélé des policies permissives `true` accordées au rôle PUBLIC
-- (OID=0, = tous rôles dont anon) ou anon sur des tables FINANCIÈRES / PII :
--   • stripe_payments  : INSERT/UPDATE ouverts à PUBLIC → n'importe qui (même non
--     connecté) pouvait écrire des enregistrements de paiement Stripe.
--   • stripe_transactions : idem (INSERT/UPDATE PUBLIC).
--   • djomy_payments / djomy_webhook_logs : ALL ouverts à PUBLIC (paiements + logs).
--   • phone_history : ALL ouvert à PUBLIC (PII numéros).
--   • load_test_logs : anon (lecture/écriture).
--
-- Écritures réelles = backend Node.js + Edge functions via service_role (BYPASSRLS),
-- donc verrouiller l'écriture côté {public,anon,authenticated} ne casse rien.
-- Lectures frontend vérifiées (grep) :
--   • stripe_transactions : lu par useStripePayment (filtre buyer_id/seller_id/id) →
--     une policy SELECT scopée existe déjà (hors liste des ouvertes) → on ne touche
--     QUE les INSERT/UPDATE ouverts.
--   • djomy_payments : lu par JomyPaymentService (filtre user_id) → l'ouverte est ALL
--     (porte la lecture) → on la remplace par un SELECT scopé user_id + PDG.
--   • stripe_payments / djomy_webhook_logs / phone_history / load_test_logs : 0 lecture
--     frontend → verrou backend-only.
--
-- Idempotent, non destructif des policies déjà scopées.
-- ============================================================================

-- ── ÉTAPE 1 : supprimer toutes les policies entièrement ouvertes (public/anon/auth) ──
DO $$
DECLARE
  r record;
  targets text[] := ARRAY[
    'stripe_payments','stripe_transactions','djomy_payments',
    'djomy_webhook_logs','phone_history','load_test_logs'
  ];
BEGIN
  FOR r IN
    SELECT c.relname AS tbl, p.polname
    FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = ANY(targets)
      AND p.polpermissive
      AND (p.polqual IS NULL
           OR btrim(lower(pg_get_expr(p.polqual, p.polrelid))) = 'true')
      AND (p.polwithcheck IS NULL
           OR btrim(lower(pg_get_expr(p.polwithcheck, p.polrelid))) = 'true')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.polname, r.tbl);
    RAISE NOTICE 'Policy ouverte supprimée : % sur %', r.polname, r.tbl;
  END LOOP;
END $$;

-- ── ÉTAPE 2 : rétablir la lecture scopée des tables encore lues par le front ──

-- djomy_payments : le propriétaire voit ses paiements (front filtre user_id) + PDG.
-- (écriture = backend service_role uniquement, pas de policy authenticated)
DROP POLICY IF EXISTS "djomy_payments_owner_select" ON public.djomy_payments;
CREATE POLICY "djomy_payments_owner_select" ON public.djomy_payments
  FOR SELECT TO authenticated
  USING (user_id = (select auth.uid()) OR public.is_admin_or_pdg((select auth.uid())));

-- stripe_transactions / stripe_payments : aucune policy de lecture recréée ici —
-- stripe_transactions garde sa policy SELECT scopée existante ; stripe_payments reste
-- backend-only (0 lecture frontend). Les écritures sont désormais backend-only partout.

-- phone_history, djomy_webhook_logs, load_test_logs : backend-only (aucune policy
-- authenticated recréée → service_role seul).

SELECT 'Palier 3a OK : stripe_payments/stripe_transactions écritures verrouillées backend ; djomy_payments lecture re-scopée (owner+PDG) ; djomy_webhook_logs/phone_history/load_test_logs verrouillés backend-only.' AS status;
