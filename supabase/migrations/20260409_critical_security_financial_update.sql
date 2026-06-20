-- MIGRATION DE SÉCURITÉ ET LOGIQUE FINANCIÈRE CRITIQUE
-- Date : 2026-04-09
-- Auteur : Automatique (Copilot)

-- 1. SÉCURISATION DES PERMISSIONS (DATABASE)
-- Supprimer les permissions excessives
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM authenticated;

-- Accorder uniquement les droits nécessaires (exemple, à adapter selon les besoins réels)
GRANT SELECT, INSERT, UPDATE ON wallets TO authenticated;
GRANT SELECT, INSERT, UPDATE ON wallet_transactions TO authenticated;
GRANT SELECT, UPDATE ON profiles TO authenticated;
GRANT SELECT ON products TO authenticated;
GRANT SELECT, INSERT, UPDATE ON orders TO authenticated;
GRANT SELECT ON subscriptions TO authenticated;
-- Ajouter d'autres tables nécessaires ici

-- Activer RLS sur toutes les tables du schéma public
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE 'ALTER TABLE public.' || quote_ident(r.tablename) || ' ENABLE ROW LEVEL SECURITY';
    END LOOP;
END $$;

-- 2. STANDARDISATION DES TRANSFERTS
-- Supprimer toutes les anciennes versions de process_wallet_transaction
DROP FUNCTION IF EXISTS process_wallet_transaction(TEXT, TEXT, DECIMAL, TEXT, TEXT);
DROP FUNCTION IF EXISTS process_wallet_transaction(UUID, UUID, NUMERIC, TEXT, TEXT);
DROP FUNCTION IF EXISTS process_wallet_transaction(TEXT, TEXT, NUMERIC, TEXT, TEXT);
DROP FUNCTION IF EXISTS process_wallet_transaction(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT);
-- Ajouter d'autres signatures si besoin

-- Utiliser exclusivement process_secure_wallet_transfer (déjà présente et sécurisée)
-- (Aucune action requise ici si la fonction est déjà en place)

-- 3. AUDIT DES FONCTIONS SECURITY DEFINER
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT proname FROM pg_proc WHERE prosecdef = true AND pronamespace = 'public'::regnamespace LOOP
        EXECUTE 'ALTER FUNCTION public.' || quote_ident(r.proname) || '() SECURITY DEFINER SET search_path = public';
    END LOOP;
END $$;

-- 4. AJOUTER/ASSURER LE PARAMÈTRE PANIC MODE
INSERT INTO system_settings (setting_key, setting_value, description)
VALUES ('panic_mode', 'false', 'Mode panique - bloque toutes les transactions financières')
ON CONFLICT (setting_key) DO NOTHING;

-- 5. COMMENTAIRE :
-- Cette migration regroupe :
-- - Sécurisation des permissions
-- - Standardisation des transferts
-- - Activation RLS sur toutes les tables
-- - Audit des SECURITY DEFINER
-- - Ajout du paramètre panic_mode
-- À appliquer sur Supabase en une seule migration.
