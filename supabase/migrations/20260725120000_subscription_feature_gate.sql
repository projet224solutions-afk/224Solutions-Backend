-- ============================================================================
-- RESTRICTION IMMÉDIATE À L'EXPIRATION D'ABONNEMENT (décision produit Thierno)
-- ============================================================================
-- À l'expiration d'un abonnement PAYANT, le vendeur perd immédiatement l'accès :
-- ses produits disparaissent du marketplace/catégories/POS, les fonctionnalités
-- payantes sont coupées. Au renouvellement, SEULS les produits masqués par
-- l'expiration reviennent (jamais ceux que le vendeur avait désactivés lui-même).
--
-- Source de vérité SERVEUR = has_active_feature(user, feature). Backend (middleware
-- requireFeature), RLS (payment_links) et frontend s'y réfèrent. Réversibilité =
-- colonne products.hidden_by_subscription (marqueur distinct du is_active manuel).
--
-- Masquage + réactivation = TRIGGERS sur public.subscriptions → atomiques dans la
-- transaction qui change le statut (job d'expiration OU RPC d'achat), idempotents,
-- non contournables, SANS modifier la RPC d'achat atomique existante (interdit #5).
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 1) RÉVERSIBILITÉ — marqueur « masqué par l'abonnement » (≠ désactivation manuelle)
-- ─────────────────────────────────────────────────────────────────────────
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS hidden_by_subscription boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_products_hidden_by_subscription
  ON public.products(vendor_id) WHERE hidden_by_subscription = true;

COMMENT ON COLUMN public.products.hidden_by_subscription IS
  'true = produit masqué automatiquement par l''expiration d''abonnement (réactivable au renouvellement). NE PAS confondre avec is_active=false posé manuellement par le vendeur, qui lui doit rester désactivé.';

-- ─────────────────────────────────────────────────────────────────────────
-- 2) TABLE DE CORRESPONDANCE plan → fonctionnalités (source de vérité serveur)
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.plan_features (
  plan_id     uuid NOT NULL REFERENCES public.plans(id) ON DELETE CASCADE,
  feature_key text NOT NULL,
  PRIMARY KEY (plan_id, feature_key)
);

ALTER TABLE public.plan_features ENABLE ROW LEVEL SECURITY;

-- Les fonctionnalités d'un plan ne sont pas secrètes (déjà affichées côté client).
-- Lecture publique ; écriture réservée au service_role (aucune policy d'écriture).
DROP POLICY IF EXISTS plan_features_read ON public.plan_features;
CREATE POLICY plan_features_read ON public.plan_features
  FOR SELECT TO anon, authenticated USING (true);

-- Seed calqué EXACTEMENT sur la source de vérité frontend actuelle
-- (src/hooks/useSubscriptionFeatures.ts → PLAN_FEATURES). Cumulatif vers le haut.
-- Reseed idempotent des 5 plans vendeur (DELETE ciblé puis INSERT).
DELETE FROM public.plan_features
 WHERE plan_id IN (SELECT id FROM public.plans WHERE name IN ('free','basic','pro','business','premium'));

INSERT INTO public.plan_features (plan_id, feature_key)
SELECT p.id, f.feature_key
FROM public.plans p
JOIN (VALUES
  -- ===== FREE (socle minimal — un vendeur non abonné garde au moins ça) =====
  ('free','products_basic'), ('free','orders_simple'), ('free','wallet_basic'),
  ('free','ratings'), ('free','support_basic'),

  -- ===== BASIC =====
  ('basic','pos_system'), ('basic','inventory_management'), ('basic','products_basic'),
  ('basic','delivery_tracking'), ('basic','ratings'), ('basic','support_basic'),
  ('basic','support_tickets'), ('basic','communication_hub'), ('basic','copilot_ai'),
  ('basic','wallet_basic'), ('basic','orders_simple'), ('basic','orders_detailed'),
  ('basic','notifications_push'), ('basic','email_support'), ('basic','auto_billing'),
  ('basic','analytics_basic'),

  -- ===== PRO (= BASIC + marketing/analytics avancés) =====
  ('pro','pos_system'), ('pro','inventory_management'), ('pro','products_basic'),
  ('pro','delivery_tracking'), ('pro','ratings'), ('pro','support_basic'),
  ('pro','support_tickets'), ('pro','communication_hub'), ('pro','copilot_ai'),
  ('pro','wallet_basic'), ('pro','orders_simple'), ('pro','orders_detailed'),
  ('pro','notifications_push'), ('pro','email_support'), ('pro','auto_billing'),
  ('pro','analytics_basic'), ('pro','marketing_promotions'), ('pro','analytics_advanced'),
  ('pro','affiliate_program'), ('pro','stock_alerts'), ('pro','complete_history'),
  ('pro','priority_support'), ('pro','featured_products'),

  -- ===== BUSINESS (= PRO + finance avancée + produits illimités) =====
  ('business','pos_system'), ('business','inventory_management'), ('business','products_basic'),
  ('business','products_unlimited'), ('business','delivery_tracking'), ('business','ratings'),
  ('business','support_basic'), ('business','support_tickets'), ('business','communication_hub'),
  ('business','copilot_ai'), ('business','wallet_basic'), ('business','wallet_unlimited'),
  ('business','orders_simple'), ('business','orders_detailed'), ('business','notifications_push'),
  ('business','email_support'), ('business','auto_billing'), ('business','analytics_basic'),
  ('business','analytics_advanced'), ('business','marketing_promotions'),
  ('business','affiliate_program'), ('business','stock_alerts'), ('business','complete_history'),
  ('business','priority_support'), ('business','featured_products'), ('business','quotes_invoices'),
  ('business','payments'), ('business','payment_links'), ('business','expenses'),
  ('business','expense_management'), ('business','debt_management'), ('business','contracts'),
  ('business','supplier_management'), ('business','multi_warehouse'), ('business','data_export'),
  ('business','prospect_management'), ('business','advanced_integrations'), ('business','multi_user'),
  ('business','gemini_ai'),

  -- ===== PREMIUM (tout, sans restriction) =====
  ('premium','pos_system'), ('premium','inventory_management'), ('premium','products_basic'),
  ('premium','products_unlimited'), ('premium','delivery_tracking'), ('premium','ratings'),
  ('premium','support_basic'), ('premium','support_tickets'), ('premium','communication_hub'),
  ('premium','copilot_ai'), ('premium','crm_basic'), ('premium','crm_advanced'),
  ('premium','wallet_basic'), ('premium','wallet_unlimited'), ('premium','orders_simple'),
  ('premium','orders_detailed'), ('premium','notifications_push'), ('premium','email_support'),
  ('premium','auto_billing'), ('premium','analytics_basic'), ('premium','analytics_advanced'),
  ('premium','analytics_realtime'), ('premium','marketing_promotions'), ('premium','affiliate_program'),
  ('premium','sales_agents'), ('premium','stock_alerts'), ('premium','complete_history'),
  ('premium','priority_support'), ('premium','featured_products'), ('premium','quotes_invoices'),
  ('premium','payments'), ('premium','payment_links'), ('premium','expenses'),
  ('premium','expense_management'), ('premium','debt_management'), ('premium','contracts'),
  ('premium','supplier_management'), ('premium','multi_warehouse'), ('premium','data_export'),
  ('premium','prospect_management'), ('premium','advanced_integrations'), ('premium','multi_user'),
  ('premium','gemini_ai'), ('premium','advanced_security'), ('premium','dedicated_manager'),
  ('premium','custom_branding'), ('premium','training'), ('premium','offline_mode'),
  ('premium','cloud_sync'), ('premium','custom_reports'), ('premium','unlimited_modules'),
  ('premium','custom_commissions'), ('premium','unlimited_integrations')
) AS f(plan_name, feature_key) ON f.plan_name = p.name
ON CONFLICT (plan_id, feature_key) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────
-- 3) FONCTION CANONIQUE — l'unique source de vérité (backend + RLS + frontend)
-- ─────────────────────────────────────────────────────────────────────────
-- Vrai si : le user a un abonnement actif/trialing NON expiré dont le plan accorde
-- la fonctionnalité, OU si la fonctionnalité fait partie du socle FREE (toujours
-- disponible, même sans aucune ligne d'abonnement → un vendeur non abonné garde le
-- minimum, cf. exigence « products_basic/orders_simple toujours OK »).
CREATE OR REPLACE FUNCTION public.has_active_feature(p_user_id uuid, p_feature text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.subscriptions s
    JOIN public.plan_features pf ON pf.plan_id = s.plan_id
    WHERE s.user_id = p_user_id
      AND s.status IN ('active','trialing')
      AND s.current_period_end > now()
      AND pf.feature_key = p_feature
  )
  OR EXISTS (
    SELECT 1
    FROM public.plan_features pf
    JOIN public.plans p ON p.id = pf.plan_id
    WHERE p.name = 'free' AND pf.feature_key = p_feature
  );
$$;

-- Supabase accorde EXECUTE à anon/authenticated par DEFAULT PRIVILEGES à la création :
-- REVOKE FROM PUBLIC ne suffit pas → on retire explicitement anon (jamais appelant légitime).
REVOKE ALL ON FUNCTION public.has_active_feature(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_active_feature(uuid, text) TO authenticated, service_role;

COMMENT ON FUNCTION public.has_active_feature(uuid, text) IS
  'Source de vérité serveur du gating d''abonnement. true si le plan actif du user accorde la fonctionnalité, ou si c''est une fonctionnalité du socle free. Appelée par le middleware backend requireFeature ET par la RLS INSERT/UPDATE de payment_links.';

-- ─────────────────────────────────────────────────────────────────────────
-- 4) RLS payment_links — gate INSERT/UPDATE par has_active_feature (PRIORITÉ)
-- ─────────────────────────────────────────────────────────────────────────
-- Reflète fidèlement la policy propriétaire existante (USING/CHECK = owner_user_id),
-- et AJOUTE la condition d'abonnement UNIQUEMENT au WITH CHECK (→ s'applique à
-- INSERT et UPDATE, la LIGNE écrite). La lecture (SELECT via USING) et la suppression
-- (DELETE via USING) restent ouvertes au propriétaire : un vendeur expiré VOIT et
-- peut annuler/supprimer ses liens, mais n'en crée/édite plus. Création = insert
-- Supabase direct côté client → cette RLS est le vrai rempart (un curl direct = 403).
DROP POLICY IF EXISTS "Owners can manage their payment links" ON public.payment_links;
CREATE POLICY "Owners can manage their payment links" ON public.payment_links
  FOR ALL TO authenticated
  USING (owner_user_id = (SELECT auth.uid()))
  WITH CHECK (
    owner_user_id = (SELECT auth.uid())
    AND public.has_active_feature((SELECT auth.uid()), 'payment_links')
  );

-- ─────────────────────────────────────────────────────────────────────────
-- 5) TRIGGER — masquage des produits à l'expiration d'un abonnement PAYANT
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_hide_products_on_subscription_expiry()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_vendor uuid;
  v_count  int;
BEGIN
  -- Ne se déclenche QUE quand un abonnement PAYANT passe réellement à 'expired'.
  IF NOT (NEW.status = 'expired'
          AND COALESCE(OLD.price_paid_gnf, 0) > 0
          AND OLD.status IS DISTINCT FROM 'expired') THEN
    RETURN NEW;
  END IF;

  SELECT id INTO v_vendor FROM public.vendors WHERE user_id = NEW.user_id;
  IF v_vendor IS NULL THEN
    RETURN NEW;
  END IF;

  -- Masque UNIQUEMENT les produits actuellement actifs (préserve les désactivations
  -- manuelles : is_active=false reste false, hidden_by_subscription reste false).
  UPDATE public.products
     SET is_active = false, hidden_by_subscription = true, updated_at = now()
   WHERE vendor_id = v_vendor AND is_active = true;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  IF v_count > 0 THEN
    INSERT INTO public.notifications (user_id, title, message, type, read, metadata)
    VALUES (
      NEW.user_id,
      'Abonnement expiré — produits masqués',
      'Votre abonnement a expiré. ' || v_count || ' de vos produits ne sont plus '
        || 'visibles dans le marketplace ni au point de vente. Renouvelez votre '
        || 'abonnement pour les réafficher automatiquement.',
      'subscription_expiry', false,
      jsonb_build_object('hidden_products', v_count, 'reason', 'subscription_expired')
    );
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.tg_hide_products_on_subscription_expiry() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_hide_products_on_expiry ON public.subscriptions;
CREATE TRIGGER trg_hide_products_on_expiry
  AFTER UPDATE ON public.subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.tg_hide_products_on_subscription_expiry();

-- ─────────────────────────────────────────────────────────────────────────
-- 6) TRIGGER — réactivation au renouvellement (quota-aware, plus récents d'abord)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_reactivate_products_on_renewal()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_vendor   uuid;
  v_max      int;
  v_active   int;
  v_slots    int;
  v_hidden   int;
  v_restored int;
  v_left     int;
BEGIN
  -- Ne se déclenche QUE pour un abonnement PAYANT devenu actif et non expiré.
  IF NOT (NEW.status = 'active'
          AND COALESCE(NEW.price_paid_gnf, 0) > 0
          AND NEW.current_period_end > now()) THEN
    RETURN NEW;
  END IF;

  -- Sur UPDATE, ne rien faire si rien de pertinent n'a changé (évite les re-tirs).
  IF TG_OP = 'UPDATE' AND NOT (
       OLD.status             IS DISTINCT FROM NEW.status
    OR OLD.current_period_end IS DISTINCT FROM NEW.current_period_end
    OR OLD.plan_id            IS DISTINCT FROM NEW.plan_id
  ) THEN
    RETURN NEW;
  END IF;

  SELECT id INTO v_vendor FROM public.vendors WHERE user_id = NEW.user_id;
  IF v_vendor IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT count(*) INTO v_hidden FROM public.products
   WHERE vendor_id = v_vendor AND hidden_by_subscription = true;
  IF v_hidden = 0 THEN
    RETURN NEW;  -- rien à réactiver
  END IF;

  SELECT max_products INTO v_max FROM public.plans WHERE id = NEW.plan_id;

  IF v_max IS NULL THEN
    -- Plan illimité : réactiver TOUT ce qui avait été masqué par l'expiration.
    UPDATE public.products
       SET is_active = true, hidden_by_subscription = false, updated_at = now()
     WHERE vendor_id = v_vendor AND hidden_by_subscription = true;
    RETURN NEW;
  END IF;

  -- Quota fini : les produits déjà actifs (non masqués) consomment des places.
  SELECT count(*) INTO v_active FROM public.products
   WHERE vendor_id = v_vendor AND is_active = true AND hidden_by_subscription = false;
  v_slots := GREATEST(v_max - v_active, 0);

  v_restored := 0;
  IF v_slots > 0 THEN
    UPDATE public.products p
       SET is_active = true, hidden_by_subscription = false, updated_at = now()
     WHERE p.id IN (
       SELECT id FROM public.products
        WHERE vendor_id = v_vendor AND hidden_by_subscription = true
        ORDER BY created_at DESC   -- les plus récents reviennent en priorité
        LIMIT v_slots
     );
    GET DIAGNOSTICS v_restored = ROW_COUNT;
  END IF;

  v_left := v_hidden - v_restored;
  IF v_left > 0 THEN
    INSERT INTO public.notifications (user_id, title, message, type, read, metadata)
    VALUES (
      NEW.user_id,
      'Produits partiellement réactivés',
      'Abonnement renouvelé : ' || v_restored || ' produit(s) réaffichés. '
        || v_left || ' produit(s) restent masqués car votre plan limite à ' || v_max
        || ' produits. Passez à un plan supérieur pour tous les réafficher.',
      'subscription_renewal', false,
      jsonb_build_object('restored', v_restored, 'still_hidden', v_left, 'max_products', v_max)
    );
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.tg_reactivate_products_on_renewal() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_reactivate_products_on_renewal ON public.subscriptions;
CREATE TRIGGER trg_reactivate_products_on_renewal
  AFTER INSERT OR UPDATE ON public.subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.tg_reactivate_products_on_renewal();
