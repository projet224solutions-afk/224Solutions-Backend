-- ===============================================
-- Migration: Fix revenus_pdg constraint + Agent types enhancements
-- ===============================================

-- 1. Corriger la contrainte CHECK de revenus_pdg
-- Ajouter 'frais_abonnement' aux valeurs autorisées
ALTER TABLE revenus_pdg 
DROP CONSTRAINT IF EXISTS revenus_pdg_source_type_check;

ALTER TABLE revenus_pdg 
ADD CONSTRAINT revenus_pdg_source_type_check 
CHECK (source_type IN (
  'frais_transaction_wallet',
  'frais_achat_commande',
  'frais_abonnement'
));

-- 2. Ajouter une contrainte CHECK pour type_agent si elle n'existe pas
ALTER TABLE agents_management
DROP CONSTRAINT IF EXISTS agents_management_type_agent_check;

ALTER TABLE agents_management
ADD CONSTRAINT agents_management_type_agent_check
CHECK (type_agent IN (
  'principal',
  'sous_agent',
  'agent_regional',
  'agent_local'
));

-- 3. Créer une fonction pour vérifier la hiérarchie des agents
CREATE OR REPLACE FUNCTION check_agent_hierarchy()
RETURNS TRIGGER AS $$
BEGIN
  -- Si l'agent est un sous-agent, il doit avoir un parent_agent_id
  IF NEW.type_agent = 'sous_agent' AND NEW.parent_agent_id IS NULL THEN
    RAISE EXCEPTION 'Un sous-agent doit avoir un agent parent';
  END IF;
  
  -- Si l'agent est principal, il ne devrait pas avoir de parent
  IF NEW.type_agent = 'principal' AND NEW.parent_agent_id IS NOT NULL THEN
    RAISE EXCEPTION 'Un agent principal ne peut pas avoir d''agent parent';
  END IF;
  
  -- Vérifier que le parent existe et est du même PDG
  IF NEW.parent_agent_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM agents_management 
      WHERE id = NEW.parent_agent_id 
      AND pdg_id = NEW.pdg_id
      AND is_active = true
    ) THEN
      RAISE EXCEPTION 'L''agent parent doit exister et appartenir au même PDG';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 4. Créer le trigger pour la validation de hiérarchie
DROP TRIGGER IF EXISTS validate_agent_hierarchy ON agents_management;

CREATE TRIGGER validate_agent_hierarchy
BEFORE INSERT OR UPDATE ON agents_management
FOR EACH ROW
EXECUTE FUNCTION check_agent_hierarchy();

-- 5. Créer une vue pour les statistiques des agents par type
CREATE OR REPLACE VIEW agent_type_statistics AS
SELECT 
  pdg_id,
  type_agent,
  COUNT(*) as total_agents,
  COUNT(CASE WHEN is_active THEN 1 END) as active_agents,
  SUM(commission_rate) as total_commission_rate
FROM agents_management
GROUP BY pdg_id, type_agent;

-- 6. Index pour améliorer les performances des requêtes d'agents
CREATE INDEX IF NOT EXISTS idx_agents_management_type_agent ON agents_management(type_agent);
CREATE INDEX IF NOT EXISTS idx_agents_management_parent_pdg ON agents_management(parent_agent_id, pdg_id);
CREATE INDEX IF NOT EXISTS idx_revenus_pdg_source_type ON revenus_pdg(source_type);

-- 7. Commentaires pour documentation
COMMENT ON COLUMN agents_management.type_agent IS 'Type d''agent: principal, sous_agent, agent_regional, ou agent_local';
COMMENT ON CONSTRAINT revenus_pdg_source_type_check ON revenus_pdg IS 'Valeurs autorisées: frais_transaction_wallet, frais_achat_commande, frais_abonnement';