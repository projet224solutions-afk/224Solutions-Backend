-- ============================================================================
-- 🌱 SEED DE CHARGE — STAGING UNIQUEMENT
-- ----------------------------------------------------------------------------
-- Génère un volume RÉALISTE pour que le tir k6 mesure quelque chose de vrai.
-- Sur les 69 profils actuels, tout répond en quelques millisecondes et le
-- chiffre obtenu serait faussement rassurant — c'est le pire résultat possible
-- avant un lancement.
--
-- ⛔ GARDE ABSOLUE — À LIRE AVANT TOUT
-- Ce script REFUSE de s'exécuter si le projet n'est pas explicitement déclaré
-- comme staging ci-dessous. La liste blanche est VIDE par défaut : tant que
-- vous n'y avez pas mis le ref de VOTRE staging, le script échoue. C'est
-- volontaire — un défaut permissif finirait un jour par injecter 10 000 faux
-- profils en production.
--
-- ⚠️ Le ref de PRODUCTION est `uakkxaibujzxdiqzpnpr` : ne l'ajoutez JAMAIS.
--
-- TRAÇABILITÉ : toute ligne créée porte `metadata->>'synthetic' = 'true'` ou un
-- identifiant préfixé `SEED-`. La purge tient en une commande (voir la fin).
--
-- IDEMPOTENT : un second passage ne double rien (tout est conditionné à
-- l'absence de la ligne SEED- correspondante).
-- ============================================================================

DO $$
DECLARE
  v_ref text;
  -- 👉 METTEZ ICI le ref de votre projet STAGING, et lui seul.
  --    Exemple : v_staging_refs text[] := ARRAY['abcdefghijklmnop'];
  v_staging_refs text[] := ARRAY[]::text[];
BEGIN
  -- Le ref du projet Supabase se lit dans le nom d'hôte de la base.
  SELECT COALESCE(current_setting('app.settings.project_ref', true),
                  split_part(COALESCE(current_setting('request.headers', true), ''), '"', 1))
    INTO v_ref;

  IF array_length(v_staging_refs, 1) IS NULL THEN
    RAISE EXCEPTION
      'SEED REFUSÉ : aucune liste blanche staging configurée. Éditez v_staging_refs '
      'en haut de ce fichier avec le ref de VOTRE staging. Ne jamais y mettre la production.';
  END IF;

  -- Ceinture ET bretelles : on refuse explicitement le ref de production, même
  -- si quelqu'un l'ajoutait par erreur à la liste blanche.
  IF 'uakkxaibujzxdiqzpnpr' = ANY(v_staging_refs) THEN
    RAISE EXCEPTION 'SEED REFUSÉ : le ref de PRODUCTION figure dans la liste blanche.';
  END IF;

  -- Garde de dernier recours : si des données réelles existent (wallets avec
  -- un solde non nul appartenant à des comptes non synthétiques), on s'arrête.
  IF EXISTS (
    SELECT 1 FROM public.wallets w
    JOIN public.profiles p ON p.id = w.user_id
    WHERE w.balance > 0 AND COALESCE(p.public_id, '') NOT LIKE 'SEED-%'
    LIMIT 1
  ) THEN
    RAISE EXCEPTION
      'SEED REFUSÉ : des wallets NON synthétiques ont un solde positif. '
      'Cette base contient des données réelles — ce n''est pas un staging vierge.';
  END IF;

  RAISE NOTICE 'Garde franchie : projet reconnu comme staging.';
END $$;

-- ============================================================================
-- À PARTIR D'ICI : la génération. Elle ne s'exécute QUE si la garde a passé
-- (le RAISE EXCEPTION ci-dessus annule toute la transaction sinon).
-- ============================================================================

-- ── 1) PROFILS — 10 000, distribution réaliste ─────────────────────────────
-- 70 % clients · 20 % prestataires · 5 % vendeurs · 5 % agents/livreurs/transitaires.
-- Les pays suivent la réalité du marché : Guinée dominante, puis la sous-région.
INSERT INTO public.profiles (id, email, first_name, last_name, role, public_id, country, country_code, city)
SELECT
  gen_random_uuid(),
  'seed' || i || '@staging.local',
  'Prenom' || i,
  'Nom' || i,
  (CASE
     WHEN i % 100 < 70 THEN 'client'
     WHEN i % 100 < 90 THEN 'prestataire'
     WHEN i % 100 < 95 THEN 'vendeur'
     WHEN i % 100 < 97 THEN 'agent'
     WHEN i % 100 < 99 THEN 'livreur'
     ELSE 'transitaire' END)::text,
  'SEED-' || lpad(i::text, 6, '0'),
  (CASE WHEN i % 100 < 85 THEN 'GN' WHEN i % 100 < 92 THEN 'SN'
        WHEN i % 100 < 96 THEN 'SL' WHEN i % 100 < 98 THEN 'ML' ELSE 'FR' END),
  (CASE WHEN i % 100 < 85 THEN 'GN' WHEN i % 100 < 92 THEN 'SN'
        WHEN i % 100 < 96 THEN 'SL' WHEN i % 100 < 98 THEN 'ML' ELSE 'FR' END),
  -- Villes guinéennes pondérées : Conakry écrase le reste, comme dans la réalité.
  (CASE WHEN i % 100 < 60 THEN 'Conakry' WHEN i % 100 < 72 THEN 'Kankan'
        WHEN i % 100 < 82 THEN 'Nzérékoré' WHEN i % 100 < 90 THEN 'Kindia'
        ELSE 'Labé' END)
FROM generate_series(1, 10000) i
WHERE NOT EXISTS (SELECT 1 FROM public.profiles WHERE public_id = 'SEED-' || lpad(i::text, 6, '0'));

-- Les wallets suivent le verrou devise-par-pays existant : le trigger
-- wallet_set_country_currency impose la bonne devise, on ne la force pas ici.
INSERT INTO public.wallets (user_id, balance, currency, wallet_status)
SELECT p.id, (random() * 5000000)::numeric(18,2), 'GNF', 'active'
FROM public.profiles p
WHERE p.public_id LIKE 'SEED-%'
  AND NOT EXISTS (SELECT 1 FROM public.wallets w WHERE w.user_id = p.id);

-- ── 2) FICHES PRESTATAIRES — 2 000, réparties sur les métiers réels ────────
INSERT INTO public.professional_services
  (user_id, service_type_id, business_name, description, city, country, status, verification_status, latitude, longitude)
SELECT
  p.id,
  (SELECT id FROM public.service_types WHERE is_active
    ORDER BY md5(p.id::text || code) LIMIT 1),   -- répartition pseudo-aléatoire STABLE
  'SEED Entreprise ' || p.public_id,
  'Fiche synthétique de test de charge.',
  p.city, p.country, 'active', 'unverified',
  -- GPS plausibles autour de Conakry (±0,15°), pour que les requêtes par rayon travaillent.
  9.6412 + (random() - 0.5) * 0.3,
  -13.5784 + (random() - 0.5) * 0.3
FROM public.profiles p
WHERE p.public_id LIKE 'SEED-%' AND p.role::text = 'prestataire'
  AND NOT EXISTS (SELECT 1 FROM public.professional_services ps WHERE ps.user_id = p.id)
LIMIT 2000;

-- ── 3) PRESTATIONS — 8 000, 4 par fiche en moyenne ────────────────────────
INSERT INTO public.service_offerings
  (service_id, title, description, base_price, price_type, unit, is_active, currency)
SELECT ps.id,
       'SEED Prestation ' || n || ' — ' || left(ps.business_name, 20),
       'Prestation synthétique pour test de charge.',
       (50000 + (random() * 2000000))::numeric(18,2),
       (CASE WHEN n % 4 = 0 THEN 'quote' WHEN n % 3 = 0 THEN 'from' ELSE 'fixed' END),
       'forfait', true, 'GNF'
FROM public.professional_services ps
CROSS JOIN generate_series(1, 4) n
WHERE ps.business_name LIKE 'SEED %'
  AND NOT EXISTS (
    SELECT 1 FROM public.service_offerings so
    WHERE so.service_id = ps.id AND so.title LIKE 'SEED Prestation ' || n || '%');

SELECT 'SEED terminé' AS statut,
       (SELECT count(*) FROM public.profiles WHERE public_id LIKE 'SEED-%')            AS profils,
       (SELECT count(*) FROM public.professional_services WHERE business_name LIKE 'SEED %') AS fiches,
       (SELECT count(*) FROM public.service_offerings WHERE title LIKE 'SEED Prestation%')   AS prestations;

-- ============================================================================
-- PURGE (une seule commande, à lancer sur le MÊME staging) :
--
--   DELETE FROM public.service_offerings WHERE title LIKE 'SEED Prestation%';
--   DELETE FROM public.professional_services WHERE business_name LIKE 'SEED %';
--   DELETE FROM public.wallets WHERE user_id IN
--     (SELECT id FROM public.profiles WHERE public_id LIKE 'SEED-%');
--   DELETE FROM public.profiles WHERE public_id LIKE 'SEED-%';
--
-- L'ordre compte : les dépendances d'abord.
-- ============================================================================
