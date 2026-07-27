-- ============================================================================
-- Garde DB « pays du vendeur » + rattrapage — répare la régression de
-- 20260724190000 (retrait du DEFAULT 'Guinée' sans remplacement → toute boutique
-- créée depuis le 24/07 a country/country_code NULL, donc pas de drapeau).
-- ============================================================================
-- Le correctif PRINCIPAL est le déclencheur (BLOC 1) : l'invariant « country_code
-- toujours renseigné et cohérent avec country » est garanti par la BASE, quelle
-- que soit la porte d'entrée (4 chemins applicatifs aujourd'hui, un 5e demain).
--
-- On NE remet PAS un DEFAULT 'Guinée' (c'est exactement ce que la normalisation a
-- voulu supprimer : du texte libre non contrôlé). On dérive proprement depuis le
-- référentiel `countries`, le profil du propriétaire, puis l'indicatif du téléphone.
--
-- Réutilise l'existant : public.iso_from_phone() (indicatif → ISO-2, migration
-- 20260721090000) et le motif de comparaison insensible casse/accents de la RPC
-- marketplace_certified_suppliers v2 (extensions.unaccent).
-- Idempotent : CREATE OR REPLACE + DROP TRIGGER IF EXISTS + backfill gardé sur NULL.
-- ============================================================================

-- ── BLOC 1 : déclencheur BEFORE INSERT OR UPDATE ────────────────────────────
-- SECURITY DEFINER : lit public.profiles (RLS) pour déduire le pays du propriétaire.
-- Fonction retournant `trigger` → NON exposée par PostgREST (pas d'endpoint RPC).
CREATE OR REPLACE FUNCTION public.vendors_fill_country()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_code         text;
  v_name         text;
  v_prof_cc      text;
  v_prof_country text;
  v_prof_phone   text;
  v_used_default boolean := false;
BEGIN
  NEW.country_code := NULLIF(upper(btrim(NEW.country_code)), '');
  NEW.country      := NULLIF(btrim(NEW.country), '');

  -- 1) country_code fourni → renseigne/aligne country depuis le référentiel.
  IF NEW.country_code IS NOT NULL THEN
    SELECT c.country_code, c.country_name INTO v_code, v_name
    FROM public.countries c WHERE c.country_code = NEW.country_code;
    IF v_code IS NULL THEN
      RAISE EXCEPTION 'vendors.country_code % inconnu du référentiel public.countries', NEW.country_code
        USING ERRCODE = '23503';
    END IF;
    NEW.country_code := v_code;
    NEW.country      := v_name;
    RETURN NEW;
  END IF;

  -- 2) seul country (nom OU code) fourni → dérive country_code (insensible casse/accents,
  --    égalité EXACTE sur le nom → « Guinée » ne matche QUE GN, jamais « Guinée-Bissau »).
  IF NEW.country IS NOT NULL THEN
    SELECT c.country_code, c.country_name INTO v_code, v_name
    FROM public.countries c
    WHERE upper(btrim(NEW.country)) = c.country_code
       OR extensions.unaccent(lower(btrim(NEW.country))) = extensions.unaccent(lower(c.country_name))
    ORDER BY (upper(btrim(NEW.country)) = c.country_code) DESC
    LIMIT 1;
    IF v_code IS NOT NULL THEN
      NEW.country_code := v_code;
      NEW.country      := v_name;
      RETURN NEW;
    END IF;
    -- nom non reconnu → on ne l'invente pas : on continue la cascade (sans écraser la saisie).
  END IF;

  -- 3) Ni l'un ni l'autre exploitable → déduire du propriétaire.
  SELECT p.country_code, p.country, COALESCE(p.phone_e164, p.phone)
    INTO v_prof_cc, v_prof_country, v_prof_phone
  FROM public.profiles p WHERE p.id = NEW.user_id;

  -- 3a) profiles.country_code (déjà ISO référentiel).
  IF v_prof_cc IS NOT NULL THEN
    SELECT c.country_code, c.country_name INTO v_code, v_name
    FROM public.countries c WHERE c.country_code = upper(btrim(v_prof_cc));
  END IF;

  -- 3b) profiles.country (ISO ou nom).
  IF v_code IS NULL AND v_prof_country IS NOT NULL THEN
    SELECT c.country_code, c.country_name INTO v_code, v_name
    FROM public.countries c
    WHERE upper(btrim(v_prof_country)) = c.country_code
       OR extensions.unaccent(lower(btrim(v_prof_country))) = extensions.unaccent(lower(c.country_name))
    ORDER BY (upper(btrim(v_prof_country)) = c.country_code) DESC
    LIMIT 1;
  END IF;

  -- 3c) indicatif du téléphone du propriétaire, puis celui de la boutique.
  IF v_code IS NULL THEN
    v_code := COALESCE(public.iso_from_phone(v_prof_phone), public.iso_from_phone(NEW.phone));
    IF v_code IS NOT NULL THEN
      SELECT c.country_name INTO v_name FROM public.countries c WHERE c.country_code = v_code;
    END IF;
  END IF;

  -- 3d) dernier repli : GN (journalisé — voir BLOC 4 du rapport).
  IF v_code IS NULL THEN
    v_code := 'GN';
    SELECT c.country_name INTO v_name FROM public.countries c WHERE c.country_code = 'GN';
    v_used_default := true;
  END IF;

  NEW.country_code := v_code;
  NEW.country      := v_name;

  IF v_used_default THEN
    -- Si ce log apparaît souvent : le parcours d'inscription ne demande pas le pays (cause de fond).
    RAISE LOG '[vendors_fill_country] REPLI GN par défaut — vendor % (user %) : pays non fourni ni déductible (profil/tél).',
      NEW.id, NEW.user_id;
  END IF;

  RETURN NEW;
END;
$$;

-- Non appelable hors contexte trigger ; on retire tout droit d'exécution résiduel par prudence.
REVOKE ALL ON FUNCTION public.vendors_fill_country() FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_vendors_fill_country ON public.vendors;
CREATE TRIGGER trg_vendors_fill_country
  BEFORE INSERT OR UPDATE OF country, country_code ON public.vendors
  FOR EACH ROW EXECUTE FUNCTION public.vendors_fill_country();

-- ── BLOC 2 : rattrapage des boutiques déjà créées (country_code NULL) ────────
-- Même cascade que le déclencheur. On journalise le split sûr / repli-GN.
DO $$
DECLARE
  v_sure    int;
  v_default int;
BEGIN
  WITH resolved AS (
    SELECT v.id,
      COALESCE(
        (SELECT c.country_code FROM public.countries c WHERE c.country_code = upper(btrim(p.country_code))),
        (SELECT c.country_code FROM public.countries c
           WHERE upper(btrim(p.country)) = c.country_code
              OR extensions.unaccent(lower(btrim(p.country))) = extensions.unaccent(lower(c.country_name))
           ORDER BY (upper(btrim(p.country)) = c.country_code) DESC LIMIT 1),
        public.iso_from_phone(COALESCE(p.phone_e164, p.phone)),
        public.iso_from_phone(v.phone)
      ) AS sure_code
    FROM public.vendors v
    LEFT JOIN public.profiles p ON p.id = v.user_id
    WHERE v.country_code IS NULL
  )
  SELECT count(*) FILTER (WHERE sure_code IS NOT NULL),
         count(*) FILTER (WHERE sure_code IS NULL)
    INTO v_sure, v_default
  FROM resolved;

  -- Rattrapage SÛR (pays connu du profil/tél).
  UPDATE public.vendors v
  SET country_code = r.sure_code,
      country      = (SELECT c.country_name FROM public.countries c WHERE c.country_code = r.sure_code)
  FROM (
    SELECT v2.id,
      COALESCE(
        (SELECT c.country_code FROM public.countries c WHERE c.country_code = upper(btrim(p.country_code))),
        (SELECT c.country_code FROM public.countries c
           WHERE upper(btrim(p.country)) = c.country_code
              OR extensions.unaccent(lower(btrim(p.country))) = extensions.unaccent(lower(c.country_name))
           ORDER BY (upper(btrim(p.country)) = c.country_code) DESC LIMIT 1),
        public.iso_from_phone(COALESCE(p.phone_e164, p.phone)),
        public.iso_from_phone(v2.phone)
      ) AS sure_code
    FROM public.vendors v2
    LEFT JOIN public.profiles p ON p.id = v2.user_id
    WHERE v2.country_code IS NULL
  ) r
  WHERE v.id = r.id AND r.sure_code IS NOT NULL;

  -- Repli GN par défaut (aucun signal exploitable). Les boutiques manifestement
  -- étrangères (indicatif/nom hors GN) auraient déjà été captées en amont → si une
  -- ligne atterrit ici, c'est qu'aucune donnée pays n'existe (pas « étrangère connue »).
  UPDATE public.vendors SET country_code = 'GN', country = 'Guinée'
  WHERE country_code IS NULL;

  RAISE NOTICE '[backfill vendors.country_code] rattrapage sûr = %, repli GN par défaut = %', v_sure, v_default;
END $$;

-- ── BLOC 4 : verrou anti-retour — NOT NULL UNIQUEMENT si zéro ligne nulle ────
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.vendors WHERE country_code IS NULL) THEN
    ALTER TABLE public.vendors ALTER COLUMN country_code SET NOT NULL;
    RAISE NOTICE '[vendors.country_code] NOT NULL posé (0 ligne nulle).';
  ELSE
    RAISE WARNING '[vendors.country_code] NOT NULL NON posé : lignes encore nulles → rattrapage incomplet, arbitrage requis.';
  END IF;
END $$;
