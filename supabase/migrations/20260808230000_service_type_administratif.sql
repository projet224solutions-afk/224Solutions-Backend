-- ============================================================================
-- 🗂️ TYPE DE SERVICE « ADMINISTRATIF »
-- ----------------------------------------------------------------------------
-- CONSTAT (audit 08/08/2026) : « Administratif » figure dans la liste des métiers
-- du PDG, mais AUCUN type de service ne le porte en base. Les fiches concernées
-- tombaient sur `freelance` (« Services Professionnels »), dont le jeu de
-- prestations MÉLANGE démarches administratives, comptabilité, conseil juridique
-- et étude de marché.
--
-- Règle PDG : un jeu ne sert jamais deux métiers distincts. « Administratif » et
-- « Services Professionnels » en SONT deux : un secrétaire public qui monte des
-- dossiers de passeport ne fait pas de conseil juridique, et inversement.
--
-- On CRÉE donc le type, plutôt que de détourner `freelance` — ce qui aurait privé
-- les prestataires professionnels de leur propre jeu pour en servir un autre.
--
-- commission_rate 0 : règle « prestations = 0 commission » (le prestataire
-- encaisse 100 %), comme les autres métiers de service.
-- Idempotent.
-- ============================================================================

INSERT INTO public.service_types (code, name, description, icon, category, is_active, commission_rate)
VALUES ('administratif', 'Administratif',
        'Démarches administratives, documents officiels, formalités d''entreprise.',
        '🗂️', 'Professionnel', true, 0)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, description = EXCLUDED.description,
      icon = EXCLUDED.icon, category = EXCLUDED.category, is_active = true;

SELECT 'Type de service administratif créé — jeu de prestations dédié côté front.' AS status;
