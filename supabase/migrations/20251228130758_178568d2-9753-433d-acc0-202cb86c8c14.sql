-- ============================================
-- TRIGGERS POUR MISE À JOUR AUTOMATIQUE DES COMPTEURS BUREAUX
-- ============================================

-- Fonction pour mettre à jour total_members d'un bureau
CREATE OR REPLACE FUNCTION update_bureau_member_count()
RETURNS TRIGGER AS $$
BEGIN
  -- Si INSERT ou UPDATE, mettre à jour le nouveau bureau_id
  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    UPDATE bureaus 
    SET total_members = (
      SELECT COUNT(*) FROM members WHERE bureau_id = NEW.bureau_id
    )
    WHERE id = NEW.bureau_id;
  END IF;
  
  -- Si DELETE ou UPDATE avec changement de bureau, mettre à jour l'ancien bureau_id
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.bureau_id IS DISTINCT FROM NEW.bureau_id) THEN
    UPDATE bureaus 
    SET total_members = (
      SELECT COUNT(*) FROM members WHERE bureau_id = OLD.bureau_id
    )
    WHERE id = OLD.bureau_id;
  END IF;
  
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour mettre à jour total_vehicles d'un bureau
CREATE OR REPLACE FUNCTION update_bureau_vehicle_count()
RETURNS TRIGGER AS $$
BEGIN
  -- Si INSERT ou UPDATE, mettre à jour le nouveau bureau_id
  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    UPDATE bureaus 
    SET total_vehicles = (
      SELECT COUNT(*) FROM vehicles WHERE bureau_id = NEW.bureau_id
    )
    WHERE id = NEW.bureau_id;
  END IF;
  
  -- Si DELETE ou UPDATE avec changement de bureau, mettre à jour l'ancien bureau_id
  IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.bureau_id IS DISTINCT FROM NEW.bureau_id) THEN
    UPDATE bureaus 
    SET total_vehicles = (
      SELECT COUNT(*) FROM vehicles WHERE bureau_id = OLD.bureau_id
    )
    WHERE id = OLD.bureau_id;
  END IF;
  
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Supprimer les triggers existants s'ils existent
DROP TRIGGER IF EXISTS trigger_update_bureau_member_count ON members;
DROP TRIGGER IF EXISTS trigger_update_bureau_vehicle_count ON vehicles;

-- Créer les triggers
CREATE TRIGGER trigger_update_bureau_member_count
AFTER INSERT OR UPDATE OR DELETE ON members
FOR EACH ROW
EXECUTE FUNCTION update_bureau_member_count();

CREATE TRIGGER trigger_update_bureau_vehicle_count
AFTER INSERT OR UPDATE OR DELETE ON vehicles
FOR EACH ROW
EXECUTE FUNCTION update_bureau_vehicle_count();

-- Mettre à jour tous les compteurs existants
UPDATE bureaus b
SET total_members = (SELECT COUNT(*) FROM members m WHERE m.bureau_id = b.id);

UPDATE bureaus b
SET total_vehicles = (SELECT COUNT(*) FROM vehicles v WHERE v.bureau_id = b.id);