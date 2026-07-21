-- ============================================================================
-- normalize_phone — CASE indicatif ÉTENDU (audit inscription multi-pays).
-- Constat : le CASE ne couvrait que 15 pays (GN/SN/ML/CI/BF/BJ/TG/NE/CM/CD/GW/
-- MA/TN/EG/JO) → un numéro LOCAL (sans indicatif) d'un autre pays (NG/FR/US…)
-- retombait sur '224' (Guinée) = E.164 faux. Bug LATENT (l'UI envoie déjà l'E.164
-- complet, préservé par la branche « ≥ 11 chiffres »), corrigé ici par robustesse.
-- Additif : même signature, même volatilité IMMUTABLE, seul le CASE s'élargit.
-- ✅ APPLIQUÉE EN PROD le 2026-07-21 (preuve ROLLBACK : FR '612345678'→+33612345678,
--    SN→+221771234567, E.164 +234… préservé, GN par défaut inchangé).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.normalize_phone(p text, default_country text DEFAULT 'GN')
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE d text; cc text;
BEGIN
  d := regexp_replace(COALESCE(p, ''), '[^0-9]', '', 'g');
  IF d = '' THEN RETURN NULL; END IF;

  -- Indicatif du pays par défaut (Afrique de l'Ouest/Centrale + diaspora courante).
  cc := CASE upper(COALESCE(default_country, 'GN'))
    -- Afrique de l'Ouest / Centrale
    WHEN 'GN' THEN '224' WHEN 'SN' THEN '221' WHEN 'ML' THEN '223' WHEN 'CI' THEN '225'
    WHEN 'BF' THEN '226' WHEN 'BJ' THEN '229' WHEN 'TG' THEN '228' WHEN 'NE' THEN '227'
    WHEN 'CM' THEN '237' WHEN 'CD' THEN '243' WHEN 'GW' THEN '245' WHEN 'NG' THEN '234'
    WHEN 'GH' THEN '233' WHEN 'LR' THEN '231' WHEN 'SL' THEN '232' WHEN 'GM' THEN '220'
    WHEN 'MR' THEN '222' WHEN 'GA' THEN '241' WHEN 'TD' THEN '235' WHEN 'CF' THEN '236'
    WHEN 'CG' THEN '242' WHEN 'GQ' THEN '240' WHEN 'AO' THEN '244' WHEN 'CV' THEN '238'
    -- Afrique du Nord / Est / Sud
    WHEN 'MA' THEN '212' WHEN 'TN' THEN '216' WHEN 'DZ' THEN '213' WHEN 'EG' THEN '20'
    WHEN 'LY' THEN '218' WHEN 'KE' THEN '254' WHEN 'TZ' THEN '255' WHEN 'UG' THEN '256'
    WHEN 'RW' THEN '250' WHEN 'ET' THEN '251' WHEN 'ZA' THEN '27'  WHEN 'ZM' THEN '260'
    -- Diaspora / international courant
    WHEN 'FR' THEN '33'  WHEN 'US' THEN '1'   WHEN 'CA' THEN '1'   WHEN 'GB' THEN '44'
    WHEN 'BE' THEN '32'  WHEN 'DE' THEN '49'  WHEN 'ES' THEN '34'  WHEN 'IT' THEN '39'
    WHEN 'PT' THEN '351' WHEN 'NL' THEN '31'  WHEN 'CH' THEN '41'  WHEN 'TR' THEN '90'
    WHEN 'CN' THEN '86'  WHEN 'IN' THEN '91'  WHEN 'SA' THEN '966' WHEN 'AE' THEN '971'
    WHEN 'JO' THEN '962'
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
COMMENT ON FUNCTION public.normalize_phone(text, text) IS 'Numéro brut → E.164 (défaut +224). CASE indicatif étendu (Afrique + diaspora). NULL si invalide.';
