
-- ============================================
-- SUPPRESSION DE TOUTES LES VERSIONS DE LA FONCTION
-- ============================================
DROP FUNCTION IF EXISTS process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT, TEXT);
DROP FUNCTION IF EXISTS process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT);
DROP FUNCTION IF EXISTS process_secure_wallet_transfer(UUID, UUID, NUMERIC, TEXT, NUMERIC);
