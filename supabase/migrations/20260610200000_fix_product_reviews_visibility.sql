-- ============================================================================
-- ⭐ VISIBILITÉ DES AVIS PRODUITS - 224SOLUTIONS
-- ============================================================================
-- PROBLÈME : le vendeur ne voit PAS les avis laissés par les clients sur ses
-- produits. Diagnostic (clé service vs anon) :
--   • Les avis existent et sont is_approved = true.
--   • La requête du composant est correcte.
--   • MAIS en prod, la lecture de product_reviews est bloquée par RLS (drift) :
--       - la lecture publique des avis approuvés n'est pas effective,
--       - AUCUNE policy n'autorise le VENDEUR à lire les avis de ses produits.
--
-- CORRECTION (policies ADDITIVES — n'ouvrent que l'accès nécessaire) :
--   1. Public : lire les avis approuvés (fiches produits, boutique).
--   2. Vendeur : lire TOUS les avis sur SES produits (approuvés ou non) pour
--      les gérer/répondre via le Copilote.
--   3. Auteur : lire ses propres avis.
-- ============================================================================

ALTER TABLE public.product_reviews ENABLE ROW LEVEL SECURITY;

-- 1) Lecture publique des avis approuvés
DROP POLICY IF EXISTS "pr_public_read_approved" ON public.product_reviews;
CREATE POLICY "pr_public_read_approved" ON public.product_reviews
  FOR SELECT
  USING (is_approved = true);

-- 2) Le vendeur lit tous les avis sur SES produits
DROP POLICY IF EXISTS "pr_vendor_read_own_products" ON public.product_reviews;
CREATE POLICY "pr_vendor_read_own_products" ON public.product_reviews
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.products p
      JOIN public.vendors v ON v.id = p.vendor_id
      WHERE p.id = product_reviews.product_id
        AND v.user_id = auth.uid()
    )
  );

-- 3) L'auteur lit ses propres avis (même non approuvés)
DROP POLICY IF EXISTS "pr_author_read_own" ON public.product_reviews;
CREATE POLICY "pr_author_read_own" ON public.product_reviews
  FOR SELECT
  USING (auth.uid() = user_id);

-- 4) Le vendeur peut répondre aux avis sur ses produits (UPDATE de vendor_response)
DROP POLICY IF EXISTS "pr_vendor_respond_own_products" ON public.product_reviews;
CREATE POLICY "pr_vendor_respond_own_products" ON public.product_reviews
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1
      FROM public.products p
      JOIN public.vendors v ON v.id = p.vendor_id
      WHERE p.id = product_reviews.product_id
        AND v.user_id = auth.uid()
    )
  );

-- ============================================================================
-- 5) RPC : noms des auteurs d'avis (pour afficher le vrai nom au lieu de "Client")
-- SECURITY DEFINER mais STRICTEMENT limité aux avis des produits du vendeur appelant
-- → respecte la vie privée (le vendeur ne voit que les noms de SES clients-évaluateurs).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_review_author_names(p_review_ids uuid[])
RETURNS TABLE(review_id uuid, author_name text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    pr.id AS review_id,
    COALESCE(
      NULLIF(TRIM(CONCAT(pf.first_name, ' ', pf.last_name)), ''),
      pf.full_name,
      'Client'
    ) AS author_name
  FROM public.product_reviews pr
  JOIN public.products prod ON prod.id = pr.product_id
  JOIN public.vendors v ON v.id = prod.vendor_id
  LEFT JOIN public.profiles pf ON pf.id = pr.user_id
  WHERE pr.id = ANY(p_review_ids)
    AND v.user_id = auth.uid();
$$;

GRANT EXECUTE ON FUNCTION public.get_review_author_names(uuid[]) TO authenticated;
