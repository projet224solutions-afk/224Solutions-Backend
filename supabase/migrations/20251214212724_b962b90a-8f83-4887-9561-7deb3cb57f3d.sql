-- Ajouter des catégories supplémentaires
INSERT INTO categories (name, description, is_active) 
SELECT name, description, is_active FROM (VALUES 
  ('Automobile', 'Pièces et accessoires automobile', true),
  ('Téléphonie', 'Téléphones et accessoires', true),
  ('Informatique', 'Ordinateurs et périphériques', true),
  ('Jardinage', 'Outils et équipements de jardin', true),
  ('Bébé & Enfant', 'Articles pour bébés et enfants', true),
  ('Bijoux & Montres', 'Bijoux et montres', true),
  ('Livres & Papeterie', 'Livres, fournitures scolaires', true),
  ('Musique & Instruments', 'Instruments de musique', true),
  ('Animalerie', 'Produits pour animaux', true),
  ('Bricolage', 'Outils et matériaux de bricolage', true),
  ('Gaming', 'Jeux vidéo et consoles', true),
  ('Cosmétiques', 'Maquillage et soins', true),
  ('Chaussures', 'Chaussures homme, femme, enfant', true),
  ('Sacs & Bagages', 'Sacs, valises et accessoires', true),
  ('Montres & Accessoires', 'Montres et accessoires mode', true),
  ('Épicerie', 'Produits d''épicerie et conserves', true),
  ('Boissons', 'Boissons et rafraîchissements', true),
  ('Électronique', 'Appareils électroniques', true),
  ('Photo & Vidéo', 'Appareils photo et caméras', true),
  ('Audio', 'Casques, enceintes, audio', true)
) AS t(name, description, is_active)
WHERE NOT EXISTS (SELECT 1 FROM categories c WHERE c.name = t.name);