-- ============================================================================
-- 🏷️ POS — UNE SEULE VÉRITÉ DE CODE-BARRES (audit 05/08/2026)
-- Deux champs coexistaient : `barcode` (saisie formulaire, souvent le code USINE du
-- fournisseur) et `barcode_value`/`barcode_format` (auto-généré EAN-13, ENCODÉ dans les
-- étiquettes imprimées). Direction UNIQUE choisie : `barcode_value` = source de vérité
-- POS (ce que les étiquettes encodent) ; `barcode` = alias cherchable qui ALIMENTE
-- barcode_value UNIQUEMENT quand celui-ci est vide (ne JAMAIS écraser un barcode_value
-- existant : des étiquettes déjà imprimées l'encodent).
-- + Normalisation : trim + retrait des caractères de contrôle (suffixes douchette).
-- ============================================================================

-- Fonction de nettoyage : contrôles (CR/LF/TAB…) retirés + trim ; '' → NULL.
CREATE OR REPLACE FUNCTION public.normalize_barcode(v text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT NULLIF(btrim(regexp_replace(coalesce(v, ''), '[\x00-\x1f\x7f]', '', 'g')), '');
$$;

-- ── BACKFILL ────────────────────────────────────────────────────────────────
-- 1) Normaliser l'existant (espaces/contrôles parasites dans les deux champs).
UPDATE public.products
SET barcode_value = public.normalize_barcode(barcode_value)
WHERE barcode_value IS DISTINCT FROM public.normalize_barcode(barcode_value);

UPDATE public.products
SET barcode = public.normalize_barcode(barcode)
WHERE barcode IS DISTINCT FROM public.normalize_barcode(barcode);

-- 2) Produits avec `barcode` mais SANS `barcode_value` (créés avant l'auto-génération) :
--    l'étiquette système exige barcode_value (le générateur filtre NOT NULL) → copier,
--    avec le format déduit (13 chiffres = EAN13, sinon CODE128).
UPDATE public.products
SET barcode_value = barcode,
    barcode_format = CASE WHEN barcode ~ '^[0-9]{13}$' THEN 'EAN13' ELSE 'CODE128' END
WHERE barcode_value IS NULL AND barcode IS NOT NULL;

-- ── TRIGGER DE SYNCHRO (la direction unique, appliquée à TOUTE écriture future :
--    création, édition, import — quel que soit le client) ──
CREATE OR REPLACE FUNCTION public.sync_product_barcode()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.barcode := public.normalize_barcode(NEW.barcode);
  NEW.barcode_value := public.normalize_barcode(NEW.barcode_value);
  IF NEW.barcode_value IS NULL AND NEW.barcode IS NOT NULL THEN
    NEW.barcode_value := NEW.barcode;
    NEW.barcode_format := CASE WHEN NEW.barcode ~ '^[0-9]{13}$' THEN 'EAN13' ELSE 'CODE128' END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_product_barcode ON public.products;
CREATE TRIGGER trg_sync_product_barcode
  BEFORE INSERT OR UPDATE OF barcode, barcode_value ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.sync_product_barcode();
