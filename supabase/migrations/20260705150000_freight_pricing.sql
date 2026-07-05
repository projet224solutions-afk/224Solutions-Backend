-- ============================================================================
-- 🚢✈️  MODULE TRANSITAIRE — PHASE 1 : TARIFICATION FRET (DEVIS À PRIX SERVEUR)
-- ----------------------------------------------------------------------------
-- Fret international multimodal (aérien + maritime). Le transitaire définit SES
-- grilles tarifaires (freight_rates) ; le prix d'un devis est calculé par la RPC
-- SERVEUR calculate_freight_quote (seule source de vérité). Le client AFFICHE le
-- résultat, il ne calcule JAMAIS le prix final.
--
-- Aérien  : poids_volumétrique = (L×l×h×pièces) / volumetric_divisor (cm³→kg) ;
--           poids_taxable = max(poids_réel, poids_volumétrique) ;
--           prix = max(poids_taxable × price_per_kg, min_charge).
-- Maritime: volume_cbm = (L×l×h×pièces) / 1 000 000 ;
--           prix = max(volume_cbm × price_per_cbm, min_charge).
--
-- Choix de table maîtresse : les EXPÉDITIONS internationales vivent déjà dans
--   public.international_shipments (transitaire_id, origin/destination_country,
--   shipping_cost, customs_fees, total_weight_kg) — c'est la table maîtresse du
--   module transitaire. `public.shipments` (JYM/COD) reste la logistique DOMESTIQUE
--   du vendeur, hors périmètre transitaire. La Phase 1 (devis) N'ÉCRIT AUCUNE
--   expédition : elle ne fait que TARIFER. La table freight_rates ci-dessous porte
--   les grilles ; l'écriture d'expéditions (avec le devis figé) viendra en Phase 2
--   sur international_shipments.
--
-- Migration LIVRÉE — NON exécutée.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. TABLE freight_rates — grilles tarifaires du transitaire
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.freight_rates (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transitaire_id     uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  mode               text NOT NULL CHECK (mode IN ('air', 'sea')),
  origin_zone        text NOT NULL,
  dest_zone          text NOT NULL,
  price_per_kg       numeric,            -- aérien : prix / kg taxable
  price_per_cbm      numeric,            -- maritime : prix / m³ (CBM)
  min_charge         numeric NOT NULL DEFAULT 0 CHECK (min_charge >= 0),
  currency           text NOT NULL DEFAULT 'GNF',
  volumetric_divisor numeric NOT NULL DEFAULT 6000 CHECK (volumetric_divisor > 0), -- cm³→kg (aérien)
  active             boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  -- La grille doit porter le tarif correspondant à son mode (pas de fret gratuit silencieux).
  CONSTRAINT freight_rates_price_matches_mode CHECK (
    (mode = 'air' AND price_per_kg  IS NOT NULL AND price_per_kg  >= 0) OR
    (mode = 'sea' AND price_per_cbm IS NOT NULL AND price_per_cbm >= 0)
  )
);

-- Une seule grille ACTIVE par (transitaire, mode, itinéraire) — insensible à la casse.
CREATE UNIQUE INDEX IF NOT EXISTS uq_freight_rates_active_route
  ON public.freight_rates (transitaire_id, mode, lower(origin_zone), lower(dest_zone))
  WHERE active;

CREATE INDEX IF NOT EXISTS idx_freight_rates_transitaire ON public.freight_rates (transitaire_id);
CREATE INDEX IF NOT EXISTS idx_freight_rates_lookup
  ON public.freight_rates (mode, lower(origin_zone), lower(dest_zone)) WHERE active;

-- updated_at auto (fonction dédiée, migration auto-suffisante).
CREATE OR REPLACE FUNCTION public.freight_rates_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_freight_rates_updated_at ON public.freight_rates;
CREATE TRIGGER trg_freight_rates_updated_at
  BEFORE UPDATE ON public.freight_rates
  FOR EACH ROW EXECUTE FUNCTION public.freight_rates_touch_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RLS — le transitaire gère SES grilles ; lecture publique des grilles actives
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.freight_rates ENABLE ROW LEVEL SECURITY;

-- profiles.id = auth.users.id ⇒ transitaire_id = auth.uid() pour le propriétaire.
DROP POLICY IF EXISTS freight_rates_owner_all ON public.freight_rates;
CREATE POLICY freight_rates_owner_all ON public.freight_rates
  FOR ALL
  USING (transitaire_id = auth.uid())
  WITH CHECK (transitaire_id = auth.uid());

-- Lecture publique des grilles ACTIVES (transparence tarifaire pour le devis).
DROP POLICY IF EXISTS freight_rates_public_read_active ON public.freight_rates;
CREATE POLICY freight_rates_public_read_active ON public.freight_rates
  FOR SELECT
  USING (active = true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RPC calculate_freight_quote — DEVIS À PRIX SERVEUR (autoritaire)
--    Le client ne calcule JAMAIS le prix : il envoie les paramètres, le serveur
--    lit la grille active et renvoie le prix + le détail. Aucun prix client accepté.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.calculate_freight_quote(
  p_transitaire_id uuid,
  p_mode           text,
  p_origin         text,
  p_dest           text,
  p_weight_kg      numeric DEFAULT 0,
  p_length_cm      numeric DEFAULT 0,
  p_width_cm       numeric DEFAULT 0,
  p_height_cm      numeric DEFAULT 0,
  p_pieces         integer DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate        public.freight_rates%ROWTYPE;
  v_pieces      integer;
  v_real_kg     numeric;
  v_vol_cm3     numeric;
  v_vol_kg      numeric;
  v_taxable_kg  numeric;
  v_cbm         numeric;
  v_price       numeric;
  v_min_applied boolean;
BEGIN
  -- Validation stricte (pas de fallback silencieux).
  IF p_transitaire_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'TRANSITAIRE_REQUIRED');
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('air', 'sea') THEN
    RETURN jsonb_build_object('success', false, 'error', 'INVALID_MODE');
  END IF;
  IF p_origin IS NULL OR btrim(p_origin) = '' OR p_dest IS NULL OR btrim(p_dest) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'ROUTE_REQUIRED');
  END IF;

  v_pieces  := GREATEST(COALESCE(p_pieces, 1), 1);
  v_real_kg := GREATEST(COALESCE(p_weight_kg, 0), 0);

  -- Grille ACTIVE correspondante (itinéraire insensible à la casse).
  SELECT * INTO v_rate
  FROM public.freight_rates
  WHERE transitaire_id = p_transitaire_id
    AND mode   = p_mode
    AND active = true
    AND lower(btrim(origin_zone)) = lower(btrim(p_origin))
    AND lower(btrim(dest_zone))   = lower(btrim(p_dest))
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_RATE_FOUND');
  END IF;

  IF p_mode = 'air' THEN
    -- Poids volumétrique (cm³ → kg) puis poids taxable = max(réel, volumétrique).
    v_vol_cm3    := GREATEST(COALESCE(p_length_cm, 0), 0)
                  * GREATEST(COALESCE(p_width_cm, 0), 0)
                  * GREATEST(COALESCE(p_height_cm, 0), 0)
                  * v_pieces;
    v_vol_kg     := round(v_vol_cm3 / v_rate.volumetric_divisor, 3);
    v_taxable_kg := GREATEST(v_real_kg, v_vol_kg);
    v_price      := GREATEST(round(v_taxable_kg * v_rate.price_per_kg, 2), v_rate.min_charge);
    v_min_applied := (v_taxable_kg * v_rate.price_per_kg) < v_rate.min_charge;

    RETURN jsonb_build_object(
      'success',              true,
      'mode',                 'air',
      'currency',             v_rate.currency,
      'price',                v_price,
      'min_charge',           v_rate.min_charge,
      'min_charge_applied',   v_min_applied,
      'price_per_kg',         v_rate.price_per_kg,
      'volumetric_divisor',   v_rate.volumetric_divisor,
      'real_weight_kg',       v_real_kg,
      'volumetric_weight_kg', v_vol_kg,
      'chargeable_weight_kg', v_taxable_kg,
      'pieces',               v_pieces,
      'rate_id',              v_rate.id
    );
  ELSE
    -- Maritime : volume en m³ (CBM).
    v_cbm   := round((GREATEST(COALESCE(p_length_cm, 0), 0)
                    * GREATEST(COALESCE(p_width_cm, 0), 0)
                    * GREATEST(COALESCE(p_height_cm, 0), 0)
                    * v_pieces) / 1000000.0, 4);
    v_price := GREATEST(round(v_cbm * v_rate.price_per_cbm, 2), v_rate.min_charge);
    v_min_applied := (v_cbm * v_rate.price_per_cbm) < v_rate.min_charge;

    RETURN jsonb_build_object(
      'success',            true,
      'mode',               'sea',
      'currency',           v_rate.currency,
      'price',              v_price,
      'min_charge',         v_rate.min_charge,
      'min_charge_applied', v_min_applied,
      'price_per_cbm',      v_rate.price_per_cbm,
      'volume_cbm',         v_cbm,
      'pieces',             v_pieces,
      'rate_id',            v_rate.id
    );
  END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. GRANTS — choix documenté
--    Le devis est en LECTURE SEULE (aucun mouvement d'argent, aucune écriture) :
--    une lecture publique serait acceptable. On centralise néanmoins TOUS les
--    appels via la route backend (service_role), donc on RETIRE l'exécution à
--    PUBLIC/anon/authenticated et on l'accorde au seul service_role (convention
--    codebase, surface minimale). La transparence tarifaire reste assurée par la
--    policy RLS `freight_rates_public_read_active` (SELECT des grilles actives).
-- ─────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.calculate_freight_quote(uuid, text, text, text, numeric, numeric, numeric, numeric, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_freight_quote(uuid, text, text, text, numeric, numeric, numeric, numeric, integer) TO service_role;

SELECT '✅ freight_rates + calculate_freight_quote (devis prix serveur air/mer) — Phase 1 transitaire' AS status;
