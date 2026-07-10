-- ============================================================================
-- 🏠 lease_inventories : matérialiser (et blinder) la table d'état des lieux
-- ----------------------------------------------------------------------------
-- Constat (cartographie 2026-07-06) : LeaseInventoryDialog.tsx insère/lit
-- `lease_inventories` via (supabase as any), MAIS aucune migration ne crée la table
-- et elle est absente de types.ts → table « fantôme » : soit créée à la main en
-- prod (sans RLS versionnée), soit les inserts échouent silencieusement. On la
-- matérialise ici, IF NOT EXISTS (no-op si elle existe déjà en prod), avec la RLS
-- que le commentaire du composant annonçait déjà (« propriétaire + locataire en
-- lecture »). C'est aussi le support vérifié par release_deposit_atomic
-- (p_inventory_id, kind='sortie').
--
-- Colonnes = exactement ce que le composant écrit (lease_id, professional_service_id,
-- kind 'entree'|'sortie', rooms jsonb, general_notes) + id/done_at/created_at.
-- Écriture réservée au PROPRIÉTAIRE du bien (bailleur) ; lecture bailleur + locataire
-- + admin. Le bailleur = properties.owner_id (rental_leases n'a pas de colonne bailleur).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.lease_inventories (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lease_id                uuid NOT NULL REFERENCES public.rental_leases(id) ON DELETE CASCADE,
  professional_service_id uuid,
  kind                    text NOT NULL DEFAULT 'entree' CHECK (kind IN ('entree','sortie')),
  rooms                   jsonb NOT NULL DEFAULT '[]'::jsonb,
  general_notes           text,
  done_at                 timestamptz NOT NULL DEFAULT now(),
  created_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_lease_inventories_lease ON public.lease_inventories (lease_id, kind);

ALTER TABLE public.lease_inventories ENABLE ROW LEVEL SECURITY;

-- Lecture : bailleur (propriétaire du bien) + locataire du bail + admin.
DROP POLICY IF EXISTS lease_inventories_read ON public.lease_inventories;
CREATE POLICY lease_inventories_read ON public.lease_inventories
  FOR SELECT TO authenticated
  USING (
    public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.rental_leases rl
      JOIN public.properties p ON p.id = rl.property_id
      WHERE rl.id = lease_inventories.lease_id
        AND (p.owner_id = auth.uid() OR rl.tenant_user_id = auth.uid())
    )
  );

-- Écriture : le BAILLEUR (propriétaire du bien) uniquement.
DROP POLICY IF EXISTS lease_inventories_owner_insert ON public.lease_inventories;
CREATE POLICY lease_inventories_owner_insert ON public.lease_inventories
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.rental_leases rl
      JOIN public.properties p ON p.id = rl.property_id
      WHERE rl.id = lease_inventories.lease_id AND p.owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS lease_inventories_owner_modify ON public.lease_inventories;
CREATE POLICY lease_inventories_owner_modify ON public.lease_inventories
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.rental_leases rl
      JOIN public.properties p ON p.id = rl.property_id
      WHERE rl.id = lease_inventories.lease_id AND p.owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS lease_inventories_owner_delete ON public.lease_inventories;
CREATE POLICY lease_inventories_owner_delete ON public.lease_inventories
  FOR DELETE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.rental_leases rl
      JOIN public.properties p ON p.id = rl.property_id
      WHERE rl.id = lease_inventories.lease_id AND p.owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS lease_inventories_service_role ON public.lease_inventories;
CREATE POLICY lease_inventories_service_role ON public.lease_inventories
  FOR ALL TO service_role USING (true) WITH CHECK (true);

SELECT 'lease_inventories matérialisée (IF NOT EXISTS) + RLS bailleur(écriture)/locataire+bailleur(lecture).' AS status;
