-- Ajouter des catégories de base pour le e-commerce
INSERT INTO categories (name, description, is_active) 
SELECT name, description, is_active FROM (VALUES 
  ('Électro Ménager', 'Appareils électroménagers', true),
  ('Mode & Vêtements', 'Vêtements et accessoires de mode', true),
  ('Alimentation', 'Produits alimentaires', true),
  ('Beauté & Santé', 'Produits de beauté et santé', true),
  ('High-Tech', 'Produits technologiques et gadgets', true),
  ('Maison & Décoration', 'Décoration et ameublement', true),
  ('Sports & Loisirs', 'Équipements sportifs et loisirs', true)
) AS t(name, description, is_active)
WHERE NOT EXISTS (SELECT 1 FROM categories c WHERE c.name = t.name);