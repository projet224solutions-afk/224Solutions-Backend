-- Ajouter les services manquants dans service_types (sport, maison)
INSERT INTO service_types (code, name, description, category, icon, is_active) 
VALUES 
  ('sport', 'Sport & Fitness', 'Coaching sportif, salles de sport, cours collectifs', 'Sport', 'dumbbell', true),
  ('maison', 'Maison & Décoration', 'Décoration intérieure, ameublement, artisanat', 'Services', 'home', true)
ON CONFLICT (code) DO UPDATE SET 
  is_active = true,
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  category = EXCLUDED.category;