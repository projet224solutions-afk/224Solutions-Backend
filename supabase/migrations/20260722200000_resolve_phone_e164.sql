-- 20260722200000_resolve_phone_e164.sql
-- 🔴 « Ce numéro n'est lié à aucun compte » — UNE seule forme canonique : phone_e164.
--
-- Constat d'audit (prod 22/07) :
--   * resolve_user_id_by_phone comparait les 9 DERNIERS CHIFFRES de profiles.phone —
--     ambigu multi-pays (+224624039029 GN et +221624039029 SN = mêmes 9 chiffres → le
--     plus ancien gagnait, potentiellement le MAUVAIS compte).
--   * Les 20 profils à téléphone ont TOUS phone_e164 déjà rempli (backfill 20260720210000)
--     → 0 profil à corriger ; 28 comptes sans téléphone (parcours email seulement).
--   * La vraie panne du reset PDG : l'Edge `phone-send-otp` (recherche par égalité stricte
--     de formats + Twilio direct) — remplacée côté Node par la passerelle ; cette migration
--     fournit la recherche canonique unique.
--
-- Fin de la canonicalisation « 9 derniers chiffres » : recherche = normalisation E.164
-- (pays du contexte) PUIS égalité stricte sur phone_e164. Tolérante à la saisie :
-- 624039029 / 0624039029 / +224 624 03 90 29 / 00224624039029 → même résultat.

-- 1) Filet idempotent (0 ligne attendue — déjà backfillé) : phone → phone_e164 manquant
UPDATE public.profiles
   SET phone_e164 = public.normalize_phone(phone, COALESCE(country_code, detected_country, country, 'GN'))
 WHERE phone IS NOT NULL AND TRIM(phone) <> ''
   AND (phone_e164 IS NULL OR TRIM(phone_e164) = '');

-- 2) Résolution CANONIQUE (remplace la version 9-chiffres ; signature étendue avec pays)
DROP FUNCTION IF EXISTS public.resolve_user_id_by_phone(text);
CREATE OR REPLACE FUNCTION public.resolve_user_id_by_phone(p_phone text, p_country text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_raw    text := COALESCE(p_phone, '');
  v_digits text := regexp_replace(v_raw, '[^0-9]', '', 'g');
  v_e164   text;
  v_id     uuid;
BEGIN
  IF length(v_digits) < 8 THEN RETURN NULL; END IF;

  -- Normalisation avec le pays du contexte (défaut GN) — jamais de format imposé à l'utilisateur.
  v_e164 := public.normalize_phone(v_raw, COALESCE(NULLIF(TRIM(p_country), ''), 'GN'));
  SELECT id INTO v_id FROM public.profiles
   WHERE phone_e164 IS NOT NULL
     AND regexp_replace(phone_e164, '[^0-9]', '', 'g') = regexp_replace(v_e164, '[^0-9]', '', 'g')
   ORDER BY created_at ASC LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- 2e chance : zéro « trunk » en tête de saisie locale (0624… → 624…)
  IF v_raw !~ '^\+' AND v_digits ~ '^0' THEN
    v_e164 := public.normalize_phone(regexp_replace(v_digits, '^0+', ''), COALESCE(NULLIF(TRIM(p_country), ''), 'GN'));
    SELECT id INTO v_id FROM public.profiles
     WHERE phone_e164 IS NOT NULL
       AND regexp_replace(phone_e164, '[^0-9]', '', 'g') = regexp_replace(v_e164, '[^0-9]', '', 'g')
     ORDER BY created_at ASC LIMIT 1;
  END IF;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_user_id_by_phone(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_user_id_by_phone(text, text) TO service_role;

-- 3) Dernier vestige « 9 chiffres » : l'index de recherche par suffixe n'est plus utilisé
DROP INDEX IF EXISTS public.idx_profiles_phone_norm9;
