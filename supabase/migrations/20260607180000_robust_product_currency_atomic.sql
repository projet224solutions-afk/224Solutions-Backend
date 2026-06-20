-- 🛡️🛡️ DURCISSEMENT ULTRA-ROBUSTE — DEVISE DU PRIX PRODUIT = DEVISE DU PAYS DU VENDEUR
--
-- Le système de devise produit cassait à répétition car la devise du prix était DÉRIVÉE à la volée
-- dans ~8 endroits (hooks/composants/backend), avec des sources contradictoires (champ produit=GNF,
-- shop_currency parfois faux ex. vendeur Guinée=EUR, pays). Vérité établie par la donnée : le prix
-- est dans la devise du PAYS du vendeur (Guinée→GNF, Sénégal→XOF, CEMAC→XAF).
--
-- Cette migration crée UNE SOURCE UNIQUE, maintenue ATOMIQUEMENT par la base :
--   1. resolve_country_currency(country) : fonction canonique pays→devise (normalisée, accents).
--   2. Backfill : products.currency/seller_currency/original_price_currency = devise du pays vendeur.
--   3. Trigger produits (INSERT / changement de vendeur) → fixe la devise depuis le pays du vendeur.
--   4. Trigger vendeurs (changement de country) → propage à TOUS ses produits.
-- → La devise stockée est TOUJOURS cohérente, impossible de dériver. Tout consommateur peut lire
--   products.seller_currency en confiance, et le checkout backend reste cohérent avec l'affichage.

-- ── 1. Fonction canonique pays → devise (IMMUTABLE, normalise accents/casse/espaces) ──
CREATE OR REPLACE FUNCTION public.resolve_country_currency(p_country text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  -- ⚠️ DOIT rester synchronisé avec getCurrencyForCountry (frontend) et currencyFromCountry (backend)
  SELECT CASE
    WHEN c IN ('guinee','guinea','gn') THEN 'GNF'
    WHEN c IN ('senegal','sn','mali','ml','cote d''ivoire','ivory coast','ci','burkina faso','bf',
               'niger','ne','togo','tg','benin','bj','guinee-bissau','gw') THEN 'XOF'
    WHEN c IN ('cameroun','cameroon','cm','gabon','ga','tchad','chad','td','congo','cg',
               'centrafrique','cf','guinee equatoriale','gq') THEN 'XAF'
    WHEN c IN ('sierra leone','sl') THEN 'SLL'
    WHEN c IN ('liberia','lr') THEN 'LRD'
    WHEN c IN ('gambie','gambia','gm') THEN 'GMD'
    WHEN c IN ('nigeria','ng') THEN 'NGN'
    WHEN c IN ('ghana','gh') THEN 'GHS'
    WHEN c IN ('rd congo','rdc','congo-kinshasa','cd') THEN 'CDF'
    WHEN c IN ('maroc','morocco','ma') THEN 'MAD'
    WHEN c IN ('tunisie','tunisia','tn') THEN 'TND'
    WHEN c IN ('algerie','algeria','dz') THEN 'DZD'
    WHEN c IN ('egypte','egypt','eg') THEN 'EGP'
    WHEN c IN ('kenya','ke') THEN 'KES'
    WHEN c IN ('tanzanie','tanzania','tz') THEN 'TZS'
    WHEN c IN ('ouganda','uganda','ug') THEN 'UGX'
    WHEN c IN ('rwanda','rw') THEN 'RWF'
    WHEN c IN ('ethiopie','ethiopia','et') THEN 'ETB'
    WHEN c IN ('afrique du sud','south africa','za') THEN 'ZAR'
    WHEN c IN ('france','fr','belgique','belgium','be') THEN 'EUR'
    WHEN c IN ('suisse','switzerland','ch') THEN 'CHF'
    WHEN c IN ('canada','ca') THEN 'CAD'
    WHEN c IN ('etats-unis','united states','usa','us') THEN 'USD'
    WHEN c IN ('royaume-uni','united kingdom','uk','gb') THEN 'GBP'
    WHEN c IN ('chine','china','cn') THEN 'CNY'
    WHEN c IN ('japon','japan','jp') THEN 'JPY'
    WHEN c IN ('inde','india','in') THEN 'INR'
    WHEN c IN ('bresil','brazil','br') THEN 'BRL'
    WHEN c IN ('turquie','turkey','tr') THEN 'TRY'
    ELSE 'GNF'
  END
  FROM (
    SELECT translate(lower(btrim(coalesce(p_country, ''))),
                     'éèêëàâäîïôöûüç', 'eeeeaaaiioouuc') AS c
  ) s;
$$;

-- ── 2. Backfill : chaque produit prend la devise du PAYS de son vendeur (prix `price` INCHANGÉ) ──
UPDATE public.products p
SET currency                = public.resolve_country_currency(v.country),
    seller_currency         = public.resolve_country_currency(v.country),
    original_price_currency = public.resolve_country_currency(v.country),
    updated_at              = now()
FROM public.vendors v
WHERE p.vendor_id = v.id
  AND (
       COALESCE(p.seller_currency, '')         IS DISTINCT FROM public.resolve_country_currency(v.country)
    OR COALESCE(p.currency, '')                IS DISTINCT FROM public.resolve_country_currency(v.country)
    OR COALESCE(p.original_price_currency, '') IS DISTINCT FROM public.resolve_country_currency(v.country)
  );

-- ── 3. Trigger produits : à la création (ou changement de vendeur), fixer la devise ──
CREATE OR REPLACE FUNCTION public.trg_products_sync_currency()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE v_cur text;
BEGIN
  SELECT public.resolve_country_currency(country) INTO v_cur
  FROM public.vendors WHERE id = NEW.vendor_id;
  v_cur := COALESCE(v_cur, 'GNF');
  NEW.currency                := v_cur;
  NEW.seller_currency         := v_cur;
  NEW.original_price_currency := v_cur;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS products_sync_currency ON public.products;
CREATE TRIGGER products_sync_currency
  BEFORE INSERT OR UPDATE OF vendor_id ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.trg_products_sync_currency();

-- ── 4. Trigger vendeurs : si le pays change, propager la nouvelle devise à TOUS ses produits ──
CREATE OR REPLACE FUNCTION public.trg_vendor_country_sync_products()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.country IS DISTINCT FROM OLD.country THEN
    UPDATE public.products
    SET currency                = public.resolve_country_currency(NEW.country),
        seller_currency         = public.resolve_country_currency(NEW.country),
        original_price_currency = public.resolve_country_currency(NEW.country),
        updated_at              = now()
    WHERE vendor_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS vendor_country_sync_products ON public.vendors;
CREATE TRIGGER vendor_country_sync_products
  AFTER UPDATE OF country ON public.vendors
  FOR EACH ROW EXECUTE FUNCTION public.trg_vendor_country_sync_products();

SELECT 'Devise produit = devise du pays vendeur, maintenue atomiquement par triggers (backfill + sync).' AS status;
