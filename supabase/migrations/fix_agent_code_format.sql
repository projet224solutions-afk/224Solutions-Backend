-- Migration: Correction du format d'ID Agent vers format séquentiel
-- Date: 2025-12-03
-- Objectif: Remplacer le format aléatoire (SAG-MIAOINPJ) par format séquentiel (AGT00001)

-- 1. Supprimer tous les anciens triggers et fonctions
DROP TRIGGER IF EXISTS trigger_auto_agent_code ON public.agents_management;
DROP TRIGGER IF EXISTS set_vendor_agent_defaults_trigger ON public.vendor_agents;
DROP FUNCTION IF EXISTS auto_generate_agent_code() CASCADE;
DROP FUNCTION IF EXISTS generate_unique_agent_code() CASCADE;
DROP FUNCTION IF EXISTS generate_vendor_agent_code() CASCADE;
DROP FUNCTION IF EXISTS set_vendor_agent_defaults() CASCADE;

-- 2. Créer la nouvelle fonction de génération séquentielle
CREATE OR REPLACE FUNCTION generate_sequential_agent_code()
RETURNS TEXT AS $$
DECLARE
  last_code TEXT;
  last_number INTEGER;
  new_number INTEGER;
  new_code TEXT;
BEGIN
  -- Récupérer le dernier code agent qui commence par 'AGT'
  SELECT agent_code INTO last_code
  FROM agents_management
  WHERE agent_code ~ '^AGT[0-9]{5}$'
  ORDER BY agent_code DESC
  LIMIT 1;
  
  -- Si aucun code n'existe, commencer à AGT00001
  IF last_code IS NULL THEN
    new_number := 1;
  ELSE
    -- Extraire le numéro et incrémenter
    last_number := CAST(SUBSTRING(last_code FROM 4) AS INTEGER);
    new_number := last_number + 1;
  END IF;
  
  -- Formater le nouveau code: AGT + 5 chiffres
  new_code := 'AGT' || LPAD(new_number::TEXT, 5, '0');
  
  -- Vérifier l'unicité (au cas où)
  WHILE EXISTS(SELECT 1 FROM agents_management WHERE agent_code = new_code) LOOP
    new_number := new_number + 1;
    new_code := 'AGT' || LPAD(new_number::TEXT, 5, '0');
  END LOOP;
  
  RETURN new_code;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Créer le trigger pour auto-génération
CREATE OR REPLACE FUNCTION auto_generate_sequential_agent_code()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.agent_code IS NULL OR NEW.agent_code = '' OR NEW.agent_code !~ '^AGT[0-9]{5}$' THEN
    NEW.agent_code := generate_sequential_agent_code();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Attacher le trigger à la table agents_management
CREATE TRIGGER trigger_auto_sequential_agent_code
BEFORE INSERT OR UPDATE ON public.agents_management
FOR EACH ROW
EXECUTE FUNCTION auto_generate_sequential_agent_code();

-- 5. Fonction pour migrer les codes existants (optionnel - à exécuter manuellement)
CREATE OR REPLACE FUNCTION migrate_existing_agent_codes()
RETURNS TABLE(old_code TEXT, new_code TEXT, agent_id UUID) AS $$
DECLARE
  agent_record RECORD;
  new_agent_code TEXT;
BEGIN
  -- Parcourir tous les agents avec des codes non conformes
  FOR agent_record IN 
    SELECT id, agent_code 
    FROM agents_management 
    WHERE agent_code IS NOT NULL 
    AND agent_code !~ '^AGT[0-9]{5}$'
    ORDER BY created_at
  LOOP
    -- Générer un nouveau code séquentiel
    new_agent_code := generate_sequential_agent_code();
    
    -- Mettre à jour le code
    UPDATE agents_management 
    SET agent_code = new_agent_code 
    WHERE id = agent_record.id;
    
    -- Retourner les informations de migration
    old_code := agent_record.agent_code;
    new_code := new_agent_code;
    agent_id := agent_record.id;
    RETURN NEXT;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. Commentaires
COMMENT ON FUNCTION generate_sequential_agent_code() IS 'Génère un code agent séquentiel au format AGT00001, AGT00002, etc.';
COMMENT ON FUNCTION auto_generate_sequential_agent_code() IS 'Trigger function pour auto-générer les codes agents de manière séquentielle';
COMMENT ON FUNCTION migrate_existing_agent_codes() IS 'Fonction de migration pour convertir les anciens codes agents vers le nouveau format (à exécuter manuellement)';

-- 7. Message de succès
DO $$ 
BEGIN
  RAISE NOTICE '✅ Migration terminée: Format d''ID agent changé vers AGT00001';
  RAISE NOTICE '📌 Pour migrer les codes existants, exécutez: SELECT * FROM migrate_existing_agent_codes();';
END $$;
