-- ════════════════════════════════════════════════════════════════════════════
-- 🏷️ TYPE DE VENTE DU VENDEUR — detaillant | detail_gros | gros (17/07/2026)
--
-- Règle PDG : chaque vendeur choisit son type de vente. Seul le côté VENTE EN
-- GROS (Espace Ventes B2B : liens de vente, tarifs client, visibilité comme
-- fournisseur) s'active/se masque — le côté ACHAT (Gestion Fournisseurs &
-- Achats) reste ouvert à TOUS (le détaillant est le CLIENT du B2B).
--
-- | sale_type    | Acheter (B2B) | Vendre en gros | Trouvable comme fournisseur |
-- | detaillant   | ✅            | ❌             | ❌                          |
-- | detail_gros  | ✅            | ✅             | ✅                          |
-- | gros         | ✅            | ✅             | ✅                          |
--
-- NB : vendors.business_type EXISTE déjà mais porte un AUTRE sens
-- (physical/digital/hybrid = type de boutique) → nouvelle colonne dédiée.
--
-- Défauts : comptes EXISTANTS → 'detail_gros' (ne casse l'accès B2B d'aucun
-- vendeur actuel qui l'utilise déjà) ; NOUVEAUX comptes → 'detaillant'
-- (ils choisissent à l'inscription / dans les réglages).
-- ════════════════════════════════════════════════════════════════════════════

-- 1) Colonne + backfill sûr des existants AVANT le NOT NULL.
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS sale_type text;

UPDATE public.vendors SET sale_type = 'detail_gros' WHERE sale_type IS NULL;

ALTER TABLE public.vendors ALTER COLUMN sale_type SET DEFAULT 'detaillant';
ALTER TABLE public.vendors ALTER COLUMN sale_type SET NOT NULL;

-- CHECK aligné au code (leçon enum/CHECK : mêmes valeurs des deux côtés).
ALTER TABLE public.vendors DROP CONSTRAINT IF EXISTS vendors_sale_type_check;
ALTER TABLE public.vendors ADD CONSTRAINT vendors_sale_type_check
  CHECK (sale_type IN ('detaillant', 'detail_gros', 'gros'));

COMMENT ON COLUMN public.vendors.sale_type IS
  'Type de vente : detaillant (achat B2B seulement) | detail_gros | gros (vend en gros). Seul le côté VENTE s''active/se masque — l''achat reste ouvert à tous.';

-- 2) Garde SERVEUR au niveau DONNÉES : les tarifs client (b2b_client_prices)
--    s'écrivent en direct sous RLS depuis le front → un détaillant ne peut PAS
--    créer/modifier de tarif de gros. Lecture/suppression inchangées (nettoyage
--    et suivi du « B2B en cours » possibles après une descente de type).
DROP POLICY IF EXISTS b2b_client_prices_supplier ON public.b2b_client_prices;
CREATE POLICY b2b_client_prices_supplier ON public.b2b_client_prices
  FOR ALL TO authenticated
  USING (supplier_vendor_id IN (SELECT id FROM public.vendors WHERE user_id = auth.uid()))
  WITH CHECK (
    supplier_vendor_id IN (
      SELECT id FROM public.vendors
      WHERE user_id = auth.uid()
        AND sale_type <> 'detaillant'   -- 🛡️ vente en gros requise pour TARIFER
    )
    -- Le produit tarifé doit appartenir au fournisseur.
    AND product_id IN (SELECT p.id FROM public.products p
                       WHERE p.vendor_id = supplier_vendor_id)
  );
