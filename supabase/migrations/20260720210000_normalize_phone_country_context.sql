-- ============================================================================
-- PHASE A — normalize_phone() reçoit le PAYS DU CONTEXTE (fin du +224 en dur).
-- Bug prouvé : le trigger tg_profiles_phone_e164 appelait normalize_phone(phone,'GN')
-- → un Sénégalais qui saisit son numéro LOCAL (771234567) obtenait +224771234567
-- (numéro inexistant / faux doublon). Le pays existe pourtant sur le profil
-- (country_code / detected_country / country). Un numéro déjà en +XXX est respecté.
-- La devise du wallet par pays est DÉJÀ gérée par trigger_create_wallet +
-- wallet_set_country_currency (via countries.currency_code) — rien à changer là.
-- ============================================================================

-- L'UNICITÉ doit porter sur le E.164 COMPLET (indicatif pays inclus), PAS sur les
-- 9 derniers chiffres : +224624039029 (GN) et +221624039029 (SN) sont DEUX numéros
-- valides et distincts. L'ancien uq_profiles_phone_norm9 les confondait (faux doublon
-- inter-pays) → on le retire. L'index de RECHERCHE non-unique idx_profiles_phone_norm9
-- reste (utilisé par resolve_user_id_by_phone). uq_profiles_phone_e164 = la vraie unicité.
DROP INDEX IF EXISTS public.uq_profiles_phone_norm9;

CREATE OR REPLACE FUNCTION public.tg_profiles_phone_e164()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.phone_e164 := public.normalize_phone(
    NEW.phone,
    COALESCE(
      NULLIF(NEW.country_code, ''),
      NULLIF(NEW.detected_country, ''),
      CASE WHEN length(COALESCE(NEW.country, '')) BETWEEN 2 AND 3 THEN upper(NEW.country) END,
      'GN'   -- défaut final si le profil n'a AUCUN pays
    )
  );
  RETURN NEW;
END $$;

-- Recompute aussi quand le PAYS change (pas seulement le téléphone).
DROP TRIGGER IF EXISTS trg_profiles_phone_e164 ON public.profiles;
CREATE TRIGGER trg_profiles_phone_e164
  BEFORE INSERT OR UPDATE OF phone, country_code, detected_country, country ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.tg_profiles_phone_e164();

-- Backfill : recalcule phone_e164 avec le VRAI pays du profil. Non destructif —
-- COALESCE respecte les numéros déjà en +XXX ; ne corrige que les locaux mal préfixés.
UPDATE public.profiles
SET phone_e164 = public.normalize_phone(
  phone,
  COALESCE(
    NULLIF(country_code, ''),
    NULLIF(detected_country, ''),
    CASE WHEN length(COALESCE(country, '')) BETWEEN 2 AND 3 THEN upper(country) END,
    'GN'))
WHERE phone IS NOT NULL AND btrim(phone) <> ''
  AND phone_e164 IS DISTINCT FROM public.normalize_phone(
    phone,
    COALESCE(NULLIF(country_code, ''), NULLIF(detected_country, ''),
             CASE WHEN length(COALESCE(country, '')) BETWEEN 2 AND 3 THEN upper(country) END, 'GN'));

-- ── DEVISE DU WALLET : re-synchronisation quand le pays est renseigné après coup ──
-- Le wallet est créé À L'INSERTION du profil, parfois avant que le pays soit connu
-- → GNF par défaut. Renseigner le pays ensuite ne changeait pas le wallet. Ce trigger
-- corrige la devise d'un wallet ENCORE VIDE (solde 0, aucune transaction) ; il ne
-- touche JAMAIS un wallet actif ni une devise CHOISIE par l'utilisateur (preferred_currency).
CREATE OR REPLACE FUNCTION public.tg_profile_country_sync_wallet()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_country text; v_cur text;
BEGIN
  IF NEW.preferred_currency IS NOT NULL AND NEW.preferred_currency <> '' THEN RETURN NEW; END IF;
  v_country := COALESCE(
    NULLIF(NEW.country_code, ''), NULLIF(NEW.detected_country, ''),
    CASE WHEN length(COALESCE(NEW.country, '')) BETWEEN 2 AND 3 THEN upper(NEW.country) END);
  IF v_country IS NULL THEN RETURN NEW; END IF;
  v_cur := public.get_currency_for_country(v_country);
  IF v_cur IS NULL OR v_cur = '' THEN RETURN NEW; END IF;

  UPDATE public.wallets w
  SET currency = upper(v_cur), updated_at = now()
  WHERE w.user_id = NEW.id
    AND COALESCE(w.balance, 0) = 0
    AND upper(COALESCE(w.currency, '')) <> upper(v_cur)
    AND NOT EXISTS (SELECT 1 FROM public.wallet_transactions t
                    WHERE t.sender_user_id = NEW.id OR t.receiver_user_id = NEW.id);
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_profile_country_sync_wallet ON public.profiles;
CREATE TRIGGER trg_profile_country_sync_wallet
  AFTER UPDATE OF country_code, detected_country, country ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.tg_profile_country_sync_wallet();
