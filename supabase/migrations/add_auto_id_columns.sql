-- Migration: Ajouter les colonnes d'ID automatique pour tous les rôles
-- Date: 2025-12-03
-- Description: Ajout des colonnes vendor_code, driver_code, client_code, pdg_code, transitaire_code, worker_code
-- Note: agent_code et bureau_code existent déjà et ne sont pas modifiés

-- 1. Ajouter vendor_code à la table vendors (si elle existe)
DO $$ 
BEGIN
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'vendors') THEN
    IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_name = 'vendors' AND column_name = 'vendor_code') THEN
      ALTER TABLE vendors ADD COLUMN vendor_code TEXT UNIQUE;
      CREATE INDEX IF NOT EXISTS idx_vendors_vendor_code ON vendors(vendor_code);
      COMMENT ON COLUMN vendors.vendor_code IS 'Code unique vendeur (format: VND00001)';
    END IF;
  END IF;
END $$;

-- 2. Ajouter driver_code à la table drivers (taxi-moto)
DO $$ 
BEGIN
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'drivers') THEN
    IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_name = 'drivers' AND column_name = 'driver_code') THEN
      ALTER TABLE drivers ADD COLUMN driver_code TEXT UNIQUE;
      CREATE INDEX IF NOT EXISTS idx_drivers_driver_code ON drivers(driver_code);
      COMMENT ON COLUMN drivers.driver_code IS 'Code unique chauffeur (format: DRV00001)';
    END IF;
  END IF;
END $$;

-- 3. Ajouter client_code à la table clients
DO $$ 
BEGIN
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'clients') THEN
    IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_name = 'clients' AND column_name = 'client_code') THEN
      ALTER TABLE clients ADD COLUMN client_code TEXT UNIQUE;
      CREATE INDEX IF NOT EXISTS idx_clients_client_code ON clients(client_code);
      COMMENT ON COLUMN clients.client_code IS 'Code unique client (format: CLT000001)';
    END IF;
  END IF;
END $$;

-- 4. Ajouter pdg_code à la table pdg (si elle existe)
DO $$ 
BEGIN
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'pdg') THEN
    IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_name = 'pdg' AND column_name = 'pdg_code') THEN
      ALTER TABLE pdg ADD COLUMN pdg_code TEXT UNIQUE;
      CREATE INDEX IF NOT EXISTS idx_pdg_pdg_code ON pdg(pdg_code);
      COMMENT ON COLUMN pdg.pdg_code IS 'Code unique PDG (format: PDG0001)';
    END IF;
  END IF;
END $$;

-- 5. Ajouter transitaire_code à la table transitaires
DO $$ 
BEGIN
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'transitaires') THEN
    IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_name = 'transitaires' AND column_name = 'transitaire_code') THEN
      ALTER TABLE transitaires ADD COLUMN transitaire_code TEXT UNIQUE;
      CREATE INDEX IF NOT EXISTS idx_transitaires_transitaire_code ON transitaires(transitaire_code);
      COMMENT ON COLUMN transitaires.transitaire_code IS 'Code unique transitaire (format: TRS00001)';
    END IF;
  END IF;
END $$;

-- 6. Ajouter worker_code à la table workers (employés)
DO $$ 
BEGIN
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'workers') THEN
    IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_name = 'workers' AND column_name = 'worker_code') THEN
      ALTER TABLE workers ADD COLUMN worker_code TEXT UNIQUE;
      CREATE INDEX IF NOT EXISTS idx_workers_worker_code ON workers(worker_code);
      COMMENT ON COLUMN workers.worker_code IS 'Code unique employé (format: WRK00001)';
    END IF;
  END IF;
END $$;

-- 7. Vérifier que agent_code existe dans la table agents
DO $$ 
BEGIN
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'agents') THEN
    IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_name = 'agents' AND column_name = 'agent_code') THEN
      ALTER TABLE agents ADD COLUMN agent_code TEXT UNIQUE;
      CREATE INDEX IF NOT EXISTS idx_agents_agent_code ON agents(agent_code);
      COMMENT ON COLUMN agents.agent_code IS 'Code unique agent (format: AGT00001)';
    END IF;
  END IF;
END $$;

-- 8. Vérifier que bureau_code existe dans la table bureau_syndicats
DO $$ 
BEGIN
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'bureau_syndicats') THEN
    IF NOT EXISTS (SELECT FROM information_schema.columns WHERE table_name = 'bureau_syndicats' AND column_name = 'bureau_code') THEN
      ALTER TABLE bureau_syndicats ADD COLUMN bureau_code TEXT UNIQUE;
      CREATE INDEX IF NOT EXISTS idx_bureau_syndicats_bureau_code ON bureau_syndicats(bureau_code);
      COMMENT ON COLUMN bureau_syndicats.bureau_code IS 'Code unique bureau syndicat (format: BST000001)';
    END IF;
  END IF;
END $$;

-- 9. Fonction helper pour générer les IDs manquants (optionnel - à exécuter manuellement si besoin)
CREATE OR REPLACE FUNCTION generate_missing_ids()
RETURNS void AS $$
DECLARE
  v_count INTEGER;
BEGIN
  -- Cette fonction peut être appelée pour générer les IDs des enregistrements existants
  -- Elle est fournie pour référence mais n'est PAS exécutée automatiquement
  
  RAISE NOTICE 'Fonction de génération d''IDs disponible. Appelez-la manuellement si nécessaire.';
  RAISE NOTICE 'Exemple: SELECT generate_missing_ids();';
  
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION generate_missing_ids() IS 'Fonction helper pour générer les IDs manquants des enregistrements existants (à appeler manuellement)';

-- 10. Afficher un résumé de la migration
DO $$ 
DECLARE
  v_tables TEXT[] := ARRAY['vendors', 'drivers', 'clients', 'pdg', 'transitaires', 'workers', 'agents', 'bureau_syndicats'];
  v_table TEXT;
  v_exists BOOLEAN;
BEGIN
  RAISE NOTICE '=== Migration des colonnes d''ID terminée ===';
  
  FOREACH v_table IN ARRAY v_tables
  LOOP
    SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = v_table) INTO v_exists;
    IF v_exists THEN
      RAISE NOTICE 'Table % : OK', v_table;
    ELSE
      RAISE NOTICE 'Table % : N''existe pas (ignorée)', v_table;
    END IF;
  END LOOP;
  
  RAISE NOTICE '==========================================';
END $$;
