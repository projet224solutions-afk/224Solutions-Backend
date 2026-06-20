-- Synchroniser le compteur PRD avec la valeur maximale existante dans products
UPDATE id_counters 
SET current_value = (
  SELECT COALESCE(
    MAX(CAST(SUBSTRING(public_id FROM 4) AS INTEGER)), 
    0
  ) 
  FROM products 
  WHERE public_id LIKE 'PRD%'
),
updated_at = NOW()
WHERE prefix = 'PRD';