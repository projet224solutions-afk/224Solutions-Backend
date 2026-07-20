-- ============================================================================
-- UN NUMÉRO = UN SEUL COMPTE — canonicalisation E.164 + unicité blindée.
-- Constat audit : l'unicité est DÉJÀ garantie par uq_profiles_phone_norm9
-- (unique sur les 9 derniers chiffres). Cette migration AJOUTE la canonicalisation
-- E.164 explicite demandée (normalize_phone + profiles.phone_e164 + index unique),
-- sans rien casser de l'existant. 0 doublon actuel → backfill & index sans conflit.
-- ============================================================================

-- 1) normalize_phone(text, default_country) → E.164 (+224624039029). IMMUTABLE (pur).
CREATE OR REPLACE FUNCTION public.normalize_phone(p text, default_country text DEFAULT 'GN')
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE d text; cc text;
BEGIN
  d := regexp_replace(COALESCE(p, ''), '[^0-9]', '', 'g');
  IF d = '' THEN RETURN NULL; END IF;

  -- Indicatif du pays par défaut (extensible : une ligne suffit).
  cc := CASE upper(COALESCE(default_country, 'GN'))
    WHEN 'GN' THEN '224' WHEN 'SN' THEN '221' WHEN 'ML' THEN '223' WHEN 'CI' THEN '225'
    WHEN 'BF' THEN '226' WHEN 'BJ' THEN '229' WHEN 'TG' THEN '228' WHEN 'NE' THEN '227'
    WHEN 'CM' THEN '237' WHEN 'CD' THEN '243' WHEN 'GW' THEN '245' WHEN 'MA' THEN '212'
    WHEN 'TN' THEN '216' WHEN 'EG' THEN '20'  WHEN 'JO' THEN '962'
    ELSE '224' END;

  -- 00XXXX (préfixe international) → +XXXX
  IF left(d, 2) = '00' THEN
    d := substring(d from 3);
    RETURN CASE WHEN length(d) >= 8 THEN '+' || d ELSE NULL END;
  END IF;

  -- Déjà préfixé de l'indicatif par défaut (cc + 8..9 chiffres) → +cc...
  IF left(d, length(cc)) = cc AND length(d) BETWEEN length(cc) + 8 AND length(cc) + 9 THEN
    RETURN '+' || d;
  END IF;

  -- Local avec 0 en tête (0XXXXXXXX) → retirer le 0.
  IF left(d, 1) = '0' THEN d := substring(d from 2); END IF;

  -- Local pur (8..9 chiffres) → ajouter l'indicatif du pays par défaut.
  IF length(d) BETWEEN 8 AND 9 THEN RETURN '+' || cc || d; END IF;

  -- Déjà international plausible (autre pays, ≥ 11 chiffres).
  IF length(d) >= 11 THEN RETURN '+' || d; END IF;

  RETURN NULL; -- trop court / invalide → refus propre
END $$;
COMMENT ON FUNCTION public.normalize_phone(text, text) IS 'Numéro brut → E.164 (défaut +224). NULL si invalide.';

-- 2) Colonne canonique + trigger de maintenance (c'est ELLE qui porte l'unicité E.164).
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS phone_e164 text;

CREATE OR REPLACE FUNCTION public.tg_profiles_phone_e164()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.phone_e164 := public.normalize_phone(NEW.phone, 'GN');
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_profiles_phone_e164 ON public.profiles;
CREATE TRIGGER trg_profiles_phone_e164
  BEFORE INSERT OR UPDATE OF phone ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.tg_profiles_phone_e164();

-- 3) Backfill de l'existant.
UPDATE public.profiles
SET phone_e164 = public.normalize_phone(phone, 'GN')
WHERE phone IS NOT NULL AND btrim(phone) <> '';

-- 4) INDEX UNIQUE E.164 (filet ultime, en plus du norm9 existant).
CREATE UNIQUE INDEX IF NOT EXISTS uq_profiles_phone_e164
  ON public.profiles (phone_e164)
  WHERE phone_e164 IS NOT NULL;

-- 5) Clôture des revues de doublons PÉRIMÉES (chacune n'a plus qu'≤1 profil réel :
--    l'unicité a déjà été rétablie). On ne touche qu'aux 'pending' devenues sans objet.
UPDATE public.phone_duplicates_review r
SET status = 'resolved',
    resolution_notes = COALESCE(r.resolution_notes, '') ||
      ' [auto-résolu 2026-07-20 : unicité rétablie (uq_profiles_phone_norm9), 1 seul profil porte ce numéro]',
    resolved_at = now()
WHERE r.status = 'pending'
  AND (SELECT count(*) FROM public.profiles p
       WHERE right(regexp_replace(COALESCE(p.phone, ''), '[^0-9]', '', 'g'), 9) = r.phone_norm9) <= 1;
