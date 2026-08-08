-- ============================================================================
-- 🚢 TRANSITAIRE → ÉCOSYSTÈME PROXIMITÉ : le pont UNIQUE
-- ----------------------------------------------------------------------------
-- CONSTAT (audit 08/08/2026) : le transitaire est un SILO. Aucune fiche
-- `professional_services`, donc : pas d'abonnement, pas de prestations, pas de
-- vitrine, invisible sur la page Proximité. Son ERP (dossiers TRS, devis
-- tarifaires, cashbox) fonctionne mais ne le relie à rien.
--
-- DÉCISION D'ARCHITECTURE : on ne duplique RIEN. Chaque transitaire reçoit sa
-- fiche `professional_services` et HÉRITE mécaniquement de tout l'écosystème
-- (abonnement CEDEAO, visibilité proximité, prestations, vitrine). Son ERP reste
-- son espace principal — les deux coexistent sans se marcher dessus.
--
-- ⚠️ CORRECTION D'UNE PRÉMISSE DE LA MISSION : il n'existe AUCUNE table
-- `transitaires` en base. Un transitaire est identifié par `profiles.role =
-- 'transitaire'` (1 en production à ce jour). Le backfill et le hook d'inscription
-- s'appuient donc sur `profiles`, pas sur une table qui n'existe pas.
--
-- SENS DU LIEN : `professional_services.user_id` → `profiles.id`. C'est le lien,
-- il existe déjà. Ajouter une colonne `professional_service_id` sur un côté ou
-- l'autre créerait une 2e vérité à maintenir synchrone pour zéro gain : la fiche
-- d'un transitaire se retrouve par (user_id, service_type='transitaire').
-- ============================================================================

-- ── 1) Le type de service ──────────────────────────────────────────────────
-- commission_rate 0 : cohérent avec la règle « prestations = 0 commission »
-- (le prestataire encaisse 100 %). Le code est la source de vérité côté front
-- (src/config/serviceTypesConfig.ts).
INSERT INTO public.service_types (code, name, description, icon, category, is_active, commission_rate)
VALUES ('transitaire', 'Transitaire / Logistique internationale',
        'Dédouanement, fret maritime et aérien, groupage, transit inter-États, entreposage.',
        '🚢', 'logistique', true, 0)
ON CONFLICT (code) DO UPDATE
  SET name = EXCLUDED.name, description = EXCLUDED.description,
      icon = EXCLUDED.icon, category = EXCLUDED.category, is_active = true;

-- ── 2) Backfill IDEMPOTENT ─────────────────────────────────────────────────
-- Idempotence par (user_id, service_type_id) : le NOT EXISTS garantit qu'un
-- re-run ne crée aucun doublon. Volontairement PAS de contrainte UNIQUE ajoutée
-- ici : un utilisateur peut légitimement détenir plusieurs fiches d'un même type
-- dans le modèle actuel (multi-boutiques), et l'imposer casserait ce cas.
CREATE OR REPLACE FUNCTION public.backfill_transitaire_services()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_type uuid; v_crees int := 0; v_total int;
BEGIN
  SELECT id INTO v_type FROM public.service_types WHERE code = 'transitaire';
  IF v_type IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'service_type transitaire absent');
  END IF;

  SELECT count(*) INTO v_total FROM public.profiles WHERE role::text = 'transitaire';

  WITH inseres AS (
    INSERT INTO public.professional_services
      (user_id, service_type_id, business_name, description, phone, email,
       city, country, status, verification_status)
    SELECT
      p.id, v_type,
      -- Nom d'enseigne lisible : on ne laisse jamais un champ obligatoire vide.
      COALESCE(NULLIF(btrim(COALESCE(p.first_name,'') || ' ' || COALESCE(p.last_name,'')), ''),
               'Transit ' || COALESCE(p.public_id, left(p.id::text, 8))),
      'Transit international, dédouanement et fret.',
      p.phone, p.email, p.city, p.country,
      'active', 'unverified'
    FROM public.profiles p
    WHERE p.role::text = 'transitaire'
      AND NOT EXISTS (
        SELECT 1 FROM public.professional_services ps
        WHERE ps.user_id = p.id AND ps.service_type_id = v_type)
    RETURNING 1)
  SELECT count(*) INTO v_crees FROM inseres;

  RETURN jsonb_build_object('success', true, 'transitaires', v_total, 'fiches_creees', v_crees);
END; $$;

REVOKE ALL ON FUNCTION public.backfill_transitaire_services() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.backfill_transitaire_services() TO service_role;

-- ── 3) À L'INSCRIPTION : la fiche naît avec le transitaire ─────────────────
-- Trigger sur profiles : couvre l'inscription ET la promotion d'un compte
-- existant au rôle transitaire. Best-effort explicite (WARNING, pas RAISE) :
-- une fiche manquante ne doit jamais empêcher quelqu'un de s'inscrire — le
-- backfill, idempotent, rattrapera le cas au prochain passage.
CREATE OR REPLACE FUNCTION public.ensure_transitaire_service()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_type uuid;
BEGIN
  IF NEW.role::text <> 'transitaire' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.role::text = 'transitaire' THEN RETURN NEW; END IF;

  SELECT id INTO v_type FROM public.service_types WHERE code = 'transitaire';
  IF v_type IS NULL THEN RETURN NEW; END IF;

  INSERT INTO public.professional_services
    (user_id, service_type_id, business_name, description, phone, email, city, country, status, verification_status)
  SELECT NEW.id, v_type,
    COALESCE(NULLIF(btrim(COALESCE(NEW.first_name,'') || ' ' || COALESCE(NEW.last_name,'')), ''),
             'Transit ' || COALESCE(NEW.public_id, left(NEW.id::text, 8))),
    'Transit international, dédouanement et fret.',
    NEW.phone, NEW.email, NEW.city, NEW.country, 'active', 'unverified'
  WHERE NOT EXISTS (
    SELECT 1 FROM public.professional_services ps
    WHERE ps.user_id = NEW.id AND ps.service_type_id = v_type);

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '[ensure_transitaire_service] % (profil %)', SQLERRM, NEW.id;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_ensure_transitaire_service ON public.profiles;
CREATE TRIGGER trg_ensure_transitaire_service
  AFTER INSERT OR UPDATE OF role ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.ensure_transitaire_service();

SELECT 'service_types transitaire + backfill idempotent + trigger d''inscription en place.' AS status;
