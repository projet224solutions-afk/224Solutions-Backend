-- ============================================================================
-- ANNUAIRE DES GROSSISTES CERTIFIÉS (bouton « Fournisseurs » du marketplace)
-- ============================================================================
-- Définition (audit 24/07) : un « grossiste certifié » = croisement de
--   1) `vendors.sale_type` ∈ ('detail_gros','gros')  — type de vente B2B
--   2) une certification `vendor_certifications.status = 'CERTIFIE'`
--      ⚠️ CLÉ DE JOINTURE NON ÉVIDENTE : `vendor_certifications.vendor_id` référence
--         `vendors.user_id` (PAS `vendors.id`). Confirmé en base (Fusion Digitale LTD).
--   3) `vendors.is_active = true`
--
-- RÈGLE ABSOLUE (décision PDG) : un grossiste certifié est listé MÊME s'il n'a AUCUN
-- produit publié (il travaille au dépôt). → PAS d'INNER JOIN products, PAS de HAVING
-- count>0. Le nombre de produits est calculé par une SOUS-REQUÊTE (LEFT), jamais un
-- filtre. Un fournisseur sans catalogue apparaît avec product_count = 0.
--
-- Lecture publique (marketplace = annuaire public) : REVOKE PUBLIC + GRANT anon/authenticated.
-- Aucune donnée sensible (nom boutique, ville, note = déjà publics dans le marketplace).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.marketplace_certified_suppliers(
  p_search  text DEFAULT NULL,
  p_city    text DEFAULT NULL,
  p_country text DEFAULT NULL
)
RETURNS TABLE (
  vendor_id     uuid,
  business_name text,
  public_id     text,
  city          text,
  country       text,
  logo_url      text,
  rating        numeric,
  total_reviews integer,
  business_type text,
  description   text,
  sale_type     text,
  product_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    v.id,
    v.business_name,
    v.public_id,
    v.city,
    v.country,
    v.logo_url,
    v.rating,
    v.total_reviews,
    v.business_type,
    v.description,
    v.sale_type,
    (SELECT count(*) FROM products p WHERE p.vendor_id = v.id AND p.is_active) AS product_count
  FROM vendors v
  WHERE v.is_active = true
    AND v.sale_type IN ('detail_gros', 'gros')
    AND EXISTS (
      SELECT 1 FROM vendor_certifications c
      WHERE c.vendor_id = v.user_id AND c.status = 'CERTIFIE'
    )
    AND (p_city    IS NULL OR p_city    = '' OR lower(v.city)    = lower(p_city))
    AND (p_country IS NULL OR p_country = '' OR lower(v.country) = lower(p_country))
    AND (
      p_search IS NULL OR p_search = ''
      OR v.business_name         ILIKE '%' || p_search || '%'
      OR coalesce(v.description, '')   ILIKE '%' || p_search || '%'
      OR coalesce(v.business_type, '') ILIKE '%' || p_search || '%'
    )
  ORDER BY
    -- Certification déjà garantie. Léger bonus au catalogue (JAMAIS éliminatoire),
    -- puis note, puis nombre d'avis, puis nom. La proximité = filtre ville (p_city).
    (CASE WHEN (SELECT count(*) FROM products p WHERE p.vendor_id = v.id AND p.is_active) > 0 THEN 1 ELSE 0 END) DESC,
    coalesce(v.rating, 0) DESC,
    coalesce(v.total_reviews, 0) DESC,
    v.business_name ASC;
$$;

COMMENT ON FUNCTION public.marketplace_certified_suppliers(text, text, text) IS
  'Annuaire des grossistes certifiés (sale_type gros/detail_gros × vendor_certifications CERTIFIE via user_id). Inclut les fournisseurs SANS produit (product_count par sous-requête, jamais d''INNER JOIN products). Lecture publique marketplace.';

REVOKE ALL ON FUNCTION public.marketplace_certified_suppliers(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.marketplace_certified_suppliers(text, text, text) TO anon, authenticated;
