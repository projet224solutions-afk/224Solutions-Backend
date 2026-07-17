-- ============================================================================
-- MARKETING VENDEUR — instrumentation du trafic RÉPARÉE (cause racine, pas de table parallèle)
--
-- CONSTAT PROUVÉ (l'infra EXISTE déjà : product_views_raw = 1093 lignes, shop_visits_raw = 82,
-- reader useTrafficAnalytics, RPC track_product_view/track_shop_visit, events temps réel Ably) :
--   1. product_views_raw n'a AUCUNE policy SELECT pour le vendeur → le dashboard lit 0 malgré
--      709 vues réelles pour un vendeur. C'est ÇA les « zéros éternels » (côté LECTURE).
--   2. Les RPC track_* SONT SECURITY DEFINER + exécutables par anon (bon chemin anti-spam), MAIS
--      leur ON CONFLICT référence un index d'expression INEXISTANT → elles plantent 42P10 (mortes).
--      D'où le service JS qui fait un INSERT DIRECT — bloqué par la RLS pour les visiteurs
--      ANONYMES (product: auth.uid()=user_id ; shop: is_vendor_or_agent). Le trafic anonyme
--      (la majorité) est donc PERDU (côté ÉCRITURE).
--
-- FIX (on ÉTEND l'existant — CLAUDE.md : chercher d'abord, étendre plutôt que recréer) :
--   A. Réparer les 2 RPC : anti-spam 30 min par NOT EXISTS (au lieu de l'ON CONFLICT cassé),
--      signature INCHANGÉE (le front passe le visitor_key stable en p_session_id).
--   B. Ajouter la policy SELECT manquante sur product_views_raw (vendeur + agent).
--   C. Index de support pour le lookup anti-spam et les lectures dashboard.
--
-- SECURITY DEFINER : le tracking anonyme est VOULU (les visiteurs non connectés comptent aussi) ;
-- la fonction n'écrit qu'une ligne d'analytics pour un couple vendeur/produit — aucune action
-- sensible. On REVOKE PUBLIC puis GRANT explicitement anon/authenticated/service_role.
-- ============================================================================

-- ── A.1 RPC track_product_view : anti-spam 30 min (même visiteur + même produit) ─────────────
CREATE OR REPLACE FUNCTION public.track_product_view(
  p_product_id uuid,
  p_vendor_id uuid,
  p_user_id uuid DEFAULT NULL::uuid,
  p_session_id text DEFAULT NULL::text,
  p_ip_address inet DEFAULT NULL::inet,
  p_user_agent text DEFAULT NULL::text,
  p_fingerprint_hash text DEFAULT NULL::text,
  p_referer_url text DEFAULT NULL::text,
  p_device_type text DEFAULT 'unknown'::text,
  p_country_code text DEFAULT NULL::text,
  p_city text DEFAULT NULL::text
)
RETURNS TABLE(success boolean, view_id uuid, message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_view_id UUID;
  -- Clé visiteur : session_id (uuid stable localStorage côté front), repli fingerprint.
  v_key TEXT := COALESCE(NULLIF(p_session_id, ''), NULLIF(p_fingerprint_hash, ''), '');
BEGIN
  IF p_product_id IS NULL OR p_vendor_id IS NULL THEN
    RETURN QUERY SELECT false, NULL::uuid, 'missing product/vendor'::text;
    RETURN;
  END IF;

  -- Anti-spam 30 min : même visiteur a déjà vu ce produit récemment → silence (jamais d'erreur).
  IF v_key <> '' AND EXISTS (
    SELECT 1 FROM product_views_raw
    WHERE product_id = p_product_id
      AND COALESCE(session_id, '') = v_key
      AND tracked_at > now() - interval '30 minutes'
  ) THEN
    RETURN QUERY SELECT false, NULL::uuid, 'View already recorded recently'::text;
    RETURN;
  END IF;

  -- ip_address et fingerprint_hash sont NOT NULL en base : COALESCE défensif (jamais de 23502
  -- même si l'appelant les omet — le front les fournit toujours, ceci est un filet de sécurité).
  INSERT INTO product_views_raw (
    product_id, vendor_id, user_id, session_id, ip_address, user_agent,
    fingerprint_hash, referer_url, device_type, country_code, city, tracked_at, view_date
  ) VALUES (
    p_product_id, p_vendor_id, p_user_id, p_session_id, COALESCE(p_ip_address, '0.0.0.0'::inet), p_user_agent,
    COALESCE(p_fingerprint_hash, v_key), p_referer_url, COALESCE(p_device_type, 'unknown'), p_country_code, p_city,
    now(), CURRENT_DATE
  )
  RETURNING id INTO v_view_id;

  RETURN QUERY SELECT true, v_view_id, 'View tracked successfully'::text;
END;
$function$;

-- ── A.2 RPC track_shop_visit : anti-spam 30 min (même visiteur + même boutique) ──────────────
CREATE OR REPLACE FUNCTION public.track_shop_visit(
  p_vendor_id uuid,
  p_user_id uuid DEFAULT NULL::uuid,
  p_session_id text DEFAULT NULL::text,
  p_ip_address inet DEFAULT NULL::inet,
  p_user_agent text DEFAULT NULL::text,
  p_fingerprint_hash text DEFAULT NULL::text,
  p_referer_url text DEFAULT NULL::text,
  p_device_type text DEFAULT 'unknown'::text,
  p_country_code text DEFAULT NULL::text,
  p_city text DEFAULT NULL::text,
  p_entry_page text DEFAULT NULL::text
)
RETURNS TABLE(success boolean, visit_id uuid, message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_visit_id UUID;
  v_key TEXT := COALESCE(NULLIF(p_session_id, ''), NULLIF(p_fingerprint_hash, ''), '');
BEGIN
  IF p_vendor_id IS NULL THEN
    RETURN QUERY SELECT false, NULL::uuid, 'missing vendor'::text;
    RETURN;
  END IF;

  IF v_key <> '' AND EXISTS (
    SELECT 1 FROM shop_visits_raw
    WHERE vendor_id = p_vendor_id
      AND COALESCE(session_id, '') = v_key
      AND tracked_at > now() - interval '30 minutes'
  ) THEN
    RETURN QUERY SELECT false, NULL::uuid, 'Visit already recorded recently'::text;
    RETURN;
  END IF;

  -- ip_address et fingerprint_hash sont NOT NULL en base : COALESCE défensif (filet de sécurité).
  INSERT INTO shop_visits_raw (
    vendor_id, user_id, session_id, ip_address, user_agent, fingerprint_hash,
    referer_url, device_type, country_code, city, entry_page, tracked_at, visit_date
  ) VALUES (
    p_vendor_id, p_user_id, p_session_id, COALESCE(p_ip_address, '0.0.0.0'::inet), p_user_agent, COALESCE(p_fingerprint_hash, v_key),
    p_referer_url, COALESCE(p_device_type, 'unknown'), p_country_code, p_city, p_entry_page,
    now(), CURRENT_DATE
  )
  RETURNING id INTO v_visit_id;

  RETURN QUERY SELECT true, v_visit_id, 'Visit tracked successfully'::text;
END;
$function$;

-- Grants explicites (le tracking anonyme est voulu). PUBLIC révoqué, rôles nommés autorisés.
REVOKE ALL ON FUNCTION public.track_product_view(uuid,uuid,uuid,text,inet,text,text,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.track_shop_visit(uuid,uuid,text,inet,text,text,text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.track_product_view(uuid,uuid,uuid,text,inet,text,text,text,text,text,text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.track_shop_visit(uuid,uuid,text,inet,text,text,text,text,text,text,text) TO anon, authenticated, service_role;

-- ── B. Policy SELECT manquante sur product_views_raw (LA cause des zéros au dashboard) ────────
-- Le vendeur propriétaire ET son agent lisent les vues de la boutique (miroir de shop_visits_raw).
DROP POLICY IF EXISTS vendors_read_own_product_views ON public.product_views_raw;
CREATE POLICY vendors_read_own_product_views ON public.product_views_raw
  FOR SELECT TO authenticated
  USING (
    vendor_id IN (SELECT id FROM public.vendors WHERE user_id = (SELECT auth.uid()))
    OR is_vendor_or_agent(vendor_id)
  );

-- ── C. Index de support : lookup anti-spam (30 min) + lectures dashboard par vendeur ──────────
CREATE INDEX IF NOT EXISTS idx_product_views_raw_dedup
  ON public.product_views_raw (product_id, session_id, tracked_at);
CREATE INDEX IF NOT EXISTS idx_product_views_raw_vendor_date
  ON public.product_views_raw (vendor_id, view_date);
CREATE INDEX IF NOT EXISTS idx_shop_visits_raw_dedup
  ON public.shop_visits_raw (vendor_id, session_id, tracked_at);
CREATE INDEX IF NOT EXISTS idx_shop_visits_raw_vendor_date
  ON public.shop_visits_raw (vendor_id, visit_date);
