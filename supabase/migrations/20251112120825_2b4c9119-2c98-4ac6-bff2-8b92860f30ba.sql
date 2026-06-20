-- Ajouter un type enum pour la source de commande
CREATE TYPE order_source AS ENUM ('online', 'pos');

-- Ajouter la colonne source à la table orders
ALTER TABLE public.orders 
ADD COLUMN source order_source DEFAULT 'online' NOT NULL;

-- Mettre à jour les commandes existantes POS (celles avec "Paiement POS" dans notes)
UPDATE public.orders 
SET source = 'pos'
WHERE notes LIKE '%Paiement POS%';

-- Créer un index pour améliorer les performances des requêtes filtrées par source
CREATE INDEX idx_orders_source ON public.orders(source);

-- Ajouter un commentaire pour documenter la colonne
COMMENT ON COLUMN public.orders.source IS 'Source de la commande: online pour les achats via interface client, pos pour les ventes au point de vente';