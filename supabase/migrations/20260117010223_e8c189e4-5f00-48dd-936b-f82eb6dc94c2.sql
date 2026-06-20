-- Ajouter le champ product_type pour les types de produits numériques
ALTER TABLE public.digital_products
ADD COLUMN product_type text;

-- Créer un index pour améliorer les recherches par type
CREATE INDEX idx_digital_products_product_type ON public.digital_products(product_type);

-- Ajouter un commentaire pour documenter les valeurs possibles
COMMENT ON COLUMN public.digital_products.product_type IS 'Type spécifique du produit: logiciel_montage, antivirus, vpn, reservation_hotel, billet_avion, formation_video, ebook, template, saas, plugin, theme, musique, graphisme, autre';