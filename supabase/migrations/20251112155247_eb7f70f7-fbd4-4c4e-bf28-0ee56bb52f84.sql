-- Activer les mises à jour en temps réel pour la table orders
ALTER TABLE public.orders REPLICA IDENTITY FULL;