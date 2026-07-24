-- 🎯 « Produits similaires » enrichi — de vrais similaires, pas « tout ce qui est en Électronique ».
--
-- Constat : 83 % du catalogue est dans UNE catégorie (« Électronique »). L'ancien score
-- (+50 catégorie, +30 tags, +popularité) était donc dominé par la catégorie → les « similaires »
-- d'un ventilateur étaient des encres de sublimation (même catégorie, très populaires).
--
-- Enrichissement (sans casser l'existant — mêmes colonnes de retour) :
--   +50  même catégorie                (existant)
--   +30  tags en commun                (existant)
--   +25  même VENDEUR                  (nouveau — la boutique du produit consulté)
--   +20  prix PROCHE (±40 %)           (nouveau — discrimine encre 25k vs ventilateur 200k)
--   +15  même SECTION/sous-catégorie   (nouveau — plus fin que la catégorie)
--   +10  même catégorie PARENTE        (nouveau — élargissement doux)
--   +popularité × 0,2                  (existant)
--
-- Élargissement PROGRESSIF via le WHERE : le vivier inclut désormais même vendeur / même section /
-- catégorie parente EN PLUS de catégorie+tags → un produit non catégorisé mais d'une boutique
-- multi-produits obtient de vrais candidats (au lieu de tomber dans un repli « produits au
-- hasard » côté service). Si RIEN ne matche → 0 ligne → état vide honnête côté UI (plus de repli).
-- Tri par score décroissant, produit courant et produits inactifs exclus (règle en vigueur).

DROP FUNCTION IF EXISTS public.get_similar_products(uuid, integer);
CREATE FUNCTION public.get_similar_products(p_product_id uuid, p_limit integer DEFAULT 10)
 RETURNS TABLE(id uuid, name text, price numeric, images text[], rating numeric, category_id uuid, similarity_score numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_category_id uuid;
  v_tags        text[];
  v_vendor_id   uuid;
  v_section     text;
  v_price       numeric;
  v_parent_id   uuid;
BEGIN
  SELECT p.category_id, p.tags, p.vendor_id, p.section, p.price
    INTO v_category_id, v_tags, v_vendor_id, v_section, v_price
  FROM products p WHERE p.id = p_product_id;

  SELECT c.parent_id INTO v_parent_id FROM categories c WHERE c.id = v_category_id;

  RETURN QUERY
  SELECT p.id, p.name, p.price::numeric, p.images, p.rating, p.category_id,
    (
      CASE WHEN p.category_id = v_category_id THEN 50 ELSE 0 END
      + CASE WHEN p.tags IS NOT NULL AND v_tags IS NOT NULL AND p.tags && v_tags THEN 30 ELSE 0 END
      + CASE WHEN p.vendor_id = v_vendor_id THEN 25 ELSE 0 END
      + CASE WHEN v_price IS NOT NULL AND v_price > 0 AND p.price BETWEEN v_price * 0.6 AND v_price * 1.4 THEN 20 ELSE 0 END
      + CASE WHEN v_section IS NOT NULL AND v_section <> '' AND p.section = v_section THEN 15 ELSE 0 END
      + CASE WHEN v_parent_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM categories c2 WHERE c2.id = p.category_id AND c2.parent_id = v_parent_id
            ) THEN 10 ELSE 0 END
      + COALESCE((SELECT pps.popularity_score FROM product_popularity_scores pps WHERE pps.product_id = p.id), 0)::numeric * 0.2
    )::numeric AS similarity_score
  FROM products p
  JOIN vendors v ON v.id = p.vendor_id
  WHERE p.id != p_product_id
    AND p.is_active = true
    AND v.business_type IN ('hybrid', 'online')
    AND (
          p.category_id = v_category_id
       OR (p.tags IS NOT NULL AND v_tags IS NOT NULL AND p.tags && v_tags)
       OR p.vendor_id = v_vendor_id
       OR (v_section IS NOT NULL AND v_section <> '' AND p.section = v_section)
       OR (v_parent_id IS NOT NULL AND EXISTS (
             SELECT 1 FROM categories c2 WHERE c2.id = p.category_id AND c2.parent_id = v_parent_id))
    )
  ORDER BY similarity_score DESC, p.rating DESC NULLS LAST
  LIMIT p_limit;
END;
$function$;
REVOKE ALL ON FUNCTION public.get_similar_products(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_similar_products(uuid, integer) TO anon, authenticated, service_role;
