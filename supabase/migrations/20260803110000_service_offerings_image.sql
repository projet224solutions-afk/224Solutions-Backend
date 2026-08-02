-- PRESTATIONS — image de couverture de la prestation.
-- Distincte du logo/photo de profil du PRESTATAIRE (professional_services) : ici c'est le VISUEL
-- du service proposé (ex. « site vitrine », « dépannage PC »). Optionnelle → placeholder par
-- catégorie côté UI si absente (jamais de carré cassé).
ALTER TABLE public.service_offerings ADD COLUMN IF NOT EXISTS image_url text;
COMMENT ON COLUMN public.service_offerings.image_url IS
  'Image de couverture de la prestation (visuel du service proposé), distincte du logo/profil du prestataire.';
