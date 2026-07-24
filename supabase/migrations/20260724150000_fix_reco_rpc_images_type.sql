-- 🛠️ Correctif RPC recommandations produit — type de la colonne `images`.
--
-- Symptôme : sur la fiche produit, « Produits similaires » et « Autres produits » ne renvoyaient
-- RIEN (le client basculait sur un fallback générique). Cause : la colonne `products.images` est
-- de type `text[]`, mais les fonctions get_similar_products / get_also_bought_products déclaraient
-- `images jsonb` dans leur RETURNS TABLE → erreur PostgreSQL 42804 (« structure of query does not
-- match function result type ») à CHAQUE appel.
--
-- Correctif : recréer les deux fonctions À L'IDENTIQUE en changeant UNIQUEMENT le type de `images`
-- (jsonb → text[]). CREATE OR REPLACE ne peut pas changer le type de retour d'une fonction
-- existante → on DROP puis on recrée. Grants d'origine préservés (anon/authenticated/service_role :
-- ce sont des lectures du catalogue public, appelées directement depuis le client).

-- ── Produits similaires ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.get_similar_products(uuid, integer);
CREATE FUNCTION public.get_similar_products(p_product_id uuid, p_limit integer DEFAULT 10)
 RETURNS TABLE(id uuid, name text, price numeric, images text[], rating numeric, category_id uuid, similarity_score numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_category_id uuid; v_tags text[];
BEGIN
  SELECT p.category_id, p.tags INTO v_category_id, v_tags FROM products p WHERE p.id = p_product_id;
  RETURN QUERY
  SELECT p.id, p.name, p.price::numeric, p.images, p.rating, p.category_id,
    (CASE WHEN p.category_id = v_category_id THEN 50 ELSE 0 END +
     CASE WHEN p.tags IS NOT NULL AND v_tags IS NOT NULL AND p.tags && v_tags THEN 30 ELSE 0 END +
     COALESCE((SELECT pps.popularity_score FROM product_popularity_scores pps WHERE pps.product_id = p.id), 0)::numeric * 0.2
    )::numeric AS similarity_score
  FROM products p
  JOIN vendors v ON v.id = p.vendor_id
  WHERE p.id != p_product_id AND p.is_active = true
    AND v.business_type IN ('hybrid', 'online')
    AND (p.category_id = v_category_id OR (p.tags IS NOT NULL AND v_tags IS NOT NULL AND p.tags && v_tags))
  ORDER BY similarity_score DESC LIMIT p_limit;
END;
$function$;
REVOKE ALL ON FUNCTION public.get_similar_products(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_similar_products(uuid, integer) TO anon, authenticated, service_role;

-- ── Autres produits (achetés ensemble) ─────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.get_also_bought_products(uuid, integer);
CREATE FUNCTION public.get_also_bought_products(p_product_id uuid, p_limit integer DEFAULT 8)
 RETURNS TABLE(id uuid, name text, price numeric, images text[], rating numeric, co_purchase_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT p.id, p.name, p.price::numeric, p.images, p.rating, pcp.co_purchase_count::bigint
  FROM product_co_purchases pcp
  JOIN products p ON p.id = pcp.related_product_id
  JOIN vendors v ON v.id = p.vendor_id
  WHERE pcp.product_id = p_product_id AND p.is_active = true
    AND v.business_type IN ('hybrid', 'online')
  ORDER BY pcp.co_purchase_count DESC LIMIT p_limit;
END;
$function$;
REVOKE ALL ON FUNCTION public.get_also_bought_products(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_also_bought_products(uuid, integer) TO anon, authenticated, service_role;
