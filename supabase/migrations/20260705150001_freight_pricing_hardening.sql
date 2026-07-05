-- ============================================================================
-- 🚢✈️  MODULE TRANSITAIRE — PHASE 1 (CORRECTIF) : DURCISSEMENT TARIFICATION FRET
-- ----------------------------------------------------------------------------
-- Migration CORRECTIVE ADDITIONNELLE. Complète 20260705150000_freight_pricing.sql
-- (table freight_rates + RPC calculate_freight_quote + policies), DÉJÀ APPLIQUÉE
-- en base. Ne RÉÉCRIT PAS la migration de base : elle la corrige de façon
-- idempotente / rejouable (CREATE OR REPLACE + DROP POLICY IF EXISTS).
--
-- Corrige deux problèmes majeurs révélés par une vérif adverse :
--
--   FIX A — SOUS-FACTURATION AÉRIENNE (multi-pièces incohérent).
--     La RPC multipliait le VOLUME par le nombre de pièces mais laissait le POIDS
--     RÉEL à la valeur d'UNE seule pièce (v_real_kg = p_weight_kg brut). Résultat :
--     le poids taxable aérien = max(poids_1_pièce, volume_total) sous-facturait dès
--     que le réel dominait. Modèle retenu = PAR PIÈCE pour TOUT : l'utilisateur
--     saisit dimensions ET poids d'UNE pièce + le nombre de pièces. On multiplie
--     donc le poids réel par le nombre de pièces (comme le volume l'était déjà) :
--       v_real_kg := poids_pièce × pièces.
--     Le drapeau min_charge_applied compare désormais la valeur ARRONDIE (cohérence
--     avec le prix renvoyé, GREATEST(round(...), min_charge)).
--
--   FIX B — ÉCRITURE DES GRILLES SANS CONTRÔLE DE RÔLE.
--     La policy freight_rates_owner_all (FOR ALL, transitaire_id = auth.uid())
--     n'exigeait AUCUN rôle → tout compte authentifié pouvait créer SES propres
--     grilles tarifaires. On ajoute un contrôle de rôle transitaire (profiles.role,
--     modèle useAuth : le rôle vit sur le profil). L'EXISTS lit le PROPRE profil
--     (id = auth.uid()) donc n'est jamais bloqué par la RLS de profiles. La lecture
--     publique des grilles est en outre restreinte à 'authenticated' (les prix
--     concurrentiels ne sont plus exposés à anon).
--
-- Migration LIVRÉE — NON exécutée.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX A — RPC calculate_freight_quote (même signature ; PAR PIÈCE pour TOUT)
--   Aérien  : poids_réel_total   = poids_pièce × pièces
--             poids_volum_total  = (L×l×h × pièces) / volumetric_divisor
--             poids_taxable      = max(réel_total, volumétrique_total)
--             prix               = max(round(taxable × price_per_kg, 2), min_charge)
--   Maritime: volume_cbm         = (L×l×h × pièces) / 1 000 000        (inchangé)
--             prix               = max(round(cbm × price_per_cbm, 2), min_charge)
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
  -- FIX A : le poids saisi est celui d'UNE pièce → poids réel total = poids_pièce × pièces.
  v_real_kg := GREATEST(COALESCE(p_weight_kg, 0), 0) * v_pieces;

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
    v_min_applied := round(v_taxable_kg * v_rate.price_per_kg, 2) < v_rate.min_charge;

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
    v_min_applied := round(v_cbm * v_rate.price_per_cbm, 2) < v_rate.min_charge;

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

-- GRANTS (ré-affirmés — idempotent ; CREATE OR REPLACE préserve les privilèges mais
-- on garde la surface minimale documentée : seul service_role exécute la RPC).
REVOKE ALL ON FUNCTION public.calculate_freight_quote(uuid, text, text, text, numeric, numeric, numeric, numeric, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_freight_quote(uuid, text, text, text, numeric, numeric, numeric, numeric, integer) TO service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- FIX B — POLICIES freight_rates : contrôle de rôle transitaire + lecture authentifiée
-- ─────────────────────────────────────────────────────────────────────────────

-- Écriture/gestion des grilles réservée au PROPRIÉTAIRE ET au rôle 'transitaire'.
-- profiles.role = source du rôle (modèle useAuth). L'EXISTS lit le propre profil
-- (id = auth.uid()) → jamais bloqué par la RLS de profiles.
DROP POLICY IF EXISTS freight_rates_owner_all ON public.freight_rates;
CREATE POLICY freight_rates_owner_all ON public.freight_rates
  FOR ALL
  USING (
    transitaire_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid() AND p.role::text = 'transitaire'
    )
  )
  WITH CHECK (
    transitaire_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid() AND p.role::text = 'transitaire'
    )
  );

-- Lecture des grilles ACTIVES restreinte aux comptes AUTHENTIFIÉS (retire anon :
-- les prix concurrentiels ne sont plus exposés au public non connecté).
DROP POLICY IF EXISTS freight_rates_public_read_active ON public.freight_rates;
CREATE POLICY freight_rates_public_read_active ON public.freight_rates
  FOR SELECT
  TO authenticated
  USING (active = true);

SELECT '✅ freight hardening — poids réel ×pièces (fix sous-facturation aérienne) + contrôle rôle transitaire sur freight_rates' AS status;
