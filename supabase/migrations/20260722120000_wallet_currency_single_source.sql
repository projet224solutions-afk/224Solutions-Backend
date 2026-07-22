-- 20260722120000_wallet_currency_single_source.sql
-- CHANTIER 1 — Devise du wallet dérivée du PAYS via countries.currency_code (source UNIQUE).
--
-- Constat d'audit (prod, 22/07/2026) :
--   * Les « trois défauts contradictoires » (XAF / 'FCFA' / GNF) sont HISTORIQUES : la table wallets
--     a été DROP+recréée par 20260109000000 en `currency VARCHAR(3) DEFAULT 'GNF'` — 'XAF'/'FCFA' sont
--     morts, et VARCHAR(3) exclut déjà 'FCFA' (4 car.). Inventaire prod : GNF=42, XOF=3, EUR=2, USD=1,
--     ZÉRO code invalide, 1 seul écart (GN/XOF AVEC solde → laissé à l'arbitrage PDG).
--   * Le VRAI bug : (a) le filet BEFORE INSERT `wallet_set_country_currency` joignait UNIQUEMENT sur
--     profiles.country_code, JAMAIS renseigné à l'inscription → inopérant ; (b) des chemins Node
--     écrivent 'GNF' en dur ; (c) DEUX sources de vérité pays→devise (get_currency_for_country CASE,
--     divergent p.ex. SL→SLL au lieu du SLE de countries, vs la table countries).
--
-- Correction : UNE seule vérité (resolve_default_currency lit countries), le filet devient robuste et
-- FORCE la devise du pays sur le wallet PRINCIPAL, get_currency_for_country délègue (fin de la divergence),
-- CHECK ISO en base (jamais un code inventé), country_code auto-renseigné (présent + futur).
-- Aucun wallet à solde n'est modifié.

-- 1) RÉSOLVEUR UNIQUE pays -> devise (lit countries ; repli plateforme GNF si pays inconnu/NULL)
CREATE OR REPLACE FUNCTION public.resolve_default_currency(p_country_code text)
RETURNS text
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $$
  SELECT COALESCE(
    (SELECT c.currency_code FROM public.countries c
      WHERE c.country_code = UPPER(TRIM(p_country_code)) LIMIT 1),
    'GNF');
$$;

CREATE OR REPLACE FUNCTION public.resolve_default_currency_for_user(p_user_id uuid)
RETURNS text
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $$
  SELECT public.resolve_default_currency(
    (SELECT UPPER(COALESCE(NULLIF(TRIM(country_code), ''), NULLIF(TRIM(detected_country), ''),
                           NULLIF(TRIM(country), ''), 'GN'))
       FROM public.profiles WHERE id = p_user_id));
$$;

REVOKE ALL ON FUNCTION public.resolve_default_currency(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_default_currency_for_user(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_default_currency(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.resolve_default_currency_for_user(uuid) TO authenticated, service_role;

-- 2) UNIFICATION : l'ancien résolveur codé en dur délègue désormais à la table
--    (corrige les divergences, p.ex. SL: SLL -> SLE). Signature/return inchangés.
CREATE OR REPLACE FUNCTION public.get_currency_for_country(p_country_code text)
RETURNS character varying
LANGUAGE sql STABLE
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
  SELECT public.resolve_default_currency(p_country_code)::varchar;
$$;

-- 3) FILET DE SÉCURITÉ DURCI (BEFORE INSERT wallets) :
--    - le wallet PRINCIPAL (premier de l'utilisateur) prend TOUJOURS la devise du pays,
--      quelle que soit la valeur passée -> neutralise les 'GNF' en dur des chemins Node ;
--    - un wallet secondaire (multi-devise) sans devise fournie retombe sur la devise du pays ;
--    - garde-fou ISO : jamais un code inventé (p.ex. 'FCFA').
--    Le pays est résolu country_code > detected_country > country (le filet n'est plus aveugle).
CREATE OR REPLACE FUNCTION public.wallet_set_country_currency()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_country  text;
  v_cur      text;
  v_is_first boolean;
BEGIN
  SELECT UPPER(COALESCE(NULLIF(TRIM(p.country_code), ''), NULLIF(TRIM(p.detected_country), ''),
                        NULLIF(TRIM(p.country), '')))
    INTO v_country
  FROM public.profiles p
  WHERE p.id = NEW.user_id;

  v_cur := public.resolve_default_currency(v_country);  -- repli GNF interne

  SELECT NOT EXISTS (SELECT 1 FROM public.wallets w WHERE w.user_id = NEW.user_id)
    INTO v_is_first;

  IF v_is_first THEN
    NEW.currency := v_cur;                                   -- wallet principal = devise du pays (priorité absolue)
  ELSIF NEW.currency IS NULL OR TRIM(NEW.currency) = '' THEN
    NEW.currency := v_cur;                                   -- wallet secondaire sans devise -> repli pays
  END IF;

  IF NEW.currency !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'Devise wallet invalide (attendu code ISO 3 lettres): %', NEW.currency
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;

-- 4) country_code AUTO-RENSEIGNÉ sur profiles (présent + futur) : cohérence géo / commission / proximité,
--    et rend le filet §3 opérant dès l'inscription. Ne touche jamais un country_code déjà posé.
CREATE OR REPLACE FUNCTION public.profile_set_country_code()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.country_code IS NULL OR TRIM(NEW.country_code) = '' THEN
    NEW.country_code := UPPER(NULLIF(TRIM(COALESCE(NEW.detected_country, NEW.country)), ''));
  END IF;
  -- jamais violer la FK countries : si le code déduit est inconnu, on laisse NULL
  IF NEW.country_code IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.countries c WHERE c.country_code = NEW.country_code) THEN
    NEW.country_code := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_profile_set_country_code ON public.profiles;
CREATE TRIGGER trg_profile_set_country_code
  BEFORE INSERT OR UPDATE OF detected_country, country ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.profile_set_country_code();

-- 5) BACKFILL country_code des profils existants (uniquement quand vide ET code déduit valide)
UPDATE public.profiles p
   SET country_code = UPPER(COALESCE(NULLIF(TRIM(p.detected_country), ''), NULLIF(TRIM(p.country), '')))
 WHERE (p.country_code IS NULL OR TRIM(p.country_code) = '')
   AND UPPER(COALESCE(NULLIF(TRIM(p.detected_country), ''), NULLIF(TRIM(p.country), '')))
       IN (SELECT country_code FROM public.countries);

-- 6) NORMALISATION DÉFENSIVE des codes hérités non-ISO sur wallets à solde NUL uniquement
--    ('FCFA'/'CFA'/vide -> devise du pays). Les wallets à solde ne sont JAMAIS touchés (arbitrage PDG).
UPDATE public.wallets w
   SET currency = public.resolve_default_currency_for_user(w.user_id)
 WHERE (w.currency IS NULL OR w.currency !~ '^[A-Z]{3}$')
   AND COALESCE(w.balance, 0) = 0;

-- 7) CHECK ISO 3 lettres — plus jamais un code inventé en base (wallets + tables argent voisines)
ALTER TABLE public.wallets              DROP CONSTRAINT IF EXISTS wallets_currency_iso_chk;
ALTER TABLE public.wallets              ADD  CONSTRAINT wallets_currency_iso_chk
  CHECK (currency ~ '^[A-Z]{3}$');

ALTER TABLE public.wallet_transactions  DROP CONSTRAINT IF EXISTS wallet_transactions_currency_iso_chk;
ALTER TABLE public.wallet_transactions  ADD  CONSTRAINT wallet_transactions_currency_iso_chk
  CHECK (currency ~ '^[A-Z]{3}$');

ALTER TABLE public.agent_wallets        DROP CONSTRAINT IF EXISTS agent_wallets_currency_iso_chk;
ALTER TABLE public.agent_wallets        ADD  CONSTRAINT agent_wallets_currency_iso_chk
  CHECK (currency ~ '^[A-Z]{3}$' AND (currency_type IS NULL OR currency_type ~ '^[A-Z]{3}$'));
