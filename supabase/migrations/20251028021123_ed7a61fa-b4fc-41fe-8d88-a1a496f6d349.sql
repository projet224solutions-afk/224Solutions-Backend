-- Activer les mises à jour en temps réel pour la table agents_management
ALTER TABLE agents_management REPLICA IDENTITY FULL;

-- S'assurer que la table est dans la publication realtime
ALTER PUBLICATION supabase_realtime ADD TABLE agents_management;