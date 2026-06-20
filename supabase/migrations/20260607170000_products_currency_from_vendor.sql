-- 💱 PRODUITS EN GNF CANONIQUE (correctif/réconciliation)
--
-- Modèle confirmé par la DONNÉE : le prix produit est saisi et stocké en GNF (champ « Prix (GNF) » ;
-- toutes les colonnes devise produit valent GNF). Le `shop_currency` du vendeur (EUR/XOF) est sa
-- devise d'AFFICHAGE, PAS la devise du prix. Lire le prix dans shop_currency ferait afficher un
-- produit de 60 000 GNF comme « 60 000 EUR » (absurde).
--
-- Ce correctif garantit que les colonnes devise des produits sont en GNF (réconcilie d'éventuels
-- produits réétiquetés à tort en EUR/XOF par un ancien changement de devise). Le NOMBRE `price`
-- n'est JAMAIS modifié. L'affichage/checkout convertit ensuite GNF → devise de l'utilisateur (BCRG).

UPDATE public.products
SET currency                = 'GNF',
    seller_currency         = 'GNF',
    original_price_currency = 'GNF',
    updated_at              = now()
WHERE COALESCE(currency, 'GNF')                <> 'GNF'
   OR COALESCE(seller_currency, 'GNF')         <> 'GNF'
   OR COALESCE(original_price_currency, 'GNF') <> 'GNF';

SELECT 'Produits remis en GNF canonique (prix inchangé).' AS status;
