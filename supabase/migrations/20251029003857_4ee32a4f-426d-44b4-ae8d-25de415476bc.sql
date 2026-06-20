-- 🔧 ACTIVER RLS SUR LES TABLES SYSTÈME
-- Sécuriser les tables de génération d'ID

-- Table id_counters (pour la génération d'IDs standardisés)
ALTER TABLE id_counters ENABLE ROW LEVEL SECURITY;

-- Politique pour lecture publique (tous peuvent voir les compteurs)
CREATE POLICY "Anyone can view id counters"
ON id_counters FOR SELECT
USING (true);

-- Seules les edge functions peuvent modifier les compteurs
CREATE POLICY "Service role can manage id counters"
ON id_counters FOR ALL
USING (auth.role() = 'service_role');

-- Table id_migration_map (pour la migration des anciens IDs)
ALTER TABLE id_migration_map ENABLE ROW LEVEL SECURITY;

-- Lecture publique pour la compatibilité
CREATE POLICY "Anyone can view id migration map"
ON id_migration_map FOR SELECT
USING (true);

-- Seul le service role peut modifier
CREATE POLICY "Service role can manage id migration"
ON id_migration_map FOR ALL
USING (auth.role() = 'service_role');