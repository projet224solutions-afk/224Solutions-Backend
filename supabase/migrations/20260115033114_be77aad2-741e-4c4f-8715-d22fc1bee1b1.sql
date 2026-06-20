-- Désactiver le type de service "Voyage / Tourisme"
UPDATE service_types 
SET is_active = false 
WHERE code = 'voyage';