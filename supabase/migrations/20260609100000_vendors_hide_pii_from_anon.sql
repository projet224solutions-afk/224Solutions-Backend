-- ============================================================================
-- SÉCURITÉ — Cacher les colonnes sensibles de `vendors` aux visiteurs ANONYMES
-- ----------------------------------------------------------------------------
-- Audit RLS (2026-06-09) : la policy « Everyone can view active vendors »
-- (USING is_active = true) laisse la clé publique anon lire TOUTES les colonnes
-- des boutiques actives, dont des données sensibles : phone, email, address,
-- kyc_status, kyc_verified_at, dispute_count. Un scraper anonyme pouvait donc
-- aspirer le contact (PII) + le statut KYC de tous les vendeurs.
--
-- CORRECTIF : privilèges au niveau COLONNE. On retire le SELECT pleine-table à
-- anon et on ne lui RE-grante que les colonnes du CATALOGUE PUBLIC (nom, logo,
-- note, ville, livraison, etc.). Les colonnes sensibles deviennent illisibles
-- pour un non-connecté. RLS (lignes) inchangée ; rôle `authenticated` inchangé
-- (vendeur, client connecté, PDG continuent de tout voir, soumis à la RLS).
--
-- NB : `user_id` est CONSERVÉ dans la liste publique car la navigation marketplace
-- anonyme (useMarketplaceUniversal) le lit ; c'est un UUID opaque (faible risque :
-- la RLS bloque tout accès aux données derrière). Le révoquer casserait le marketplace.
-- Pour le cacher aussi, il faudrait d'abord déplacer ce lookup côté backend.
--
-- Allow-list explicite : toute NOUVELLE colonne sera invisible à anon par défaut
-- tant qu'elle n'est pas ajoutée ici (sécurité par défaut). Non destructif, rejouable.
-- ============================================================================

-- 1. Retirer l'accès pleine-table d'anon (sinon le grant table écrase les colonnes).
REVOKE SELECT ON public.vendors FROM anon;

-- 2. Re-granter UNIQUEMENT les colonnes du catalogue public (sans PII ni internes).
GRANT SELECT (
  id,
  user_id,                 -- UUID opaque, requis par la navigation marketplace anonyme
  business_name,
  description,
  logo_url,
  cover_image_url,
  is_verified,
  is_active,
  rating,
  total_reviews,
  created_at,
  updated_at,
  public_id,
  vendor_code,
  delivery_base_price,
  delivery_price_per_km,
  delivery_rush_bonus,
  delivery_enabled,
  average_delivery_days,
  latitude,
  longitude,
  city,
  neighborhood,
  business_type,
  service_type,
  country,
  shop_slug,
  shop_currency,
  currency_locked,
  seller_country_code
) ON public.vendors TO anon;

SELECT 'vendors : colonnes sensibles (phone, email, address, kyc_status, kyc_verified_at, dispute_count) cachées aux visiteurs anonymes.' AS status;
